"""Run native CP entry/readiness/departure methods, mocking their engine boundary."""
from pathlib import Path
import sys
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
    ROOT = Path(sys.argv.pop(1)).resolve()


class NativeContractTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / 'scripts/CpObject.lua').read_text())
        self.lua.execute('AIDriveStrategyCourse = {}; AIDriveStrategyFieldWorkCourse = {}')
        for name in ['AIDriveStrategyUnloadCombine', 'AIDriveStrategyCombineCourse']:
            self.lua.execute((ROOT / f'scripts/ai/strategies/{name}.lua').read_text())
        self.lua.execute('''
        log = {}
        local function record(value) log[#log+1] = value end
        function result() return table.concat(log, ',') end
        u = setmetatable({states=AIDriveStrategyUnloadCombine.myStates}, AIDriveStrategyUnloadCombine)
        u.vehicle = {stopCurrentAIJob=function() record('handover') end}
        u.state = u.states.IDLE
        u.debug = function() end
        u.debugSparse = function() end
        u.setMaxSpeed = function(_,v) record('speed:'..v) end
        u.releaseCombine = function() record('release') end
        u.startPathfindingToInvertedGoalPositionMarker = function() record('return-start') end
        u.setCurrentTaskFinished = function() record('giants-task') end
        AIMessageErrorIsFull = {new=function() return {} end}
        c = setmetatable({states=AIDriveStrategyCombineCourse.myStates}, AIDriveStrategyCombineCourse)
        c.state = {}
        c.debugSparse = function() end
        c.willWaitForUnloadToFinish = function() return false end
        c.isPipeInFruit = function() return false end
        c.course = {isCloseToNextTurn=function() return false end}
        u.combineToUnload = {getCpDriveStrategy=function() return c end}
        u.isBehindAndAlignedToCombine = function() return true end
        u.isInFrontAndAlignedToMovingCombine = function() return false end
        ''')

    def test_clear_working_row_accepts_native_entry(self):
        self.assertTrue(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_pipe_in_crop_rejects_native_moving_entry(self):
        self.lua.execute('c.isPipeInFruit=function() return true end')
        self.assertFalse(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_near_turn_rejects_native_moving_entry(self):
        self.lua.execute('c.course.isCloseToNextTurn=function() return true end')
        self.assertFalse(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_missing_course_rejects_native_moving_entry(self):
        self.lua.execute('c.course=nil')
        self.assertFalse(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_bad_alignment_rejects_entry(self):
        self.lua.execute('u.isBehindAndAlignedToCombine=function() return false end')
        self.assertFalse(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_native_front_alignment_exception_is_preserved(self):
        self.lua.execute('u.isBehindAndAlignedToCombine=function() return false end; '
                         'u.isInFrontAndAlignedToMovingCombine=function() return true end')
        self.assertTrue(self.lua.eval('u:isOkToStartUnloadingCombine()'))

    def test_native_stopped_full_crop_exception_is_preserved(self):
        self.lua.execute('c.state=c.states.UNLOADING_ON_FIELD; '
                         'c.unloadState=c.states.WAITING_FOR_UNLOAD_ON_FIELD; '
                         'c.isPipeInFruit=function() return true end')
        self.assertTrue(self.lua.eval('c:isReadyToUnload(true)'))

    def test_waiting_pocket_readiness_does_not_create_new_crop_override(self):
        self.lua.execute('c.willWaitForUnloadToFinish=function() return true end; '
                         'c.isPipeInFruit=function() return true end')
        self.assertTrue(self.lua.eval('c:isReadyToUnload(true)'))

    def test_release_while_reversing_is_not_idle(self):
        self.lua.execute('u.combineToUnload=nil; u.state=u.states.MOVING_BACK_WITH_TRAILER_FULL')
        self.assertFalse(self.lua.eval('u:isIdle()'))

    def test_departure_returns_to_valid_start_before_handover(self):
        self.lua.execute('u.invertedStartPositionMarkerNode=1; u:startUnloadingTrailers()')
        self.assertEqual(self.lua.eval('result()'), 'speed:0,release,return-start')
        self.lua.execute('u.state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL; u:onLastWaypointPassed()')
        self.assertEqual(self.lua.eval('result()'), 'speed:0,release,return-start,handover')

    def test_departure_without_marker_retains_direct_native_handover(self):
        self.lua.execute('u:startUnloadingTrailers()')
        self.assertEqual(self.lua.eval('result()'), 'speed:0,release,handover')

    def test_giants_departure_is_not_converted_to_ad(self):
        self.lua.execute('u.useGiantsUnload=true; u:onTrailerFull()')
        self.assertEqual(self.lua.eval('result()'), 'giants-task')

    def test_moving_call_keeps_native_rear_target(self):
        self.lua.execute('''
            u.getPipeOffset=function() return 10,4 end
            u.isPathfindingNeeded=function(_,vehicle,wp,x,z,range)
                assert(range==25 and x==10 and z==4); return true end
            u.getCombinesMeasuredBackDistance=function() return 7 end
            u.setNewState=function(self,state) self.state=state end
            u.startPathfindingToMovingCombine=function(_,wp,x,z) targetZ=z end
            accepted=u:call(u.combineToUnload,{x=100,z=100})
        ''')
        self.assertTrue(self.lua.globals().accepted)
        self.assertEqual(self.lua.globals().targetZ,-12)
        self.assertTrue(self.lua.eval('u.state==u.states.WAITING_FOR_PATHFINDER'))

    def test_close_moving_call_is_rejected_without_following(self):
        self.lua.execute('''
            u.getPipeOffset=function() return 10,4 end
            u.isPathfindingNeeded=function() return false end
            u.startWaitingForSomethingToDo=function(self) self.state=self.states.IDLE end
            accepted=u:call(u.combineToUnload,{x=100,z=100})
        ''')
        self.assertFalse(self.lua.globals().accepted)
        self.assertTrue(self.lua.eval('u:isIdle()'))


if __name__ == '__main__':
    unittest.main()
