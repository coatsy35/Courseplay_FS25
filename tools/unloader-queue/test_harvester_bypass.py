"""Parked-trailer recovery through production turn lifecycle and queue hooks."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE=Path(__file__).resolve().parents[2]
ROOT=Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0,str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT=ROOT


class HarvesterBypassTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT=ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine','AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT/f'scripts/ai/strategies/{name}.lua').read_text())
        source=(ROOT/'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua').read_text()
        for method in ('startRecoveryTurn', 'resumeFieldworkAfterTurn'):
            start=source.index('function AIDriveStrategyFieldWorkCourse:'+method+'(')
            end=source.index('\nend',start)+4
            self.lua.execute(source[start:end])
        runtime.load_queue(self.lua)
        self.lua.execute('''
            Q=CpUnloaderQueue; g_currentMission.time=10000
            local setting=function(v) return {getValue=function() return v end} end
            settings={turnSpeed=setting(10),reverseSpeed=setting(8),fieldSpeed=setting(15)}
            hv={spec_combine={},size={width=3.5},active=true,stopped=true,
                getCpSettings=function() return settings end,getChildVehicles=function() return {} end,
                getIsCpActive=function(self) return self.active end,
                getAIDirectionNode=function() return {x=0,z=0,t=0} end,
                stopCurrentAIJob=function() stopped=true end}
            tv={stopped=true,getIsCpActive=function() return true end}
            tv.getAIDirectionNode=function() return {x=0,z=20,t=0} end
            AIUtil.isStopped=function(v) return v.stopped end
            AIUtil.getSteeringParameters=function() return nil,0 end
            AIUtil.hasChainedAttachments=function() return false end
            AIUtil.getDirectionNodeToReverserNodeOffset=function() return 0 end
            AIMessageCpErrorNoPathFound={new=function() return {} end}
            u=setmetatable({vehicle=tv,states=AIDriveStrategyUnloadCombine.myStates},AIDriveStrategyUnloadCombine)
            u.settings={fullThreshold=setting(85)}; full=false; manual=false
            u.getAllTrailersFull=function() return full end
            u.isDriveUnloadNowRequested=function() return manual end
            u.setMaxSpeed=function(self,speed) self.speed=speed end; u.debug=function() end
            tv.getCpDriveStrategy=function() return u end
            c=setmetatable({vehicle=hv,states={TURNING={},WORKING={}}},AIDriveStrategyCombineCourse)
            c.state=c.states.TURNING; c.turningRadius=9; c.workWidth=15.2
            hv.getCpDriveStrategy=function() return c end
            c.debug=function() end; c.settings=settings
            c.raiseImplements=function() raised=true end
            c.raiseControllerEvent=function() end
            c.raiseControllerEventWithLambda=function(_,event,fn) fn(true) end
            c.getLoweringDurationMs=function() return 1000 end
            c.getFrontAndBackMarkers=function() return 4,-6 end
            c.getAllowReversePathfinding=function() return true end
            c.getWorkWidth=function() return 15.2 end
            c.isTurnOnFieldActive=function() return true end
            c.setPathfindingDoneCallback=function(self,owner,callback) self.callbackOwner=owner; self.callback=callback end
            c.startRecoveryTurn=AIDriveStrategyFieldWorkCourse.startRecoveryTurn
            c.ppc={restorePreviouslyRegisteredListeners=function() restored=true end,
                registerListeners=function() end,setCourse=function(_,course) installed=course end,
                initialize=function(_,ix) assert(ix==1) end}
            c.proximityController={unregisterBlockingObjectListener=function() end,
                registerBlockingObjectListener=function(self,owner,fn) self.owner=owner; self.callback=fn end}
            target={x=20,z=30,t=0}
            context={turnEndWpIx=953,setStraightEntryDistance=function() end,
                getTurnEndNodeAndOffsets=function() return target,-4 end,
                getBoundaryId=function() return 'F' end,
                appendPathfinderEndingTurnCourse=function() return 0 end}
            c.turnContext=context; c.course=Course(hv,{{x=0,z=0},{x=0,z=10}},false)
            original=c.course
            c.ppc.getCourse=function() return installed or original end
            c.ppc.getRelevantWaypointIx=function() return 1 end
            c.getCurrentCourse=function() return c.ppc:getCourse() end
            c.getWorkWidth=function() return 15.2 end
            productionPriority=Q.priority
            Q.priority=function(driver,vehicle)
                assert(driver==u and vehicle==hv); yielded=true
                Q.take(driver,'yield'); return true
            end
            old=setmetatable({vehicle=hv,driveStrategy=c,turnContext=context,ppc=c.ppc,
                proximityController=c.proximityController,states={TURNING={}},turningRadius=9},CourseTurn)
            old.state=old.states.TURNING; c.aiTurn=old
            calls=0
            productionGenerate=Q.generateHarvesterBypass
            Q.generateHarvesterBypass=function(self)
                self.queueBypassConstraints={isValidNode=function() return true end}
                return CourseTurn.generatePathfinderTurn(self,false)
            end
            nativeTurnSearch=PathfinderUtil.findPathForTurn
            PathfinderUtil.findPathForTurn=function(...)
                args={...}; calls=calls+1; return {isActive=function() return false end},{done=false}
            end
            Q.take(u,'prepare')
        ''')

    def test_vehicle_block_callback_starts_native_recovery_to_unchanged_target(self):
        self.lua.execute('''
            c:onBlockingVehicle(tv,false)
            assert(c.aiTurn~=old and c.aiTurn.turnContext==context and c.course==original)
            assert(raised and restored and c.aiTurn.state==c.aiTurn.states.PREPARING_RECOVERY)
            assert(Q.holdForHarvesterBypass(u) and u.speed==0)
            c.aiTurn:getDriveData(33)
            assert(calls==1 and args[1]==hv and args[3]==target and args[4]==-4)
            assert(args[5]==9 and args[6] and args[8]==15.2 and args[9]==-6 and args[10])
            assert(c.callbackOwner==c.aiTurn and c.callback==c.aiTurn.onPathfindingDone)
            assert(c.proximityController.callback==c.aiTurn.onBlocked)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(installed==c.aiTurn.turnCourse and c.aiTurn.state==c.aiTurn.states.TURNING)
            assert(c.course==original and context.turnEndWpIx==953 and not stopped)
        ''')

    def test_inactive_old_pathfinder_does_not_disable_bypass(self):
        self.lua.execute('c.pathfinder={isActive=function() return false end}; assert(Q.tryHarvesterBypass(c,tv,false))')

    def test_blocked_work_starter_recovers_to_same_row_start_and_releases_queue(self):
        self.lua.execute('''
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            starter={turnContext=context,states={DRIVING_TO_ROW={},APPROACHING_ROW={}}}
            starter.state=starter.states.DRIVING_TO_ROW; c.workStarter=starter
            Q.take(u,'yield'); u.queueData.yieldRequests={[hv]={}}
            assert(not u:isAllowedToBeCalled())
            c:onBlockingVehicle(tv,false)
            assert(c.state==c.states.TURNING and not c.workStarter)
            assert(c.aiTurn.turnContext==context and c.course==original)
            assert(Q.holdForHarvesterBypass(u) and not yielded)
            assert(not u:isAllowedToBeCalled() and not u:call(hv,nil))
            c.aiTurn:getDriveData(33)
            assert(calls==1 and args[3]==target and args[4]==-4)
            c.callback(c.callbackOwner,{{x=0,y=0},{x=10,y=-10},{x=20,y=-20}})
            assert(c.aiTurn.state==c.aiTurn.states.TURNING and context.turnEndWpIx==953)
            -- Exercise native turn completion, listener restoration and saved
            -- fieldwork resumption, not just a mocked state change.
            c.fieldWorkCourse=original
            original.getNextFwdWaypointIxFromVehiclePosition=function(_,ix)
                assert(ix==953); return 1,true
            end
            c.ppc.setNormalLookaheadDistance=function() end
            c.ppc.isReversing=function() return false end
            c.aiTurn.getLowerImplementNode=function() return 0 end
            context.shouldPlowBeOnTheLeft=function() return false end
            c.startWaitingForLower=function(self) self.state=self.states.WORKING end
            c.lowerImplements=function() lowered=true end
            c.startCourse=function(self,course,ix) assert(course==original and ix==1); self.course=course end
            c.resumeFieldworkAfterTurn=AIDriveStrategyFieldWorkCourse.resumeFieldworkAfterTurn
            restored=false; c.aiTurn:resumeFieldworkAfterTurn(953)
            assert(restored and lowered and c.course==original)
            assert(not Q.holdForHarvesterBypass(u))
            assert(u:isAllowedToBeCalled() and not u.queueData.yieldRequests)
        ''')

    def test_work_starter_already_lowering_is_not_replaced_by_recovery(self):
        self.lua.execute('''
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            starter={turnContext=context,states={DRIVING_TO_ROW={},APPROACHING_ROW={}}}
            starter.state=starter.states.APPROACHING_ROW; c.workStarter=starter
            assert(not Q.tryHarvesterBypass(c,tv,false))
            assert(c.workStarter==starter and c.aiTurn==old and c.course==original)
        ''')

    def test_failed_connector_detour_releases_held_trailer_to_yield(self):
        self.lua.execute('''
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            local starter={turnContext=context,states={DRIVING_TO_ROW={}}}
            starter.state=starter.states.DRIVING_TO_ROW; c.workStarter=starter
            assert(Q.tryHarvesterBypass(c,tv,false))
            c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(yielded and c.queueBypass.waiting and not u.queueData.bypass)
            assert(u.queueData.operation=='yield' and not u:isAllowedToBeCalled())
            for i=1,10 do g_currentMission.time=g_currentMission.time+1000; c.aiTurn:getDriveData(33) end
            assert(calls==1,'unchanged blocked connector must not start repeated searches')
        ''')

    def test_work_start_travel_has_live_header_guard_without_full_route_stop(self):
        self.install_guard_geometry()
        self.lua.execute('''
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            assert(Q.guardHarvesterTurn(c,10)==0 and bypassCalls==1)
            c.queueTurnGuard=nil
            tv.rootNode.z=75
            assert(Q.guardHarvesterTurn(c,10)==10)
            assert(not c.queueTurnPreflight and not c.queueRecoveryFailure)
        ''')

    def test_real_native_planner_routes_header_around_parked_rig(self):
        self.lua.execute('''
            CpUtil.getDefaultCollisionFlags=function() return 334339 end
            CollisionFlag={TERRAIN_DELTA=0}
            require('HybridAStar'); require('PathfinderContext')
        ''')
        fixture=(SOURCE/'tools/unloader-queue/connector-search-fixture.lua').read_text()
        self.lua.execute(fixture.split('v.getRootVehicle=',1)[0])
        self.lua.execute('''
            local origin={x=0,z=0,t=0}
            hv.getAIDirectionNode=function() return origin end
            hv.getRootVehicle=function(self) return self end
            hv.getCpSettings=function() return settings end
            settings.penaltyFactor={getValue=function() return 1 end}
            settings.useJps={getValue=function() return true end}
            CpFieldUtil.getFieldNumUnderVehicle=function() return 11 end
            target.x=targetX or 0; target.z=targetZ or 80; target.t=targetT or 0
            local G=CpUnloaderQueueGeometry
            obstacles={G.rectangle({x=0,z=40,heading=0},{width=obstacleWidth or 3.5,length=18},0)}
            local validation=PathfinderConstraints(PathfinderContext(hv))
            assert(not validation:isValidNode(State3D(0,-40,CpMathUtil.angleFromGame(0)),false,true),'fixture must detect trailer collision')
            Q.generateHarvesterBypass=productionGenerate
            PathfinderUtil.findPathForTurn=nativeTurnSearch
            assert(Q.tryHarvesterBypass(c,tv,false))
            c.aiTurn.queueForwardOnly=forceForward
            c.aiTurn:getDriveData(33)
            for i=1,2000 do
                if installed or stopped then break end
                if c.queueBypass.retry then c.aiTurn:getDriveData(33) end
                if c.pathfinder and c.pathfinder:isActive() then
                    local result=c.pathfinder:resume()
                    if result.done then c.callback(c.callbackOwner,result.path) end
                end
            end
            assert(installed and not stopped,'native planner must find a route around the rig')
            local outside=false
            for i=1,installed:getNumberOfWaypoints() do
                local x,_,z=installed:getWaypointPosition(i)
                local box=G.rectangle({x=x,z=z,heading=installed:getWaypointYRotation(i)},
                    {width=16.6,length=13},0)
                assert(not G.overlap(box,obstacles[1]),string.format('header intersects at %d x%.2f z%.2f yaw%.2f reverse%s',i,x,z,installed:getWaypointYRotation(i),tostring(installed:isReverseAt(i))))
                if math.abs(x)>11 then outside=true end
                if forceForward then assert(not installed:isReverseAt(i),'forward route contains reversing') end
            end
            assert(outside and probeCount>10 and c.course==original and context.turnEndWpIx==953)
        ''')

    def test_real_planner_side_detours_for_head_on_trailer_and_wide_parked_combine(self):
        for scenario in ('targetX=-30; targetT=math.pi; forceForward=true',
                         'obstacleWidth=16.6; forceForward=true'):
            with self.subTest(scenario=scenario):
                self.setUp()
                self.lua.execute(scenario)
                self.test_real_native_planner_routes_header_around_parked_rig()

    def test_real_planner_keeps_distant_connector_target_after_local_block(self):
        self.lua.execute('''
            targetZ=475; forceForward=true
            c.course=Course(hv,{{x=0,z=0},{x=0,z=20},{x=0,z=60},
                {x=0,z=120},{x=0,z=240},{x=0,z=475}},true)
            original=c.course
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            local starter={turnContext=context,states={DRIVING_TO_ROW={}}}
            starter.state=starter.states.DRIVING_TO_ROW; c.workStarter=starter
        ''')
        self.test_real_native_planner_routes_header_around_parked_rig()
        self.lua.execute('''
            local _,_,z=installed:getWaypointPosition(installed:getNumberOfWaypoints())
            assert(z>460 and c.aiTurn.queueConnectorCourse==original)
            assert(original:getNumberOfWaypoints()==6)
            assert(c.aiTurn.queueConnectorJoin==4,'search must rejoin locally, not target 475m away')
            assert(c.aiTurn.queueBypassValidationEnd<installed:getNumberOfWaypoints())
        ''')
        self.install_guard_geometry()
        self.lua.execute('''
            c.queueTurnPreflight={course=installed,unknown=true,attempts=2,checked=0}
            Q.yieldArea=function(_,horizon,limit)
                assert(not limit,'long connector must not receive full-turn preflight')
                return function() return false end
            end
            assert(Q.guardHarvesterTurn(c,10)==10 and not c.queueTurnPreflight)
        ''')

    def test_unchanged_long_connector_tail_does_not_exhaust_local_validation(self):
        self.lua.execute('''
            targetZ=2500; forceForward=true
            local points={{x=0,z=0},{x=0,z=20},{x=0,z=60},{x=0,z=120}}
            for z=125,2500,5 do points[#points+1]={x=0,z=z} end
            c.course=Course(hv,points,true); original=c.course
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            local starter={turnContext=context,states={DRIVING_TO_ROW={}}}
            starter.state=starter.states.DRIVING_TO_ROW; c.workStarter=starter
        ''')
        self.test_real_native_planner_routes_header_around_parked_rig()
        self.lua.execute('''
            local _,_,z=installed:getWaypointPosition(installed:getNumberOfWaypoints())
            assert(z==2500 and c.aiTurn.queueBypassValidationEnd<200)
            assert(original:getNumberOfWaypoints()==480)
        ''')

    def test_live_pathfinder_keeps_ownership(self):
        self.lua.execute('c.pathfinder={isActive=function() return true end}; assert(not Q.tryHarvesterBypass(c,tv,false)); assert(c.aiTurn==old)')

    def test_failed_search_never_uses_calculated_turn_or_skips_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.generateCalculatedTurn=function() error('unsafe fallback') end
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(not stopped and not installed and c.queueBypass.retry and not yielded)
            recovery:getDriveData(33); assert(calls==2)
            c.callback(c.callbackOwner,nil)
            assert(not stopped and not installed and yielded and c.queueBypass.waiting)
            assert(not u.queueData.bypass and u.queueData.operation=='yield')
            for i=1,10 do g_currentMission.time=g_currentMission.time+10000; recovery:getDriveData(33) end
            assert(calls==2,'unchanged blocker must not trigger repeated searches')
            tv.getAIDirectionNode=function() return {x=10,z=20,t=0} end
            recovery:getDriveData(33); assert(calls==3 and not c.queueBypass.waiting)
        ''')

    def test_recovery_block_listener_does_not_skip_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            c.proximityController.callback(recovery); assert(not stopped)
            recovery.state=recovery.states.TURNING
            c.proximityController.callback(recovery); assert(not stopped and c.queueBypass.retry)
        ''')

    def test_final_adjusted_course_is_rejected_if_it_intersects_an_obstacle(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery:getDriveData(33)
            local checks=0
            recovery.queueBypassConstraints.isValidNode=function(_,node)
                checks=checks+1; return node.x<5
            end
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(not stopped and checks>1 and c.queueBypass.retry and context.turnEndWpIx==953)
            assert(not installed,'invalid final course must never be installed')
        ''')

    def test_moving_full_assigned_and_native_departing_trailers_do_not_get_held(self):
        for condition in ('tv.stopped=false','hv.stopped=false','full=true','manual=true',
                          'u.combineToUnload=hv','u.queueData.nativeDeparture=true'):
            with self.subTest(condition=condition):
                self.setUp()
                self.lua.execute(condition+'; assert(not Q.tryHarvesterBypass(c,tv,false)); assert(c.aiTurn==old)')

    def test_special_callback_turn_reverse_block_and_working_row_are_excluded(self):
        self.lua.execute('''
            assert(not Q.tryHarvesterBypass(c,tv,true))
            old.callbackFunction=function() end; assert(not Q.tryHarvesterBypass(c,tv,false))
            old.callbackFunction=nil; c.state=c.states.WORKING; assert(not Q.tryHarvesterBypass(c,tv,false))
        ''')

    def test_other_harvester_yield_request_is_not_overridden(self):
        self.lua.execute('u.queueData.yieldRequests={[{}]={}}; assert(not Q.tryHarvesterBypass(c,tv,false))')

    def test_success_stop_and_fullness_release_both_hold_references(self):
        for change in ('c.state=c.states.WORKING','hv.active=false','full=true','manual=true'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); '+change+
                                 '; assert(not Q.holdForHarvesterBypass(u)); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_cancel_invalidates_both_hold_references(self):
        self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); Q.cancel(u); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_timed_out_recovery_requests_yield_without_deleting_combine_driver(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); g_currentMission.time=130001
            assert(not Q.holdForHarvesterBypass(u)); assert(not stopped and c.queueBypass.waiting and yielded)
            assert(not u.queueData.bypass)
        ''')

    def test_parked_combine_without_live_driver_can_be_bypassed(self):
        self.lua.execute('''
            tv.spec_combine={}; tv.getCpDriveStrategy=function() return nil end
            assert(Q.tryHarvesterBypass(c,tv,false))
            assert(not c.queueBypass.driver and not u.queueData.bypass)
            c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(installed and not stopped and c.course==original)
        ''')

    def test_forward_retry_is_deferred_out_of_completion_callback(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(calls==1 and recovery.queueForwardOnly)
            recovery.generatePathfinderTurn=function(self)
                assert(self.queueForwardOnly); calls=calls+1
            end
            recovery:getDriveData(33); assert(calls==2)
        ''')

    def test_failed_bypass_enters_real_queue_yield_and_preserves_waiting_combine(self):
        self.lua.execute('''
            Q.priority=productionPriority
            u.releaseCombine=function(self) self.combineToUnload=nil end
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(Q.owns(u) and u.queueData.operation=='yield')
            assert(u.queueData.yieldRequests[hv] and c.queueBypass.waiting)
            assert(not u.queueData.bypass and not stopped and c.course==original)
        ''')

    def test_no_reverse_setting_does_not_install_unchecked_initial_backup(self):
        self.lua.execute('''
            c.getAllowReversePathfinding=function() return false end
            assert(Q.tryHarvesterBypass(c,tv,false)); c.aiTurn:getDriveData(33)
            assert(calls==1 and not installed and c.aiTurn.state==c.aiTurn.states.WAITING_FOR_PATHFINDER)
        ''')

    def test_failed_recovery_creation_does_not_change_queue_state(self):
        self.lua.execute('''
            old.startRecoveryTurn=function() end; local state=u.state
            assert(not Q.tryHarvesterBypass(c,tv,false)); assert(u.state==state and not u.queueData.bypass)
        ''')

    def install_guard_geometry(self):
        self.lua.execute('''
            hv.rootNode={x=0,z=0,t=0}; hv.lastSpeedReal=0
            tv.rootNode={x=0,z=19,t=math.pi/2}; tv.spec_combine={}
            tv.getCpDriveStrategy=function() return nil end
            hv.getAIDirectionNode=function() return hv.rootNode end
            tv.getAIDirectionNode=function() return tv.rootNode end
            g_currentMission.vehicleSystem={vehicles={hv,tv}}
            c.course=Course(hv,{{x=0,z=0},{x=0,z=5},{x=0,z=10},{x=0,z=20},{x=0,z=30}},false)
            original=c.course
            CpUnloaderQueueWorld.currentBodies=function(v)
                if v==hv then return {
                    {body={left=2,right=-2,front=4,back=-5},pose=hv.rootNode},
                    {body={left=7.6,right=-7.6,front=1,back=-1},pose={x=0,z=7,t=0}}}
                end
                return {{body={left=7.6,right=-7.6,front=6,back=-6},pose=v.rootNode}}
            end
            bypassCalls=0
            c.onBlockingVehicle=function(self,vehicle,back)
                assert(vehicle==tv and not back); bypassCalls=bypassCalls+1
            end
        ''')

    def test_turn_envelope_stops_before_header_contact_without_a_ray_hit(self):
        self.install_guard_geometry()
        self.lua.execute('''
            -- No proximity ray or live driver is supplied for the parked combine.
            assert(Q.guardHarvesterTurn(c,10)==0)
            assert(bypassCalls==1 and c.queueTurnGuard.vehicle==tv)
            assert(Q.guardHarvesterTurn(c,10)==0,'a ray gap must not release the stop')
            tv.rootNode.x=40; g_currentMission.time=g_currentMission.time+100
            assert(Q.guardHarvesterTurn(c,10)==10,'actual clearance must release the guard')
        ''')

    def test_guard_checks_attached_header_and_keeps_parallel_traffic_clear(self):
        self.install_guard_geometry()
        self.lua.execute('''
            tv.rootNode.x=12; tv.rootNode.z=12
            assert(Q.guardHarvesterTurn(c,10)==0,'header overlap must count outside centre rays')
            tv.rootNode.x=22; g_currentMission.time=g_currentMission.time+100
            assert(Q.guardHarvesterTurn(c,10)==10,'parallel non-overlapping rig must not block')
        ''')

    def test_moving_vehicle_is_stopped_for_but_not_treated_as_parked(self):
        self.install_guard_geometry()
        self.lua.execute('''
            tv.stopped=false
            assert(Q.guardHarvesterTurn(c,10)==0 and bypassCalls==0)
            tv.stopped=true; hv.stopped=false
            assert(Q.guardHarvesterTurn(c,10)==0 and bypassCalls==0)
        ''')

    def test_guard_rechecks_new_course_immediately_and_leaves_working_rows_native(self):
        self.install_guard_geometry()
        self.lua.execute('''
            assert(Q.guardHarvesterTurn(c,10)==0)
            installed=Course(hv,{{x=0,z=0},{x=-10,z=0},{x=-20,z=0}},true)
            tv.rootNode.z=30
            assert(Q.guardHarvesterTurn(c,10)==10)
            c.state=c.states.WORKING
            assert(Q.guardHarvesterTurn(c,10)==10 and not c.queueTurnGuard)
        ''')

    def test_guard_uses_braking_distance_at_speed(self):
        self.install_guard_geometry()
        self.lua.execute('''
            tv.rootNode.z=32
            assert(Q.guardHarvesterTurn(c,10)==10)
            hv.lastSpeedReal=30/3600; g_currentMission.time=g_currentMission.time+100
            assert(Q.guardHarvesterTurn(c,30)==0,'fast approach must be held early')
        ''')

    def test_guard_detects_queued_tractor_and_trailer(self):
        self.install_guard_geometry()
        self.lua.execute('''
            tv.spec_combine=nil; tv.getCpDriveStrategy=function() return u end
            assert(Q.guardHarvesterTurn(c,10)==0)
        ''')

    def test_complete_turn_is_checked_before_start_not_only_near_obstacle(self):
        self.install_guard_geometry()
        self.lua.execute('''
            tv.rootNode.z=75
            c.course=Course(hv,{{x=0,z=0},{x=0,z=30},{x=0,z=60},{x=0,z=90}},true)
            original=c.course; old.turnCourse=c.course
            assert(Q.guardHarvesterTurn(c,10)==0,'must reject turn before driving towards distant trailer')
            assert(c.queueTurnPreflight.vehicle==tv and bypassCalls==1)
            g_currentMission.time=g_currentMission.time+100
            assert(Q.guardHarvesterTurn(c,10)==0,'short horizon must not release planned-route block')
            tv.rootNode.x=40; g_currentMission.time=g_currentMission.time+100
            assert(Q.guardHarvesterTurn(c,10)==10)
        ''')

    def test_repeat_block_callbacks_preserve_preparing_and_searching_bypass(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            assert(Q.tryHarvesterBypass(c,tv,false) and c.aiTurn==recovery and not yielded)
            recovery:getDriveData(33)
            assert(Q.tryHarvesterBypass(c,tv,false) and not yielded and c.queueBypass)
        ''')

    def test_preflight_unavailable_geometry_retries_then_reports_failure(self):
        self.install_guard_geometry()
        self.lua.execute('''
            old.turnCourse=c.course; local area=Q.yieldArea
            Q.yieldArea=function(_,horizon,limit) if limit then return nil end; return function() return false end end
            assert(Q.guardHarvesterTurn(c,10)==0 and not c.queueRecoveryFailure)
            g_currentMission.time=g_currentMission.time+1000
            assert(Q.guardHarvesterTurn(c,10)==0 and not c.queueRecoveryFailure)
            g_currentMission.time=g_currentMission.time+1000
            assert(Q.guardHarvesterTurn(c,10)==0 and c.queueRecoveryFailure)
        ''')

    def test_preflight_recovers_when_geometry_becomes_available(self):
        self.install_guard_geometry()
        self.lua.execute('''
            old.turnCourse=c.course; local area=Q.yieldArea
            Q.yieldArea=function() return nil end
            assert(Q.guardHarvesterTurn(c,10)==0)
            Q.yieldArea=area; tv.rootNode.x=40
            g_currentMission.time=g_currentMission.time+1000
            assert(Q.guardHarvesterTurn(c,10)==10 and not c.queueRecoveryFailure)
        ''')

    def test_parked_non_queue_tractor_does_not_require_cp_ownership(self):
        self.lua.execute('''
            tv.spec_motorized={}; tv.getCpDriveStrategy=function() return nil end
            assert(Q.tryHarvesterBypass(c,tv,false) and not c.queueBypass.driver)
            assert(not u.queueData.bypass)
        ''')

    def test_wait_timeout_stops_at_update_boundary_not_inside_pathfinder_callback(self):
        self.lua.execute('''
            tv.spec_combine={}; tv.getCpDriveStrategy=function() return nil end
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(not stopped and c.queueBypass.waiting)
            g_currentMission.time=g_currentMission.time+120001
            recovery:getDriveData(33)
            assert(not stopped and c.queueRecoveryFailure)
            c:update(33); assert(stopped and not c.queueBypass)
        ''')


if __name__=='__main__': unittest.main()
