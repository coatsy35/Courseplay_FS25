"""End-of-course grain-combine rear entry; ordinary approaches stay native."""
from pathlib import Path
import sys
import unittest
SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_final_approach as final
final.ROOT = final.yielding.ROOT = final.yielding.runtime.ROOT = ROOT

class StoppedApproachTests(unittest.TestCase):
    def setUp(self):
        final.FinalApproachTests.setUp(self)
        self.lua.execute('''
            final=true; waiting=true; harvester.lastSpeedReal=0
            c.isWaitingForUnload=function() return waiting end
            c.hasAutoAimPipe=function() return false end
            c.willWaitForUnloadToFinish=function() return false end
            c.isReadyToUnload=function() return true end
            u.isBehindAndAlignedToCombine=function() return true end
            u.isInFrontAndAlignedToMovingCombine=function() return true end
            u.state=u.states.DRIVING_TO_COMBINE
            u.startCourseFollowingCombine=function(self) following=true; self.state=self.states.UNLOADING_MOVING_COMBINE end
            u.startPathfindingToWaitingCombine=function(self,x,z) replan={x=Q.stoppedApproachGoal(self,x,z)} end
            v.stopCurrentAIJob=function(_,message)
                stopped=message; Q.clearStoppedApproach(u); Q.clearFinalUnload(u); u.state=u.states.IDLE
            end
            u.ppc.getRelevantWaypointIx=function() return 1 end
            function bendTrailer(angle)
                local joint=trailer.joint.node
                trailer.rootNode.x=joint.x-6.5*math.sin(angle)
                trailer.rootNode.z=joint.z-6.5*math.cos(angle)
                trailer.rootNode.t=angle; joint.t=angle
                assert(W.model(v),'articulated fixture must remain a valid coupled rig')
            end
            function rearPath()
                u.state=u.states.WAITING_FOR_PATHFINDER
                local x,z=Q.stoppedApproachGoal(u,0,-8)
                assert(z<-25 and not u:isOkToStartUnloadingCombine())
                local course={}
                Q.stoppedApproachPath(u,true,course)
                u.course=course; u.state=u.states.DRIVING_TO_COMBINE
                place(x,pipe.z+z,0)
                assert(not u:isOkToStartUnloadingCombine(),'cut corner before full rig run-in')
                assert(Q.stoppedApproachLast(u))
            end
            function checkedRunIn()
                rearPath()
                for i=1,100 do
                    g_currentMission.time=g_currentMission.time+30
                    Q.updateStoppedApproach(u)
                    if stopped or u.queueStoppedApproach.phase=='driving' then break end
                end
                assert(not stopped and u.queueStoppedApproach.phase=='driving')
            end
        ''')

    def test_native_backup_retry_retains_checked_stopped_entry(self):
        self.lua.execute('''
            local context=nativeBackupFixture()
            u.state=u.states.WAITING_FOR_PATHFINDER
            local x,z=Q.stoppedApproachGoal(u,0,-8)
            local data=u.queueStoppedApproach; local started=data.started; data.context=context
            u:onPathfindingObstacleAtStart(u.pathfinderController,context,1,false,0,0)
            g_currentMission.time=2000; Q.updateStoppedApproach(u)
            assert(u.queueStoppedApproach==data and data.started==started)
            u:onLastWaypointPassed()
            assert(retried==1 and data.phase=='approaching' and u.state==u.states.DRIVING_TO_COMBINE)
            place(x,pipe.z+z,0)
            u:onLastWaypointPassed()
            assert(data.phase=='checking' and not u:isOkToStartUnloadingCombine())
        ''')

    def test_native_backup_does_not_spend_the_travel_progress_allowance(self):
        self.lua.execute('''
            local context=nativeBackupFixture()
            u.state=u.states.WAITING_FOR_PATHFINDER
            Q.stoppedApproachGoal(u,0,-8); u.queueStoppedApproach.context=context
            u:onPathfindingObstacleAtStart(u.pathfinderController,context,1,false,0,0)
            g_currentMission.time=91000; Q.updateStoppedApproach(u)
            assert(not stopped and u.queueStoppedApproach and u.state==u.states.MOVING_BACK_BEFORE_PATHFINDING)
            u:onLastWaypointPassed()
            assert(retried==1 and u.queueStoppedApproach.phase=='approaching')
            g_currentMission.time=180000; place(0,2,0); Q.updateStoppedApproach(u)
            assert(not stopped and u.queueStoppedApproach.progressTime==180000)
            g_currentMission.time=270001; Q.updateStoppedApproach(u)
            assert(stopped and not u.queueStoppedApproach)
        ''')

    def test_search_and_progressing_final_run_in_can_exceed_ninety_seconds(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER
            Q.stoppedApproachGoal(u,0,-8)
            g_currentMission.time=91000; Q.updateStoppedApproach(u)
            assert(not stopped and u.queueStoppedApproach.phase=='pathfinding')
            checkedRunIn()
            local data=u.queueStoppedApproach
            for i,p in ipairs(data.path) do
                place(p.x,p.z,p.t); g_currentMission.time=g_currentMission.time+500
                Q.updateStoppedApproach(u)
                assert(not stopped and u.queueStoppedApproach==data)
            end
            assert(g_currentMission.time>90000)
            u:onLastWaypointPassed()
            assert(not stopped and u.state==u.states.UNLOADING_STOPPED_COMBINE)
        ''')

    def test_occupied_final_rear_entry_retains_job_then_resumes_original_goal(self):
        for late in (False, True):
            with self.subTest(late=late):
                self.setUp()
                self.lua.execute('''
                    u.state=u.states.WAITING_FOR_PATHFINDER
                    local x,z=Q.stoppedApproachGoal(u,0,-8)
                    local blocker,blockerDriver,blockerHeader=makeHarvester(x,pipe.z+z,0)
                    blocker.getIsCpActive=function() return false end
                    g_currentMission.vehicleSystem.vehicles={harvester,v,blocker}
                    Q.data(u).waitingApproach={combine=harvester,x=0,z=-8}
                '''+('''
                    assert(not u:onPathfindingDoneToWaitingCombine({},false,nil,true))
                ''' if late else '''
                    AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine(u,0,-8)
                ''')+'''
                    assert(u.queueData.deferredApproach and not stopped)
                    g_currentMission.time=90000
                    Q.updateStoppedApproach(u); Q.resumeWaitingApproach(u)
                    assert(u.combineToUnload==harvester and u.queueData.deferredApproach and not stopped)
                    local original
                    u.startPathfindingToWaitingCombine=function(_,x,z) original={x=x,z=z} end
                    blocker.rootNode.x=80; blockerHeader.rootNode.x=80
                    g_currentMission.time=91001; Q.resumeWaitingApproach(u)
                    assert(not u.queueData.deferredApproach and original.x==0 and original.z==-8)
                    assert(not stopped and u.combineToUnload==harvester)
                ''')

    def test_permanently_occupied_final_goal_releases_reservation_without_stopping_job(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER
            local x,z=Q.stoppedApproachGoal(u,0,-8)
            local blocker=makeHarvester(x,pipe.z+z,0)
            g_currentMission.vehicleSystem.vehicles={harvester,v,blocker}
            assert(Q.deferWaitingApproach(u,0,-8))
            g_currentMission.time=120001; Q.resumeWaitingApproach(u)
            assert(not stopped and u.state==u.states.IDLE and not u.combineToUnload)
            assert(not u.queueStoppedApproach and not u.queueData.deferredApproach)
            assert(u.queueData.approachRetryAt>g_currentMission.time)
        ''')

    def test_native_hold_without_physical_progress_does_not_hide_a_stalled_approach(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER
            Q.stoppedApproachGoal(u,0,-8); Q.stoppedApproachPath(u,true,{})
            u.state=u.states.DRIVING_TO_COMBINE
            u.isBeingHeld=function() return true end
            g_currentMission.time=89000; Q.updateStoppedApproach(u); assert(not stopped)
            g_currentMission.time=90001; Q.updateStoppedApproach(u); assert(stopped)
        ''')

    def test_leaving_final_scope_finishes_native_backup_and_retains_departure_intent(self):
        for depart in (False, True):
            with self.subTest(depart=depart):
                self.setUp()
                self.lua.execute('''
                    local context=nativeBackupFixture()
                    u.state=u.states.WAITING_FOR_PATHFINDER
                    x,z=Q.stoppedApproachGoal(u,0,-8); u.queueStoppedApproach.context=context
                    u:onPathfindingObstacleAtStart(u.pathfinderController,context,1,false,0,0)
                    u.requestDriveUnloadNow=function() manual=true end
                '''+('manual=true' if depart else '')+'''
                    Q.updateStoppedApproach(u)
                    local data=u.queueStoppedApproach; local course=u.course
                    final=false; manual=false; g_currentMission.time=91000
                    Q.updateStoppedApproach(u)
                    assert(not stopped and u.queueStoppedApproach==data and u.course==course)
                    assert(u.state==u.states.MOVING_BACK_BEFORE_PATHFINDING)
                    u:onLastWaypointPassed()
                    assert(retried==1 and u.queueStoppedApproach==data)
                    assert(u.state==u.states.DRIVING_TO_COMBINE)
                    place(x,pipe.z+z,0)
                    c.willWaitForUnloadToFinish=function() return true end
                    -- Exercise the endpoint before the next update as well.
                    u:onLastWaypointPassed()
                    assert(not stopped and not u.queueStoppedApproach)
                '''+('''
                    assert(nativeDeparture and u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
                ''' if depart else '''
                    assert(u.state==u.states.UNLOADING_STOPPED_COMBINE and not following)
                    assert(u.combineToUnload==harvester and not u.queueStationaryPipe)
                '''))

    def test_initial_admission_requires_trailer_heading_lateral_and_fill_node(self):
        self.lua.execute('''
            assert(u:isOkToStartUnloadingCombine())
            bendTrailer(0.3); assert(not u:isOkToStartUnloadingCombine())
            assert(u:isPathfindingNeeded(v,pipe,0,-8),'nearby wrong-angle rig must replan')
            place(2,0,0); assert(not u:isOkToStartUnloadingCombine())
            place(0,25,0); assert(not u:isOkToStartUnloadingCombine(),'fill node in front')
            place(0,0,0); assert(u:isOkToStartUnloadingCombine(),'manually aligned rig cannot reattach')
            waiting=false; trailer.rootNode.t=0.3; assert(u:isOkToStartUnloadingCombine(),'ordinary moving admission altered')
        ''')

    def test_waiting_without_stop_setting_starts_stopped_then_follows_on_resume(self):
        self.lua.execute('''
            u:startUnloadingCombine()
            assert(u.state==u.states.UNLOADING_STOPPED_COMBINE and not following)
            waiting=false; harvester.lastSpeedReal=0.002
            u:unloadStoppedCombine()
            assert(following and u.state==u.states.UNLOADING_MOVING_COMBINE and u.speed==0)
        ''')

    def test_checked_rear_run_in_keeps_assignment_until_complete_rig_aligned(self):
        self.lua.execute('''
            checkedRunIn()
            local data=u.queueStoppedApproach
            assert(u.combineToUnload==harvester and not u:isOkToStartUnloadingCombine())
            assert(data.course:getNumberOfWaypoints()==#data.path,'checked curve was thinned')
            for i,p in ipairs(data.path) do
                local x,_,z=data.course:getWaypointPosition(i); assert(x==p.x and z==p.z)
            end
            local poses=W.poses(data.world.model)
            for i=2,#data.path do poses=H.advance(data.world.model,poses,data.path[i]); assert(W.clear(data.world,poses)) end
            for _,p in ipairs(poses) do assert(math.abs(p.t-data.goal.t)<math.rad(10)) end
            place(data.goal.x,data.goal.z,data.goal.t)
            u:onLastWaypointPassed()
            assert(not u.queueStoppedApproach and not data.world.node)
            assert(u.combineToUnload==harvester and u.state==u.states.UNLOADING_STOPPED_COMBINE)
        ''')

    def test_real_articulated_trailer_straightens_on_checked_run_in(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER
            local x,z=Q.stoppedApproachGoal(u,0,-8)
            Q.stoppedApproachPath(u,true,{})
            u.course=u.queueStoppedApproach.course; u.state=u.states.DRIVING_TO_COMBINE
            place(x,pipe.z+z,0); bendTrailer(0.3)
            assert(Q.stoppedApproachLast(u))
            for i=1,100 do
                g_currentMission.time=g_currentMission.time+30; Q.updateStoppedApproach(u)
                if stopped or u.queueStoppedApproach.phase=='driving' then break end
            end
            assert(not stopped and u.queueStoppedApproach.phase=='driving')
            local data=u.queueStoppedApproach; local poses=W.poses(data.world.model)
            for i=2,#data.path do poses=H.advance(data.world.model,poses,data.path[i]); assert(W.clear(data.world,poses)) end
            for _,pose in ipairs(poses) do assert(math.abs(pose.t)<math.rad(10)) end
        ''')

    def test_arrival_at_endpoint_with_angled_trailer_never_starts_unloading(self):
        self.lua.execute('''
            checkedRunIn(); local goal=u.queueStoppedApproach.goal
            place(goal.x,goal.z,goal.t); trailer.rootNode.t=0.3
            u:onLastWaypointPassed(); assert(stopped and not u.queueStoppedApproach)
        ''')

    def test_checked_run_in_does_not_cross_crop_or_adjacent_header(self):
        for obstruction in ('densityCount=10', 'collision=1'):
            with self.subTest(obstruction=obstruction):
                self.setUp()
                self.lua.execute('''rearPath(); '''+obstruction+'''
                    Q.updateStoppedApproach(u)
                    assert(stopped and not u.queueStoppedApproach)
                ''')

    def test_live_obstacle_holds_run_in_then_times_out_safely(self):
        self.lua.execute('''
            checkedRunIn()
            u.ppc.getCurrentWaypointIx=function() return 30 end -- look-ahead is well ahead of tractor
            Q.updateStoppedApproach(u)
            assert(Q.stoppedApproachSpeed(u,15)==5)
            collision=1; g_currentMission.time=g_currentMission.time+201; Q.updateStoppedApproach(u); assert(Q.stoppedApproachSpeed(u,15)==0)
            g_currentMission.time=g_currentMission.time+12001; Q.updateStoppedApproach(u)
            assert(stopped)
        ''')

    def test_full_and_manual_departure_during_run_in_or_pathfinding_are_native(self):
        for phase in ('pathfinding','driving'):
            for request in ('full=true','manual=true'):
                with self.subTest(phase=phase,request=request):
                    self.setUp()
                    self.lua.execute(('''
                        u.state=u.states.WAITING_FOR_PATHFINDER; Q.stoppedApproachGoal(u,0,-8)
                        u.pathfinderController={pathfinder={}}
                    ''' if phase=='pathfinding' else 'checkedRunIn()')+request+'''
                        Q.updateStoppedApproach(u)
                        assert(nativeDeparture and not u.queueStoppedApproach and not u.combineToUnload)
                        assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
                        assert(not u.pathfinderController or not u.pathfinderController.pathfinder)
                    ''')

    def test_resumed_combine_retires_owned_path_and_returns_to_native_allocation(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER; Q.stoppedApproachGoal(u,0,-8)
            u.pathfinderController={pathfinder={}}; waiting=false
            Q.updateStoppedApproach(u)
            assert(not u.queueStoppedApproach and not u.pathfinderController.pathfinder)
            assert(not u.combineToUnload and u.state==u.states.IDLE)
        ''')

    def test_aligned_run_in_hands_back_to_native_follow_when_combine_resumes(self):
        self.lua.execute('''
            checkedRunIn(); local goal=u.queueStoppedApproach.goal
            place(goal.x,goal.z,goal.t); waiting=false; harvester.lastSpeedReal=0.002
            Q.updateStoppedApproach(u)
            assert(not u.queueStoppedApproach and following and u.combineToUnload==harvester)
            assert(u.state==u.states.UNLOADING_MOVING_COMBINE and u.speed==0)
        ''')

    def test_outgoing_trailer_guard_precedes_rear_goal_and_retains_assignment(self):
        self.lua.execute('''
            Q.deferWaitingApproach=function(driver,x,z)
                assert(driver==u and x==0 and z==-8)
                deferred=true; return true
            end
            Q.stoppedApproachGoal=function() error('outgoing trailer guard bypassed') end
            AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine(u,0,-8)
            assert(deferred and u.combineToUnload==harvester and not replan)
        ''')

    def test_target_change_cannot_accept_stale_approach_callback(self):
        self.lua.execute('''
            u.state=u.states.WAITING_FOR_PATHFINDER; Q.stoppedApproachGoal(u,0,-8)
            u.combineToUnload=nil; Q.stoppedApproachPath(u,true,{})
            assert(not u.queueStoppedApproach)
        ''')

    def test_stationary_moving_mode_stall_replans_without_losing_assignment(self):
        self.lua.execute('''
            u.state=u.states.UNLOADING_MOVING_COMBINE
            assert(not Q.watchStoppedMovingUnload(u))
            g_currentMission.time=12001
            assert(Q.watchStoppedMovingUnload(u))
            assert(replan and u.combineToUnload==harvester and u.queueStoppedApproach)
            assert(u.state==u.states.WAITING_FOR_PATHFINDER and u.speed==0)
        ''')

    def test_actual_transfer_or_motion_prevents_stall_replan(self):
        for progress in ('fill=fill-10','place(0,1,0)'):
            with self.subTest(progress=progress):
                self.setUp()
                self.lua.execute('''
                    u.state=u.states.UNLOADING_MOVING_COMBINE; Q.watchStoppedMovingUnload(u)
                    g_currentMission.time=11000
                '''+progress+'''
                    Q.watchStoppedMovingUnload(u); g_currentMission.time=20000
                    assert(not Q.watchStoppedMovingUnload(u) and not replan)
                ''')

if __name__ == '__main__':
    unittest.main()
