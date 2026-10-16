"""Ordinary moving-rendezvous overshoot, using native admission/release/recall.

Only the engine, grain transfer and asynchronous pathfinder are adapters.
End-of-course parking and ordinary moving catches retain separate coverage.
"""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_milestone_unloading as milestone
milestone.ROOT = milestone.final.ROOT = milestone.final.yielding.ROOT = milestone.final.yielding.runtime.ROOT = ROOT


class OrdinaryRendezvousTests(unittest.TestCase):
    def setUp(self):
        milestone.MilestoneUnloadingTests.setUp(self)
        self.lua.execute('''
            c.settings={stopForUnload={getValue=function() return false end}}
            c.willWaitForUnloadToFinish=nil -- exercise the native full-wait distinction
            c.unloadState=c.states.WAITING_FOR_UNLOAD_ON_FIELD
            c.isDischarging=function() return discharging or false end
            c.isPipeMoving=function() return pipeMoving or false end
            harvester.rootNode.t=0; harvester.lastSpeedReal=0; v.lastSpeedReal=0
            pipe.x=0; pipe.z=0; pipe.t=0
            place(12.2,17.4,0)
            fill=19900
            -- Fill node is on the trailer, 9.8 m behind the tractor: the logged -7.6 m overshoot.
            u.getBestTargetNodeDistanceFromPipe=function()
                local _,_,z=localToLocal(trailer.rootNode,pipe,0,0,0); return -z
            end
            u.isBehindAndAlignedToCombine=nil; u.isInFrontAndAlignedToMovingCombine=nil
            u.driveBesideCombine=nil; u.startWaitingForSomethingToDo=nil
            u.renderText=function() end; u.info=function() end
            u.ppc.getLookaheadDistance=function() return 6 end
            CpUtil.isVehicleDebugActive=function() return false end
            u.pathfindingRange=AIDriveStrategyUnloadCombine.pathfindingRange
            CpMathUtil.clamp=function(v,a,b) return math.max(a,math.min(v,b)) end
            u.state=u.states.UNLOADING_MOVING_COMBINE
            c.unloader={get=function() return assigned end,set=function(_,vehicle) assigned=vehicle end,
                reset=function() assigned=nil end}
            c.unloaderToRendezvous={get=function() return nil end,reset=function() end}
            assigned=v
            u.releaseCombine=nil -- native deregistration must clear the combine's reservation
            c.timeToCallUnloader={get=function() return true end,set=function() end}
            c.findUnloader=nil -- exercise queue lead selection followed by the native stopped call
            Q.data(u)
            Q.plan={leads={[tostring(harvester.rootNode)]={trailer=tostring(v.rootNode)}}}
            u.getDistanceAndEteToVehicle=function(_,target)
                assert(target==harvester); return 20,5
            end
        ''')

    def test_logged_moving_then_full_transition_releases_and_recalls_behind(self):
        self.lua.execute('''
            c.state=c.states.WORKING; harvester.lastSpeedReal=10/3600
            assert(u:isOkToStartUnloadingCombine())
            u:unloadMovingCombine()
            assert(u.combineToUnload==harvester and u.state==u.states.UNLOADING_MOVING_COMBINE)
            -- Two seconds later the harvester is full. Both stop ahead of the pipe.
            c.state=c.states.UNLOADING_ON_FIELD; harvester.lastSpeedReal=0
            u:unloadMovingCombine()
            assert(u.speed==0)
            assert(u.state==u.states.IDLE and not u.combineToUnload and not assigned,
                'full stationary harvester still accepts an unreachable front fill node')
            c:callUnloaderWhenNeeded()
            local controller=u.pathfinderController
            assert(u.combineToUnload==harvester and u.state==u.states.WAITING_FOR_PATHFINDER)
            assert(controller.searchCount==1 and controller.goal.x==12.2)
            assert(math.abs(controller.goal.z+8.4)<0.0001)
            assert(controller.currentContext.maxFruitPercentValue==10)
            assert(controller.currentContext.offFieldPenaltyValue==7.5)
            assert(#controller.currentContext.vehiclesToIgnoreValue==0)
            assert(controller.currentContext.maxIterationsValue==52619)
            noExtraRecovery(u); assert(not c.queueFinishClearance and not stopped)
            controller.done(u,controller,true,{adjustForReversing=function() end},false)
            place(12.2,-8.4,0)
            assert(u:isOkToStartUnloadingCombine()); u:startUnloadingCombine()
            u:unloadMovingCombine()
            assert(u.speed>0 and u.state==u.states.UNLOADING_MOVING_COMBINE)
            -- Native transfer resumes harvesting; no parking/recovery state is installed.
            fill=fill-100; c.state=c.states.WORKING; harvester.lastSpeedReal=10/3600
            u:unloadMovingCombine(); noExtraRecovery(u)
            assert(u.combineToUnload==harvester and not c.queueFinishClearance and not stopped)
        ''')

    def test_stationary_front_call_plans_behind_instead_of_reentering_zero_speed(self):
        self.lua.execute('''
            u.state=u.states.IDLE; u.combineToUnload=nil
            assert(u:call(harvester,nil))
            assert(u.state==u.states.WAITING_FOR_PATHFINDER and u.pathfinderController.goal.z<0)
            noExtraRecovery(u)
        ''')

    def test_all_other_native_front_cases_are_preserved(self):
        for change in ('c.state=c.states.WORKING', 'harvester.lastSpeedReal=2/3600',
                       'c.settings.stopForUnload.getValue=function() return true end',
                       'v.lastSpeedReal=2/3600', 'discharging=true', 'pipeMoving=true',
                       'place(12.2,9.8,0)', 'place(12.2,5,0)',
                       'c.unloadState=c.states.WAITING_FOR_UNLOAD_IN_POCKET',
                       'c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK',
                       'c.unloadState=c.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW',
                       'c.unloadState=c.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED',
                       'c.alwaysNeedsUnloader=function() return true end',
                       'c.hasAutoAimPipe=function() return true end',
                       'u.augerWagon=true', 'u.fieldUnloadPositionNode=1', 'u.useGiantsUnload=true'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute(change+'''
                    local native=milestoneUnload.isInFrontAndAlignedToMovingCombine(u)
                    assert(u:isInFrontAndAlignedToMovingCombine()==native)
                    noExtraRecovery(u)
                ''')

    def test_close_rear_target_is_planned_only_for_the_stranded_front_case(self):
        self.lua.execute('''
            local rear=pipe.z-v.rootNode.z+2
            assert(not milestoneUnload.isPathfindingNeeded(u,v,pipe,12.2,-rear))
            assert(u:isPathfindingNeeded(v,pipe,12.2,-rear))
            local marker={x=12.2,z=v.rootNode.z,t=0}
            assert(not u:isPathfindingNeeded(v,marker,0,0))
            u.combineToUnload=nil
            u.getPipeOffsetReferenceNode=function() error('unassigned departure touched pipe') end
            assert(not u:isPathfindingNeeded(v,marker,0,0))
        ''')

    def test_manual_and_threshold_departure_keep_native_priority(self):
        for request in ('full=true', 'manual=true'):
            with self.subTest(request=request):
                self.setUp()
                self.lua.execute(request+'''
                    u:unloadMovingCombine()
                    assert(nativeDeparture and u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
                    assert(not u.pathfinderController.goal and not c.queueFinishClearance)
                ''')

    def test_native_crop_turn_and_misalignment_rejections_remain(self):
        for change in ('c.isPipeInFruit=function() return true end',
                       'c.course.isCloseToNextTurn=function() return true end',
                       'v.rootNode.t=math.pi/2'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute('c.state=c.states.WORKING; harvester.lastSpeedReal=10/3600; '+change+'''
                    assert(not u:isOkToStartUnloadingCombine()); noExtraRecovery(u)
                ''')


if __name__ == '__main__':
    unittest.main()
