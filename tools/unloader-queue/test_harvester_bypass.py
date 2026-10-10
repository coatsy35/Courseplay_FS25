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
        start=source.index('function AIDriveStrategyFieldWorkCourse:startRecoveryTurn(')
        end=source.index('\nend',start)+4
        self.lua.execute(source[start:end])
        self.lua.execute('''
            AIDriveStrategyCombineCourse.getDriveData=function(self)
                if nativeStep then nativeStep() end
                return 10,20,true,nativeSpeed or 10,0.7
            end
            AIDriveStrategyUnloadCombine.getDriveData=function(self)
                if nativeUnloaderStep then nativeUnloaderStep(self) end
                return 30,40,true,15,0.6
            end
        ''')
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

    def travel_fixture(self, trailer_x=0, trailer_z=40):
        self.lua.execute('''
            W=CpUnloaderQueueWorld; G=CpUnloaderQueueGeometry
            hv.rootNode={x=0,z=0,t=0}; hv.size={width=3.5,length=8}
            hv.getAIDirectionNode=function() return hv.rootNode end
            hv.getCpDriveStrategy=function() return c end
            local header={rootNode={x=0,z=5,t=0},size={width=15.2,length=2}}
            hv.getAttachedImplements=function() return {{object=header}} end
            tv.rootNode={x=0,z=40,t=0}; tv.size={width=3,length=5}
            tv.getAIDirectionNode=function() return tv.rootNode end
            trailer={rootNode={x=0,z=30,t=0},size={width=3,length=10}}
            tv.getAttachedImplements=function() return {{object=trailer}} end
            c.getCurrentCourse=function() return installed or old.turnCourse end
            c.ppc.getRelevantWaypointIx=function() return 1 end
            c.isVehicleInProximity=function() return false end
            u.releaseCombine=function() u.combineToUnload=nil end
            AIDriveStrategyCombineCourse.isActiveCpCombine=function(v) return v==hv and v.active end
            old.turnCourse=Course(hv,{{x=0,z=0},{x=0,z=20},{x=0,z=60},{x=20,z=80}},true)
            context.isHeadlandCorner=function() return false end
            u.turningRadius=9
            AIUtil.getLength=function() return 18 end
        ''')
        self.lua.execute(f'tv.rootNode.x={trailer_x}; tv.rootNode.z={trailer_z}; '
                         f'trailer.rootNode.x={trailer_x}; trailer.rootNode.z={trailer_z-10}')

    def test_planned_turn_checks_full_header_and_trailer_before_first_movement(self):
        self.travel_fixture(trailer_x=7, trailer_z=40)
        self.lua.execute('''
            local gx,gz,f,s,a=c:getDriveData(33)
            assert(gx==10 and gz==20 and f and s==0 and a==0.7)
            assert(c.aiTurn~=old and not u.queueData.yieldRequests)
            assert(not u:isAllowedToBeCalled() and not u:call(hv,{}))
            c.aiTurn:getDriveData(33)
            assert(calls==1 and not stopped and context.turnEndWpIx==953)
        ''')

    def traffic_fixture(self):
        self.travel_fixture(trailer_x=40)
        self.lua.execute('''
            for k,value in pairs(AIDriveStrategyUnloadCombine.myCombineUnloadStates) do u.states[k]=value end
            function trafficRig(x,z,state,assignment,departing)
                local vehicle={active=true,stopped=false,rootNode={x=x,z=z,t=math.pi/2},size={width=3,length=5}}
                local trailer={rootNode={x=x-10,z=z,t=math.pi/2},size={width=3,length=10}}
                vehicle.getAIDirectionNode=function() return vehicle.rootNode end
                vehicle.getIsCpActive=function() return vehicle.active end
                vehicle.getAttachedImplements=function() return {{object=trailer}} end
                local driver=setmetatable({vehicle=vehicle,states=u.states,state=state,combineToUnload=assignment,
                    settings=u.settings,turningRadius=9,debug=function() end},AIDriveStrategyUnloadCombine)
                driver.getAllTrailersFull=function() return departing end
                driver.isDriveUnloadNowRequested=function() return false end
                driver.setMaxSpeed=function(self,speed) self.speed=speed end
                driver.ppc={getRelevantWaypointIx=function() return 1 end}
                driver.course=Course(vehicle,{{x=x,z=z},{x=x+60,z=z}},true)
                driver.getCurrentCourse=function(self) return self.course end
                vehicle.getCpDriveStrategy=function() return driver end
                Q.data(driver).nativeDeparture=departing
                return driver,vehicle,trailer
            end
            Q.speed=function() end -- queue following has separate production tests
        ''')

    def test_departing_serving_and_incoming_traffic_keep_their_native_jobs(self):
        self.traffic_fixture()
        self.lua.execute('''
            outgoing,ov,ot=trafficRig(0,40,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            serving,sv,st=trafficRig(0,20,u.states.BACKING_UP_FOR_REVERSING_COMBINE,hv,false)
            incoming,iv,it=trafficRig(-20,55,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
            local departure=outgoing.course; local approach=incoming.course; local assignment=incoming.combineToUnload
            incoming.pathfinderController={pathfinder={}}; local runner=incoming.pathfinderController.pathfinder
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn==old)
            local gx,gz,f,s,a=incoming:getDriveData(33)
            assert(gx==30 and gz==40 and f and s==0 and a==0.6)
            assert(incoming.course==approach and incoming.combineToUnload==assignment)
            assert(incoming.pathfinderController.pathfinder==runner and not Q.owns(incoming))
            assert(not Q.priority(serving,hv) and serving.state==u.states.BACKING_UP_FOR_REVERSING_COMBINE)
            assert(outgoing.course==departure and outgoing.queueData.nativeDeparture and not Q.owns(outgoing))
            ov.rootNode.x=80; ot.rootNode.x=70; g_currentMission.time=g_currentMission.time+201
            -- A coupled backup still overlaps a later segment: native local
            -- clearance must be allowed to continue, not a whole-turn deadlock.
            assert(select(4,c:getDriveData(33))==10 and c.aiTurn==old)
            assert(select(4,incoming:getDriveData(33))==0)
            c.state=c.states.WORKING
            assert(select(4,incoming:getDriveData(33))==15)
            assert(incoming.course==approach and incoming.combineToUnload==assignment)
        ''')

    def test_approach_waiting_transition_cannot_be_seized_by_proximity_callback(self):
        self.traffic_fixture()
        self.lua.execute('''
            incoming,iv,it=trafficRig(-20,55,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
            c:getDriveData(33)
            nativeUnloaderStep=function(driver)
                driver.stateAfterWaitingForManeuveringCombine=driver.state
                driver.state=driver.states.WAITING_FOR_MANEUVERING_COMBINE
                assert(Q.priority(driver,hv))
            end
            assert(select(4,incoming:getDriveData(33))==0)
            assert(not Q.owns(incoming) and incoming.combineToUnload)
        ''')

    def test_full_stationary_obstacle_is_planned_around_without_taking_departure(self):
        self.traffic_fixture()
        self.lua.execute('''
            outgoing,ov,ot=trafficRig(0,40,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            ov.stopped=true; local course=outgoing.course; local state=outgoing.state
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
            c.aiTurn:getDriveData(33)
            assert(calls==1 and outgoing.state==state and outgoing.course==course)
            assert(not outgoing.queueData.bypass and outgoing.queueData.nativeDeparture)
            c.callback(c.callbackOwner,nil)
            assert(c.queueTrailerWait and outgoing.state==state and outgoing.course==course)
            assert(not Q.owns(outgoing) and not outgoing.queueData.yieldRequests)
            g_currentMission.time=g_currentMission.time+5001
            c:getDriveData(33); c.aiTurn:getDriveData(33)
            assert(calls==2 and context.turnEndWpIx==953 and not stopped)
        ''')

    def test_existing_occupant_departure_and_backup_are_never_approach_held(self):
        self.traffic_fixture()
        self.lua.execute('''
            c:getDriveData(33)
            incoming,iv,it=trafficRig(0,55,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
            assert(not Q.holdIncomingTurn(incoming,15))
            outgoing,ov,ot=trafficRig(-20,55,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            assert(not Q.holdIncomingTurn(outgoing,15))
            serving,sv,st=trafficRig(-20,55,u.states.BACKING_UP_FOR_REVERSING_COMBINE,hv,false)
            assert(not Q.holdIncomingTurn(serving,15))
        ''')

    def test_new_reservation_invalidates_cached_clear_approach_in_same_update(self):
        self.traffic_fixture()
        self.lua.execute('''
            incoming,iv,it=trafficRig(-20,55,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
            assert(not Q.holdIncomingTurn(incoming,15))
            c:getDriveData(33)
            assert(Q.holdIncomingTurn(incoming,15))
            local checks=0; local area=Q.yieldArea
            Q.yieldArea=function(...) checks=checks+1; return area(...) end
            for i=1,10 do assert(Q.holdIncomingTurn(incoming,15)) end
            assert(checks==0)
        ''')

    def test_stalled_queue_yield_can_be_planned_around_without_losing_its_requests(self):
        self.travel_fixture()
        self.lua.execute('''
            Q.take(u,'yield'); local state=u.state
            local other={}; u.queueData.yieldRequests={[other]={turnClearance=function() return true end}}
            local requests=u.queueData.yieldRequests
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
            c.aiTurn:getDriveData(33)
            assert(calls==1 and u.state==state and u.queueData.yieldRequests==requests)
            assert(not u.queueData.bypass)
            c.callback(c.callbackOwner,nil)
            assert(u.state==state and u.queueData.yieldRequests==requests)
            g_currentMission.time=g_currentMission.time+5001
            c:getDriveData(33); c.aiTurn:getDriveData(33)
            assert(calls==2 and not stopped)
        ''')

    def test_failed_native_approach_detour_does_not_take_its_job_or_index_yield_request(self):
        self.traffic_fixture()
        self.lua.execute('''
            incoming,iv,it=trafficRig(0,40,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
            iv.stopped=true; incoming.pathfinderController={pathfinder={}}
            local assignment=incoming.combineToUnload; local course=incoming.course
            local search=incoming.pathfinderController.pathfinder
            c:getDriveData(33); c.aiTurn:getDriveData(33)
            -- The target moves outside the reservation while search is pending.
            iv.rootNode.x=-20; it.rootNode.x=-30
            c.callback(c.callbackOwner,nil)
            assert(c.queueTrailerWait and not incoming.queueData.yieldRequests)
            assert(not Q.owns(incoming) and incoming.combineToUnload==assignment)
            assert(incoming.course==course and incoming.pathfinderController.pathfinder==search)
        ''')

    def test_native_bypass_record_is_discarded_before_new_turn_obstruction_check(self):
        self.traffic_fixture()
        self.lua.execute('''
            outgoing,ov,ot=trafficRig(0,40,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            ov.stopped=true; c:getDriveData(33); local first=c.queueBypass
            assert(first and not outgoing.queueData.bypass)
            c.aiTurn=old; installed=nil
            c:getDriveData(33)
            assert(c.queueBypass and c.queueBypass~=first and c.aiTurn~=old)
        ''')

    def test_new_stationary_native_obstacle_stops_accepted_detour_before_replanning(self):
        self.traffic_fixture()
        self.lua.execute('''
            tv.rootNode.x=0; trailer.rootNode.x=0
            c:getDriveData(33); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=20,y=-10,t=0},{x=20,y=-30,t=0}})
            local recovery=c.aiTurn
            outgoing,ov,ot=trafficRig(20,20,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            ov.stopped=true
            assert(select(4,c:getDriveData(33))==0)
            assert(recovery.state==recovery.states.PREPARING_RECOVERY)
            assert(outgoing.queueData.nativeDeparture and not Q.owns(outgoing))
            recovery:getDriveData(33); assert(calls==2)
        ''')

    def test_reservation_expires_on_turn_change_stop_and_does_not_cover_special_turns(self):
        for change in ('c.aiTurn={}', 'hv.active=false', 'c.state=c.states.WORKING'):
            with self.subTest(change=change):
                self.setUp(); self.traffic_fixture()
                self.lua.execute('''
                    incoming,iv,it=trafficRig(-20,55,u.states.DRIVING_TO_MOVING_COMBINE,{},false)
                    c:getDriveData(33); assert(Q.holdIncomingTurn(incoming,15))
                '''+change+'''
                    assert(not Q.holdIncomingTurn(incoming,15))
                ''')

    def test_brakes_and_reserves_trailer_before_starting_search(self):
        self.travel_fixture()
        self.lua.execute('''
            hv.stopped=false
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn==old)
            assert(c.queueBypass.braking and not u.queueData.yieldRequests)
            assert(Q.holdForHarvesterBypass(u) and u.speed==0)
            hv.stopped=true
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
            assert(not u.queueData.yieldRequests)
        ''')

    def test_route_appearing_in_native_drive_update_is_checked_immediately(self):
        self.travel_fixture()
        self.lua.execute('''
            local planned=old.turnCourse; old.turnCourse=nil
            old.states.FINISHING_ROW={}; old.state=old.states.FINISHING_ROW
            nativeStep=function() old.turnCourse=planned; old.state=old.states.TURNING end
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
        ''')

    def test_trailer_entering_route_is_detected_on_approach(self):
        self.travel_fixture(trailer_x=30)
        self.lua.execute('''
            assert(select(4,c:getDriveData(33))==10 and c.aiTurn==old)
            tv.rootNode.x=0; trailer.rootNode.x=0; g_currentMission.time=g_currentMission.time+201
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
        ''')

    def test_native_corner_centre_entry_and_row_finishing_are_unchanged(self):
        for condition in (
            'context.isHeadlandCorner=function() return true end',
            'old.callbackFunction=function() end',
            'old.states.FINISHING_ROW={}; old.state=old.states.FINISHING_ROW',
            'c.states.DRIVING_TO_WORK_START_WAYPOINT={}; c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT',
            'old.turnCourse=nil',
        ):
            with self.subTest(condition=condition):
                self.setUp(); self.travel_fixture()
                self.lua.execute(condition+'''
                    nativeSpeed=0
                    assert(select(4,c:getDriveData(33))==0 and c.aiTurn==old)
                    nativeSpeed=10
                    assert(select(4,c:getDriveData(33))==10 and c.aiTurn==old)
                    assert(not c.queueBypass and not u.queueData.yieldRequests)
                ''')

    def test_unobstructed_turn_and_non_queue_harvester_do_not_trigger_changes(self):
        self.travel_fixture(trailer_x=30)
        self.lua.execute('''
            assert(select(4,c:getDriveData(33))==10 and c.aiTurn==old)
            Q.members={}; tv.rootNode.x=0; trailer.rootNode.x=0
            g_currentMission.time=g_currentMission.time+201
            assert(select(4,c:getDriveData(33))==10 and c.aiTurn==old)
        ''')

    def test_failed_detour_requests_forward_clearance_then_replans_same_row(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); local recovery=c.aiTurn
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(not stopped and c.queueTrailerWait and u.queueData.operation=='yield')
            assert(select(4,c:getDriveData(33))==0)
            local request=u.queueData.yieldRequests[hv]
            assert(request.turnClearance and request.preferForward)
            local target=Q.yieldTarget(u)
            assert(target and target.choices[1].z>tv.rootNode.z and not target.choices[1].reverse)
            -- Tractor clear is insufficient while its trailer remains in the turn.
            tv.rootNode.x=30
            assert(Q.checkParkedTrailerTravel(c) and c.queueTrailerWait)
            trailer.rootNode.x=30
            assert(Q.checkParkedTrailerTravel(c))
            g_currentMission.time=g_currentMission.time+2001
            assert(Q.checkParkedTrailerTravel(c) and not c.queueTrailerWait)
            assert(recovery.state==recovery.states.PREPARING_RECOVERY)
            assert(u.queueData.bypass and u.queueData.operation=='prepare')
            assert(not u.queueData.yieldRequests and not u.queueData.priorityCombine)
            recovery:getDriveData(33)
            assert(calls==2 and args[3]==targetNode and context.turnEndWpIx==953)
        '''.replace('args[3]==targetNode', 'args[3].x==20 and args[3].z==30'))

    def test_reverse_disabled_still_plans_before_any_movement(self):
        self.travel_fixture()
        self.lua.execute('''
            c.getAllowReversePathfinding=function() return false end
            assert(Q.checkParkedTrailerTravel(c))
            c.aiTurn:getDriveData(33)
            assert(calls==1 and not args[6] and not installed and not u.queueData.yieldRequests)
        ''')

    def test_native_reverse_backup_during_drive_update_cannot_preempt_planning(self):
        self.travel_fixture()
        self.lua.execute('''
            -- Execute native checkBlockingUnloader, including its request to U.
            c.ppc.isReversing=function() return true end
            AIUtil.isReversing=function() return false end
            c.proximityController.checkBlockingVehicleBack=function() return 12,tv end
            c.unloaderRequestedToIgnoreProximity={get=function() return nil end}
            c.isWaitingForUnload=function() return false end
            c.shouldHoldInTurnManeuver=function() return false end
            c.debugSparse=function() end; tv.getName=function() return 'parked trailer' end
            nativeStep=function() c:checkBlockingUnloader() end
            assert(select(4,c:getDriveData(33))==0 and c.aiTurn~=old)
            assert(u.queueData.bypass and not u.queueData.yieldRequests)
            assert(u.state==u.queueData.state)
        ''')

    def test_forward_and_reverse_requests_before_drive_data_plan_first(self):
        for request in ('u:requestToBackupForReversingCombine(hv)', 'u:onBlockingVehicle(hv,false)'):
            with self.subTest(request=request):
                self.setUp(); self.travel_fixture()
                self.lua.execute(request+'''
                    assert(c.aiTurn~=old and u.queueData.bypass and not u.queueData.yieldRequests)
                ''')

    def test_successful_bypass_can_complete_native_ending_turn(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            c.aiTurn.state=c.aiTurn.states.ENDING_TURN
            assert(select(4,c:getDriveData(33))==10)
            nativeSpeed=0; assert(select(4,c:getDriveData(33))==0)
            c.state=c.states.WORKING
            assert(not Q.holdForHarvesterBypass(u) and not c.queueBypass)
        ''')

    def test_successful_detour_does_not_time_out_during_convoy_wait_or_driving(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            g_currentMission.time=200001
            hv.stopped=false
            assert(Q.holdForHarvesterBypass(u) and not c.queueTrailerWait)
            assert(not u.queueData.yieldRequests and select(4,c:getDriveData(33))==10)
            hv.stopped=true; nativeSpeed=0
            assert(Q.holdForHarvesterBypass(u) and select(4,c:getDriveData(33))==0)
            assert(not c.queueTrailerWait and not u.queueData.yieldRequests)
        ''')

    def test_persistent_trailer_block_brakes_before_fallback_movement(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            hv.stopped=false
            c:onBlockingVehicle(tv,false)
            assert(c.aiTurn.queueYieldReason and not u.queueData.yieldRequests)
            assert(Q.holdForHarvesterBypass(u) and select(4,c:getDriveData(33))==0)
            assert(not u.queueData.yieldRequests)
            hv.stopped=true
            assert(select(4,c:getDriveData(33))==0 and c.queueTrailerWait)
            assert(u.queueData.operation=='yield' and u.queueData.yieldRequests[hv])
        ''')

    def test_other_combine_yield_is_not_cancelled_when_first_turn_clears(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,nil)
            local other={}
            AIDriveStrategyCombineCourse.isActiveCpCombine=function() return true end
            u.queueData.yieldRequests[other]={}
            tv.rootNode.x=30; trailer.rootNode.x=30
            g_currentMission.time=g_currentMission.time+3000
            assert(Q.checkParkedTrailerTravel(c) and c.queueTrailerWait)
            assert(u.queueData.operation=='yield' and u.queueData.yieldRequests[other])
        ''')

    def test_superseded_turn_ignores_late_pathfinder_callback(self):
        self.travel_fixture()
        self.lua.execute('''
            assert(Q.checkParkedTrailerTravel(c)); c.aiTurn:getDriveData(33)
            c.aiTurn=old
            c.callback(c.callbackOwner,nil)
            assert(not stopped and not c.queueTrailerWait and not u.queueData.yieldRequests)
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

    def test_real_native_planner_routes_header_around_parked_rig(self):
        self.travel_fixture()
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
            target.x=0; target.z=80; target.t=0
            local G=CpUnloaderQueueGeometry
            obstacles={G.rectangle({x=0,z=40,heading=0},{width=3.5,length=18},0)}
            local validation=PathfinderConstraints(PathfinderContext(hv))
            assert(not validation:isValidNode(State3D(0,-40,CpMathUtil.angleFromGame(0)),false,true),'fixture must detect trailer collision')
            Q.generateHarvesterBypass=productionGenerate
            PathfinderUtil.findPathForTurn=nativeTurnSearch
            assert(Q.checkParkedTrailerTravel(c))
            c.aiTurn:getDriveData(33)
            for i=1,2000 do
                if installed or stopped then break end
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
            end
            assert(outside and probeCount>10 and c.course==original and context.turnEndWpIx==953)
        ''')

    def test_live_pathfinder_keeps_ownership(self):
        self.lua.execute('c.pathfinder={isActive=function() return true end}; assert(not Q.tryHarvesterBypass(c,tv,false)); assert(c.aiTurn==old)')

    def test_failed_search_never_uses_calculated_turn_or_skips_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.generateCalculatedTurn=function() error('unsafe fallback') end
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(not stopped and not installed and not u.queueData.bypass and not c.queueBypass)
            assert(c.queueTrailerWait and recovery.state==recovery.states.WAITING_FOR_PATHFINDER)
        ''')

    def test_recovery_block_listener_does_not_skip_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            c.proximityController.callback(recovery); assert(not stopped)
            recovery.state=recovery.states.TURNING
            c.proximityController.callback(recovery); assert(not stopped and c.queueTrailerWait and not c.queueBypass)
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
            assert(not stopped and checks>1 and not c.queueBypass and context.turnEndWpIx==953)
            assert(c.queueTrailerWait and recovery.state==recovery.states.WAITING_FOR_PATHFINDER)
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

    def headland_corner_fixture(self):
        self.lua.execute('''
            require('FieldWorkerProximityController')
            local points={}
            for z=0,100,5 do points[#points+1]={x=0,z=z} end
            fc=Course(hv,points,false)
            for i=1,fc:getNumberOfWaypoints() do
                fc:getWaypoint(i).attributes:setHeadlandPassNumber(1)
            end
            fc:getWaypoint(7).attributes:setHeadlandTurn(true)
            fc.name='same saved course'; fc.multiTools=2
            c.fieldWorkCourse=fc; c.course=fc
            c.getCurrentCourse=function(self) return self.course end
            c.ppc.getRelevantWaypointIx=function() return 1 end
            c.state=c.states.WORKING
            c.settings.convoyDistance={getValue=function() return 75 end}
            hv.getFieldWorkCourse=function() return fc end
            c.fieldWorkerProximityController=setmetatable({fieldWorkCourse=fc},FieldWorkerProximityController)
            leaderNode={x=0,z=55,t=math.pi}
            lv={spec_combine={},active=true,getAIDirectionNode=function() return leaderNode end,
                getFieldWorkCourse=function() return fc end,
                getIsCpFieldWorkActive=function(self) return self.active end}
            lc=Course(lv,{{x=0,z=55},{x=0,z=65},{x=0,z=75}},false)
            lc:getWaypoint(1).attributes:setOnConnectingPath(true)
            lead={vehicle=lv,fieldWorkCourse=lc,connectorEntry={},states={DRIVING_TO_WORK_START_WAYPOINT={}},
                turnContext={turnStartWpIx=2}}
            lv.getCpDriveStrategy=function() return lead end
            g_currentMission.vehicleSystem={vehicles={hv,lv}}
        ''')

    def test_corner_follower_stops_for_physical_gap_despite_stale_convoy_trail(self):
        self.headland_corner_fixture()
        self.lua.execute('''
            assert(Q.holdHeadlandCorner(c))
            local x,z,f,s,a=c:getDriveData()
            assert(x==10 and z==20 and f and s==0 and a==.7)
            assert(c.state==c.states.WORKING and c.course==fc and lead.connectorEntry)
            leaderNode.z=90
            assert(not Q.holdHeadlandCorner(c))
            local _,_,_,speed=c:getDriveData(); assert(speed==10)
        ''')

    def test_corner_hold_continues_after_lead_finishes_planning_then_releases(self):
        self.headland_corner_fixture()
        self.lua.execute('''
            lead.connectorEntry=nil; lead.state=lead.states.DRIVING_TO_WORK_START_WAYPOINT
            assert(Q.holdHeadlandCorner(c))
            lead.state={}; assert(not Q.holdHeadlandCorner(c))
            lead.connectorEntry={}; lv.active=false; assert(not Q.holdHeadlandCorner(c))
        ''')

    def test_corner_hold_respects_machine_convoy_setting_and_course_identity(self):
        self.headland_corner_fixture()
        self.lua.execute('''
            c.settings.convoyDistance.getValue=function() return 50 end
            assert(not Q.holdHeadlandCorner(c))
            c.settings.convoyDistance.getValue=function() return 60 end
            assert(Q.holdHeadlandCorner(c))
            lv.getFieldWorkCourse=function() return Course(lv,{{x=0,z=0},{x=0,z=100}},false) end
            assert(not Q.holdHeadlandCorner(c))
        ''')

    def test_hold_excludes_centre_rows_unrelated_turns_and_headland_connector_targets(self):
        self.headland_corner_fixture()
        self.lua.execute('''
            fc:getWaypoint(1).attributes:setHeadlandPassNumber(nil)
            assert(not Q.holdHeadlandCorner(c))
            fc:getWaypoint(1).attributes:setHeadlandPassNumber(1)
            fc:getWaypoint(7).attributes:setHeadlandTurn(false)
            assert(not Q.holdHeadlandCorner(c))
            c.state=c.states.TURNING
            c.turnContext={fieldWorkCourse=fc,turnStartWpIx=7,isHeadlandCorner=function() return true end}
            assert(Q.holdHeadlandCorner(c))
            fc:getWaypoint(7).attributes:setHeadlandPassNumber(nil)
            assert(not Q.holdHeadlandCorner(c))
            fc:getWaypoint(7).attributes:setHeadlandPassNumber(1)
            lc:getWaypoint(2).attributes:setHeadlandPassNumber(1)
            assert(not Q.holdHeadlandCorner(c))
        ''')

    def test_leading_centre_entry_is_never_held_by_the_headland_follower(self):
        self.headland_corner_fixture()
        self.lua.execute('''
            c.states.DRIVING_TO_WORK_START_WAYPOINT={}
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            assert(not Q.holdHeadlandCorner(c))
        ''')

    def test_success_stop_and_fullness_release_both_hold_references(self):
        for change in ('c.state=c.states.WORKING','hv.active=false','full=true','manual=true'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); '+change+
                                 '; assert(not Q.holdForHarvesterBypass(u)); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_cancel_invalidates_both_hold_references(self):
        self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); Q.cancel(u); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_timed_out_recovery_holds_combine_for_clearance(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); g_currentMission.time=130001
            assert(not Q.holdForHarvesterBypass(u)); assert(not stopped and c.queueTrailerWait and not c.queueBypass)
        ''')

    def test_failed_recovery_creation_does_not_change_queue_state(self):
        self.lua.execute('''
            old.startRecoveryTurn=function() end; local state=u.state
            assert(not Q.tryHarvesterBypass(c,tv,false)); assert(u.state==state and not u.queueData.bypass)
        ''')


if __name__=='__main__': unittest.main()
