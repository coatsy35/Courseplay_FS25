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
            PathfinderUtil.setWorldPositionAndRotationOnTerrain=function(node,x,z,t)
                node.x=x; node.z=z; node.t=t
            end
            v.cpGetFieldPolygon=function()
                return {{x=-100,z=-100},{x=100,z=-100},{x=100,z=200},{x=-100,z=200}}
            end
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
            u.ppc.getRelevantWaypointIx=function() return 1 end
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
            local data=u.queueStoppedApproach
            assert(data and data.overshoot and controller.goal.z==data.farZ)
            assert(data.farZ<data.rearZ-data.runIn-10 and data.rearZ<=-11.4)
            assert(controller.currentContext.maxFruitPercentValue==10)
            assert(controller.currentContext.offFieldPenaltyValue==7.5)
            assert(#controller.currentContext.vehiclesToIgnoreValue==0)
            assert(controller.currentContext.maxIterationsValue==52619)
            assert(not c.queueFinishClearance and not u.queueFinalUnload and not stopped)
            controller.done(u,controller,true,{adjustForReversing=function() end},false)
            assert(not u:isOkToStartUnloadingCombine(), 'do not cut directly to pipe before rear entry')
            place(controller.goal.x,controller.goal.z,0)
            u:onLastWaypointPassed()
            assert(data.search and data.search.directOnly)
            for i=1,200 do
                g_currentMission.time=g_currentMission.time+30
                Q.updateStoppedApproach(u)
                if stopped or data.phase=='driving' then break end
            end
            assert(not stopped and data.phase=='driving')
            local previous
            for _,p in ipairs(data.path) do
                assert(not previous or p.z>=previous-0.01, 'run-in cannot circle/backtrack')
                assert(math.abs(p.t)<0.01, 'aligned rear entry must drive straight')
                previous=p.z
                place(p.x,p.z,p.t); g_currentMission.time=g_currentMission.time+100
                Q.updateStoppedApproach(u)
            end
            assert(not u:isOkToStartUnloadingCombine(), 'native admission waits for endpoint validation')
            u:onLastWaypointPassed()
            assert(not stopped and not u.queueStoppedApproach)
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
            assert(u.queueStoppedApproach and u.queueStoppedApproach.overshoot)
            assert(not c.queueFinishClearance and not u.queueFinalUnload)
        ''')

    def begin_rear_route(self):
        self.lua.execute('''
            u.state=u.states.IDLE; u.combineToUnload=nil; u:call(harvester,nil)
            controller=u.pathfinderController; data=u.queueStoppedApproach
            controller.done(u,controller,true,{adjustForReversing=function() end},false)
            place(controller.goal.x,controller.goal.z,0)
        ''')

    def test_angled_trailer_must_straighten_during_the_reserved_run_in(self):
        self.begin_rear_route()
        self.lua.execute('''
            local joint=trailer.joint.node
            trailer.rootNode.x=joint.x-6.5*math.sin(0.4)
            trailer.rootNode.z=joint.z-6.5*math.cos(0.4)
            trailer.rootNode.t=0.4; joint.t=0.4
            assert(not Q.pipeEntryAligned(u) and not u:isOkToStartUnloadingCombine())
            u:onLastWaypointPassed()
            for i=1,200 do
                Q.updateStoppedApproach(u)
                if stopped or data.phase=='driving' then break end
            end
            assert(not stopped and data.phase=='driving')
            assert(data.path[#data.path].z-data.path[1].z>=data.runIn)
            -- The tractor reaching the entry alone must not authorise unloading.
            place(data.goal.x,data.goal.z,0)
            trailer.rootNode.t=0.4; joint.t=0.4
            u:onLastWaypointPassed()
            assert(stopped and u.speed==0 and u.state~=u.states.UNLOADING_MOVING_COMBINE)
        ''')

    def test_blocked_forward_run_in_cannot_fall_back_to_circling(self):
        self.begin_rear_route()
        self.lua.execute('''
            u:onLastWaypointPassed(); local search=data.search
            assert(search.directOnly)
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                detector.collidingShapes=(z>-36 and z<-30) and 1 or 0
            end
            for i=1,200 do
                Q.updateStoppedApproach(u)
                if stopped then break end
            end
            assert(stopped and search.expanded==0 and not data.path and u.speed==0)
        ''')

    def test_crop_is_not_ignored_for_ordinary_rear_entry(self):
        self.begin_rear_route()
        self.lua.execute('''
            densityCount=10; u:onLastWaypointPassed()
            assert(stopped and u.speed==0 and not c.queueFinishClearance)
            assert(not Q.finalApproachTarget(u))
        ''')

    def test_missing_rig_geometry_cannot_bypass_the_required_rear_run_in(self):
        self.lua.execute('''
            W.model=function() return nil,'unsupported test rig' end
            u.state=u.states.IDLE; u.combineToUnload=nil; u:call(harvester,nil)
            assert(stopped and u.speed==0 and not u.pathfinderController.goal)
            assert(not u.queueStoppedApproach and not c.queueFinishClearance)
        ''')

    def test_native_search_keeps_its_lifecycle_before_the_far_rear_arrival(self):
        self.lua.execute('''
            u.state=u.states.IDLE; u.combineToUnload=nil; u:call(harvester,nil)
            local data=u.queueStoppedApproach; local pending=u.pathfinderController.pathfinder
            g_currentMission.time=180000; Q.updateStoppedApproach(u)
            assert(not stopped and data==u.queueStoppedApproach and data.phase=='pathfinding')
            assert(u.pathfinderController.pathfinder==pending and not u:isOkToStartUnloadingCombine())
            -- Manual target cancellation cannot leave a stale approach owning the tractor.
            harvester.active=false; Q.updateStoppedApproach(u)
            assert(not u.queueStoppedApproach and not u.combineToUnload and not stopped)
            assert(not u.pathfinderController.pathfinder)
        ''')

    def test_target_resuming_and_manual_departure_cancel_only_this_entry(self):
        for change in ('c.state=c.states.WORKING; harvester.lastSpeedReal=10/3600', 'manual=true'):
            with self.subTest(change=change):
                self.setUp(); self.begin_rear_route()
                self.lua.execute(change+'''
                    Q.updateStoppedApproach(u)
                    assert(not u.queueStoppedApproach and not stopped)
                    assert(not c.queueFinishClearance and not u.queueFinalUnload)
                    if manual then assert(nativeDeparture) end
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
