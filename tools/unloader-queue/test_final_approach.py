"""Final-only stalled transfer recovery, complete rig checks and native ownership."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_yield as yielding
yielding.ROOT = yielding.runtime.ROOT = ROOT


class FinalApproachTests(unittest.TestCase):
    def setUp(self):
        yielding.YieldTests.setUp(self)
        self.lua.execute('''
            u.states={}
            for _,collection in ipairs({AIDriveStrategyUnloadCombine.myStates,AIDriveStrategyUnloadCombine.myCombineUnloadStates}) do
                for name,properties in pairs(collection) do u.states[name]={name=name,properties=properties} end
            end
            u.setNewState=function(self,state) self.state=state end
            u.state=u.states.UNLOADING_STOPPED_COMBINE
            u.combineToUnload=harvester
            final=true; fill=1000; full=false; manual=false
            c.isWaitingForUnloadAfterCourseEnded=function() return final end
            c.combineController={getFillLevel=function() return fill end}
            c.isUnloadFinished=function() return false end
            c.isTurning=function() return false end
            c.isAboutToTurn=function() return false end
            c.isAboutToReturnFromPocket=function() return false end
            u.getAllTrailersFull=function() return full end
            u.isDriveUnloadNowRequested=function() return manual end
            u.driveBesideCombine=function() nativeDrives=(nativeDrives or 0)+1; return 4,5 end
            u.ppc.setShortLookaheadDistance=function() end
            u.ppc.setNormalLookaheadDistance=function() end
            u.ppc.getCurrentWaypointIx=function() return 1 end
            u.getPipeOffset=function() return 0,0 end
            u.getPipeOffsetReferenceNode=function() return pipe end
            u.getCombinesMeasuredBackDistance=function() return 8 end
            u.getBestTargetNodeDistanceFromPipe=function() return pipe.z-v.rootNode.z end
            u.startPathfindingToWaitingCombine=function(self,x,z)
                assert(self.state==self.states.WAITING_FOR_PATHFINDER and self.combineToUnload==harvester)
                replan={x=x,z=z}
            end
            u.releaseCombine=function(self) self.combineJustUnloaded=self.combineToUnload; self.combineToUnload=nil end
            u.startMovingBackFromCombine=function(self,state,combine)
                assert(combine==harvester); nativeDeparture=true; self:setNewState(state)
            end
            u.startWaitingForSomethingToDo=function(self) self:releaseCombine(); self:setNewState(self.states.IDLE) end
            v.stopCurrentAIJob=function(_,message) stopped=message; Q.clearFinalUnload(u); u.state=u.states.IDLE end
            AIMessageCpErrorNoPathFound={new=function() return 'no safe path' end}
            pipe={x=0,z=15,t=0}
            place(0,0,0)
            function tick(ms)
                g_currentMission.time=g_currentMission.time+(ms or 100)
                Q.updateFinalUnload(u)
            end
            function stall()
                u:unloadStoppedCombine(); tick(12001); u:unloadStoppedCombine()
            end
            function reverseReady()
                for i=1,100 do
                    tick()
                    if stopped or u.queueFinalUnload.phase=='reversing' then return end
                end
                error('reverse validation did not complete')
            end
            function finishReverse()
                local goal=u.queueFinalUnload.goal
                place(goal.x,goal.z,goal.t)
                u:onLastWaypointPassed()
            end
            function atRunIn()
                place(replan.x,pipe.z+replan.z,0)
                u.state=u.states.DRIVING_TO_COMBINE
                u.course={getDistanceToLastWaypoint=function() return 0 end}
            end
        ''')

    def test_only_stationary_final_unload_is_watched(self):
        self.lua.execute('''
            final=false; u:unloadStoppedCombine(); tick(20000); u:unloadStoppedCombine()
            assert(not u.queueFinalUnload and nativeDrives==2)
            final=true; u:unloadStoppedCombine(); assert(u.queueFinalUnload)
            u.state=u.states.UNLOADING_MOVING_COMBINE; tick(); assert(not u.queueFinalUnload)
        ''')

    def test_motion_or_actual_grain_transfer_resets_watchdog(self):
        for progress in ('place(0,1,0)', 'fill=fill-10'):
            with self.subTest(progress=progress):
                self.setUp()
                self.lua.execute('''
                    u:unloadStoppedCombine(); tick(11000)
                '''+progress+'''
                    u:unloadStoppedCombine(); tick(11000); u:unloadStoppedCombine()
                    assert(u.queueFinalUnload.phase=='watching' and not stopped)
                    tick(1100); u:unloadStoppedCombine()
                    assert(u.queueFinalUnload.phase=='checkingReverse')
                ''')

    def test_checked_reverse_retains_assignment_and_replans_behind_pipe(self):
        self.lua.execute('''
            stall(); assert(u.queueFinalUnload.phase=='checkingReverse' and u.speed==0)
            reverseReady(); assert(u.queueFinalUnload.phase=='reversing')
            assert(u.combineToUnload==harvester and u.state==u.states.MOVING_BACK_BEFORE_PATHFINDING)
            local data=u.queueFinalUnload
            assert(data.course:isReverseAt(1))
            local _,_,lastZ=data.course:getWaypointPosition(data.course:getNumberOfWaypoints())
            assert(math.abs(lastZ+24.8)<0.01, 'reverse must track trailer axle, not tractor')
            tick(); assert(Q.finalUnloadSpeed(u,10)==5)
            finishReverse()
            assert(replan and replan.z<0 and u.combineToUnload==harvester and not data.world)
            assert(data.phase=='replanning' and u.state==u.states.WAITING_FOR_PATHFINDER)
        ''')

    def test_crop_obstacle_boundary_and_unsafe_articulation_fail_closed(self):
        for obstruction in ('densityCount=10', 'collision=1', 'place(0,-95,0)', 'trailer.rootNode.t=0.3'):
            with self.subTest(obstruction=obstruction):
                self.setUp()
                self.lua.execute(obstruction+'''
                    stall(); assert(stopped and not replan and not u.queueFinalUnload)
                ''')

    def test_mid_route_obstacle_stops_checked_reverse(self):
        self.lua.execute('''
            stall(); reverseReady(); tick(); assert(Q.finalUnloadSpeed(u,10)==5)
            collision=1; tick(); assert(Q.finalUnloadSpeed(u,10)==0 and not stopped)
            tick(12001); assert(stopped and not replan)
        ''')

    def test_full_or_manual_departure_during_reverse_keeps_native_exit(self):
        for request in ('full=true', 'manual=true'):
            with self.subTest(request=request):
                self.setUp()
                self.lua.execute('''
                    stall(); reverseReady();
                '''+request+'''
                    tick(); assert(u.queueFinalUnload.departing and not nativeDeparture)
                    finishReverse()
                    assert(nativeDeparture and not replan and not u.queueFinalUnload)
                    assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL and not u.combineToUnload)
                ''')

    def test_final_lane_checks_trailer_and_does_not_bypass_pending_validation(self):
        self.lua.execute('''
            stall(); reverseReady(); finishReverse(); atRunIn()
            assert(Q.deferFinalPipeApproach(u) and u.queueFinalUnload.phase=='checkingLane')
            assert(Q.deferFinalPipeApproach(u) and u.queueFinalUnload.phase=='checkingLane')
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                detector.collidingShapes=(z<-8) and 1 or 0 -- trailer only
            end
            tick(); assert(stopped and not u.queueFinalUnload)
        ''')

    def test_clear_lane_returns_to_native_approach_and_retries_are_bounded(self):
        self.lua.execute('''
            for attempt=1,2 do
                stall(); reverseReady(); finishReverse(); atRunIn()
                assert(replan.z<=-18)
                assert(Q.deferFinalPipeApproach(u))
                for i=1,100 do
                    tick()
                    if u.queueFinalUnload.phase=='watching' then break end
                end
                assert(u.queueFinalUnload.phase=='watching' and not stopped)
                assert(u.state==u.states.UNLOADING_STOPPED_COMBINE)
                assert(u.combineToUnload==harvester and not u.queueFinalUnload.world)
            end
            stall(); assert(stopped and not u.queueFinalUnload)
        ''')

    def test_target_change_manual_stop_and_emptying_release_resources(self):
        for change in ('u.combineToUnload=nil', 'u.state=u.states.IDLE', 'final=false'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute('''
                    stall(); local world=u.queueFinalUnload.world
                '''+change+'''
                    tick(); assert(not u.queueFinalUnload and not world.node and not replan)
                ''')

    def test_departure_cancels_owned_native_replan_before_callback(self):
        self.lua.execute('''
            stall(); reverseReady(); finishReverse()
            u.pathfinderController={pathfinder={}}
            u.queueData={deferredApproach={combine=harvester},waitingApproach={}}
            manual=true; tick()
            assert(nativeDeparture and not stopped and not u.queueFinalUnload)
            assert(not u.pathfinderController.pathfinder and not u.queueData.deferredApproach)
            assert(not u.queueData.waitingApproach and u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
        ''')

    def test_empty_target_after_reverse_uses_native_completion(self):
        self.lua.execute('''
            stall(); reverseReady(); fill=0
            c.queueFinishClearance={}
            c.isUnloadFinished=function() return true end
            c.getFillLevelPercentage=function() return 0 end
            u.areThereAnyCombinesOrLoaderLeftoverOnTheField=function() return false end
            tick(); assert(u.queueFinalUnload.phase=='reversing')
            finishReverse()
            assert(nativeDeparture and not replan and not u.queueFinalUnload)
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
        ''')

    def test_successful_combine_stop_keeps_checked_reverse_until_endpoint(self):
        self.lua.execute('''
            stall(); reverseReady()
            local data=u.queueFinalUnload; local course=data.course; local world=data.world
            harvester.active=false; harvester.queueFinishedEmptyCombine=true
            tick()
            assert(u.queueFinalUnload==data and u.course==course and world.node and not nativeDeparture)
            assert(u.state==u.states.MOVING_BACK_BEFORE_PATHFINDING)
            finishReverse()
            assert(nativeDeparture and not replan and not u.queueFinalUnload and not world.node)
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
        ''')

    def test_native_reverse_callback_without_marker_is_untouched(self):
        self.lua.execute('''
            u:setNewState(u.states.MOVING_BACK_BEFORE_PATHFINDING)
            u:onLastWaypointPassed()
            assert(u.state==u.states.IDLE and not stopped and not replan)
        ''')


if __name__ == '__main__':
    unittest.main()
