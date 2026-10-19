"""3025: crossing turns, replacement clearance and stable articulated preparation."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
import test_harvester_bypass as bypass
runtime.ROOT = ROOT
bypass.ROOT = ROOT


class CrossingTests(unittest.TestCase):
    def setUp(self):
        bypass.HarvesterBypassTests.setUp(self)
        bypass.HarvesterBypassTests.travel_fixture(self, trailer_x=100)
        self.lua.execute('''
            local points={}
            for x=-100,200 do points[#points+1]={x=x,z=40} end
            fc=Course(hv,points,false)
            c.fieldWorkCourse=fc; context.turnStartWpIx=100
            hv.getIsCpFieldWorkActive=hv.getIsCpActive
            fv={rootNode={x=-20,z=40,t=math.pi/2},size={width=3.5,length=8},
                spec_combine={},active=true,stopped=false,lastSpeedReal=.004}
            fh={rootNode={x=-15,z=40,t=math.pi/2},size={width=15.2,length=2}}
            fv.getAttachedImplements=function() return {{object=fh}} end
            fv.getAIDirectionNode=function() return fv.rootNode end
            fv.getIsCpActive=function() return fv.active end
            fv.getIsCpFieldWorkActive=fv.getIsCpActive
            f=setmetatable({vehicle=fv,states={WORKING={},TURNING={}},fieldWorkCourse=fc,course=fc,
                debug=function() end,ppc={getRelevantWaypointIx=function() return 81 end}},AIDriveStrategyCombineCourse)
            f.state=f.states.WORKING
            f.getCurrentCourse=function() return fc end
            f.getClosestFieldworkWaypointIx=function() return 81 end
            fv.getCpDriveStrategy=function() return f end
            local proximity={hasSameCourse=function(_,v) return v==hv or v==fv end}
            c.fieldWorkerProximityController=proximity; f.fieldWorkerProximityController=proximity
            g_currentMission.vehicleSystem={vehicles={hv,fv}}
        ''')

    def test_crossing_follower_stops_in_both_update_orders_without_changing_jobs(self):
        for order in ('c:getDriveData(); f:getDriveData()', 'f:getDriveData(); c:getDriveData()'):
            self.setUp()
            self.lua.execute(order+'''
                assert(f.queueCombineHold and f.queueCombineHold.lead==c)
                assert(select(4,f:getDriveData())==0)
                assert(not c.queueCombineHold and c.aiTurn==old)
                assert(f.course==fc and f.state==f.states.WORKING and not f.queueData)
                c.state=c.states.WORKING
                assert(select(4,f:getDriveData())==10 and not f.queueCombineHold)
            ''')

    def test_occupied_turn_exit_releases_blocker_before_original_leader_retries(self):
        self.lua.execute('''
            fv.rootNode.x=0; fh.rootNode.x=5; fv.stopped=true
            local state=f.state; local course=f.course
            assert(select(4,f:getDriveData())==0)
            assert(c.aiTurn~=old and not f.queueData and not f.queueBypass)
            c.aiTurn:getDriveData(33)
            assert(calls==1 and context.turnEndWpIx==953)
            c.callback(c.callbackOwner,nil)
            assert(c.queueCombineHold and c.queueCombineHold.clearing and not f.queueCombineHold)
            for i=1,30 do
                g_currentMission.time=g_currentMission.time+1000
                assert(select(4,f:getDriveData())==10)
                assert(select(4,c:getDriveData())==0)
                c.aiTurn:getDriveData(33)
            end
            assert(calls==1 and c.queueTrailerWait,'occupied endpoint repeatedly replanned')
            assert(f.course==course and f.state==state and not stopped)
            -- Root alone is insufficient: the full header must also clear.
            fv.rootNode.x=80; c:getDriveData(); assert(c.queueCombineHold)
            fh.rootNode.x=85; c:getDriveData(); assert(not c.queueCombineHold)
            c:getDriveData(); g_currentMission.time=g_currentMission.time+2001
            c:getDriveData(); c.aiTurn:getDriveData(33)
            assert(calls==2 and context.turnEndWpIx==953)
        ''')

    def test_released_blocker_keeps_clearance_priority_with_five_combines(self):
        self.lua.execute('''
            fv.rootNode.x=0; fh.rootNode.x=5; fv.stopped=true
            f:getDriveData(); c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(c.queueCombineHold and c.queueCombineHold.clearing)
            for i=1,3 do
                local x=9+i*3
                local vehicle={rootNode={x=x,z=0,t=0},size={width=3.5,length=8},spec_combine={}}
                local header={rootNode={x=x,z=5,t=0},size={width=15.2,length=2}}
                vehicle.getAIDirectionNode=function() return vehicle.rootNode end
                vehicle.getAttachedImplements=function() return {{object=header}} end
                vehicle.getIsCpActive=function() return true end
                vehicle.getIsCpFieldWorkActive=vehicle.getIsCpActive
                local driver={vehicle=vehicle,states=c.states,state=c.states.TURNING,fieldWorkCourse=fc,
                    turnContext={turnStartWpIx=200+i,isHeadlandCorner=function() return false end}}
                local turnCourse=Course(vehicle,{{x=x,z=0},{x=x,z=80}},true)
                driver.aiTurn={turnContext=driver.turnContext,turnCourse=turnCourse,
                    startRecoveryTurn=function() end,states={TURNING={}}}
                driver.aiTurn.state=driver.aiTurn.states.TURNING
                driver.getCurrentCourse=function() return turnCourse end
                driver.ppc={getRelevantWaypointIx=function() return 1 end}
                vehicle.getCpDriveStrategy=function() return driver end
                table.insert(g_currentMission.vehicleSystem.vehicles,vehicle)
            end
            f.fieldWorkerProximityController.hasSameCourse=function() return true end
            for i=1,30 do
                assert(not Q.holdCombineTurn(f,10),'third combine re-held clearing blocker')
                assert(Q.holdCombineTurn(c,10))
            end
            -- When clearance priority ends, ordinary traffic rules apply again.
            c.queueCombineHold=nil
            assert(Q.holdCombineTurn(f,10))
        ''')

    def test_stale_bypass_failure_cannot_release_a_new_hold_pair(self):
        self.lua.execute('''
            fv.rootNode.x=0; fh.rootNode.x=5; fv.stopped=true
            f:getDriveData(); c.aiTurn:getDriveData(33)
            local previous=f.queueCombineHold
            local replacement={lead=previous.lead,context=previous.context,course=previous.course}
            f.queueCombineHold=replacement
            c.callback(c.callbackOwner,nil)
            assert(f.queueCombineHold==replacement and not c.queueCombineHold)
            assert(c.queueTrailerWait and not stopped)
        ''')

    def test_priority_is_frozen_and_header_only_crossing_is_protected(self):
        self.lua.execute('''
            f:getDriveData(); assert(f.queueCombineHold)
            f.getClosestFieldworkWaypointIx=function() return 200 end
            for i=1,10 do
                assert(Q.checkCombineTurns(f,15))
                assert(not Q.checkCombineTurns(c,15))
            end
            assert(f.queueCombineHold.lead==c and not c.queueCombineHold)
            c.fieldWorkCourse={}
            assert(not Q.holdCombineTurn(f))
        ''')

    def test_other_courses_and_nonconflicting_rows_are_unchanged(self):
        self.lua.execute('''
            f.fieldWorkerProximityController={hasSameCourse=function() return false end}
            assert(not Q.holdCombineTurn(f,15))
            f.fieldWorkerProximityController=c.fieldWorkerProximityController
            fv.rootNode.x=-90; fh.rootNode.x=-85
            f.ppc.getRelevantWaypointIx=function() return 11 end
            assert(not Q.holdCombineTurn(f,15) and not f.queueCombineHold)
        ''')

    def test_equal_progress_turns_choose_one_winner_in_either_order(self):
        for order in ('c:getDriveData(); f:getDriveData()', 'f:getDriveData(); c:getDriveData()'):
            self.setUp()
            self.lua.execute('''
                hv.rootNode.z=25; hv:getAttachedImplements()[1].object.rootNode.z=30
                old.turnCourse=Course(hv,{{x=0,z=25},{x=0,z=60},{x=20,z=80}},true)
                f.state=f.states.TURNING
                f.turnContext={turnStartWpIx=100,isHeadlandCorner=function() return false end}
                f.aiTurn={turnContext=f.turnContext,turnCourse=fc,startRecoveryTurn=function() end,states={TURNING={}}}
                f.aiTurn.state=f.aiTurn.states.TURNING
                c.vehicle.stopped=false
            '''+order+'''
                assert((f.queueCombineHold~=nil)~=(c.queueCombineHold~=nil))
                local winner=f.queueCombineHold and c or f
                for i=1,10 do c:getDriveData(); f:getDriveData() end
                assert(not winner.queueCombineHold)
            ''')


class AcceptedRouteTests(unittest.TestCase):
    def setUp(self):
        bypass.HarvesterBypassTests.setUp(self)
        self.travel_fixture=lambda *args,**kwargs: bypass.HarvesterBypassTests.travel_fixture(self,*args,**kwargs)
        bypass.HarvesterBypassTests.traffic_fixture(self)

    def native_reverse_failure(self, prepare_before_failure=False):
        self.lua.execute('''
            tv.rootNode.x=0; trailer.rootNode.x=0
            u.state=u.states.MOVING_BACK; u.combineToUnload=hv
            reverseState=u.state; reverseCourse=u.course
            c:getDriveData(); c.aiTurn:getDriveData(33)
            recovery=c.aiTurn
            assert(calls==1 and not Q.owns(u))
            recovery.queueBypassConstraints.isValidNode=function(_,node) return node.x<5 end
        ''')
        if prepare_before_failure:
            self.lua.execute("u.combineToUnload=nil; Q.take(u,'prepare')")
        self.lua.execute('''
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=20,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(c.queueTrailerWait and not c.queueBypass)
        ''')

    def test_native_reverse_to_preparation_requests_clearance_once_then_retries(self):
        self.native_reverse_failure()
        self.lua.execute('''
            local wait=c.queueTrailerWait
            for i=1,30 do
                g_currentMission.time=g_currentMission.time+100
                assert(select(4,c:getDriveData())==0)
                assert(u.state==reverseState and u.course==reverseCourse and u.combineToUnload==hv)
                assert(not Q.owns(u) and not u.queueData.yieldRequests)
            end
            -- The native reverse ends before the first retry becomes eligible.
            u.combineToUnload=nil; Q.take(u,'prepare')
            -- An old request record alone is not an active yield operation.
            u.queueData.yieldRequests={[hv]={turnClearance=wait.area}}
            c:getDriveData()
            local data=u.queueData
            local request=assert(data.yieldRequests and data.yieldRequests[hv], 'reverse completion lost clearance request')
            assert(data.operation=='yield' and request.turnClearance==wait.area and request.preferForward)
            assert(wait.retryAt==g_currentMission.time+5000 and data.nextAttempt==0)
            local generation=data.generation
            local search={}; data.search=search
            for i=1,40 do
                g_currentMission.time=g_currentMission.time+100
                c:getDriveData()
                assert(data.generation==generation and data.search==search and data.yieldRequests[hv]==request)
                assert(c.queueTrailerWait==wait and calls==1)
            end
            -- A rig actually moving clear gets to finish its movement.
            tv.stopped=false; g_currentMission.time=wait.retryAt+1
            c:getDriveData(); assert(c.queueTrailerWait==wait and calls==1)
            tv.stopped=true
            c:getDriveData()
            assert(c.queueTrailerWait==wait and calls==1 and data.search==search)
            -- A checked search owns recovery until it completes or fails.
            Q.failed(data,'no safe clearance route'); Q.cancel(u)
            c:getDriveData(); recovery:getDriveData(33)
            assert(calls==2 and not c.queueTrailerWait and c.queueBypass)
            assert(not data.search and data.yieldRequests[hv]==request)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=20,y=-10,t=0},{x=20,y=-30,t=0}})
            for i=1,30 do c:getDriveData() end
            assert(recovery.state==recovery.states.TURNING and calls==2)
            assert(context.turnEndWpIx==953 and not stopped)
        ''')

    def test_reverse_finished_during_search_uses_live_state_at_failure(self):
        self.native_reverse_failure(prepare_before_failure=True)
        self.lua.execute('''
            local request=assert(u.queueData.yieldRequests and u.queueData.yieldRequests[hv])
            assert(u.queueData.operation=='yield' and request.turnClearance==c.queueTrailerWait.area)
            assert(request.preferForward)
        ''')

    def test_reverse_completion_clearance_waits_for_whole_rig_then_resumes_same_row(self):
        self.native_reverse_failure()
        self.lua.execute('''
            u.combineToUnload=nil; Q.take(u,'prepare'); c:getDriveData()
            assert(u.queueData.operation=='yield')
            tv.rootNode.x=40
            c:getDriveData(); assert(c.queueTrailerWait and not c.queueTrailerWait.clearSince)
            trailer.rootNode.x=40
            c:getDriveData(); assert(c.queueTrailerWait)
            g_currentMission.time=g_currentMission.time+1999
            c:getDriveData(); assert(c.queueTrailerWait)
            g_currentMission.time=g_currentMission.time+2
            c:getDriveData(); assert(not c.queueTrailerWait and c.queueBypass)
            assert(u.queueData.operation=='prepare' and not u.queueData.yieldRequests)
            recovery:getDriveData(33)
            assert(calls==2 and context.turnEndWpIx==953 and not stopped)
        ''')

    def test_stationary_traffic_does_not_restart_checked_detour_every_frame(self):
        self.lua.execute('''
            tv.rootNode.x=0; trailer.rootNode.x=0
            c:getDriveData(); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=20,y=-10,t=0},{x=20,y=-30,t=0}})
            local recovery=c.aiTurn; local course=recovery.turnCourse
            outgoing,ov,ot=trafficRig(20,20,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            ov.stopped=true
            local deadline=c.queueBypass.untilTime
            -- The full reservation may overlap, but the planner's complete
            -- vehicle clearance says this accepted course remains traversable.
            for i=1,400 do
                g_currentMission.time=g_currentMission.time+33
                c:getDriveData()
                if recovery.state==recovery.states.PREPARING_RECOVERY then recovery:getDriveData(33) end
                assert(recovery.turnCourse==course and calls==1)
            end
            assert(c.queueBypass.untilTime==deadline and not c.queueTrailerWait)
        ''')


    def test_success_after_failed_retry_retains_active_detour(self):
        self.lua.execute('''
            outgoing,ov,ot=trafficRig(0,40,u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL,nil,true)
            ov.stopped=true
            c:getDriveData(); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,nil)
            assert(c.queueTrailerWait and not c.queueBypass)
            g_currentMission.time=g_currentMission.time+5001
            c:getDriveData(); c.aiTurn:getDriveData(33)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=20,y=-10,t=0},{x=20,y=-30,t=0}})
            local recovery=c.aiTurn
            assert(c.queueBypass and c.queueBypass.turn==recovery)
            for i=1,60 do
                g_currentMission.time=g_currentMission.time+33
                c:getDriveData()
                assert(c.aiTurn==recovery and recovery.state~=recovery.states.PREPARING_RECOVERY)
            end
            assert(calls==2 and not c.queueTrailerWait)
        ''')


class PreparationTests(unittest.TestCase):
    def setUp(self):
        runtime.EngineBoundaryTests.setUp(self)
        self.lua.execute('''
            Q=CpUnloaderQueue; W=CpUnloaderQueueWorld; H=HeadlandLoopGeometry
            AIUtil.getLength=function() return 18 end
            u.states={IDLE={}}; u.state=u.states.IDLE
            u.getFieldSpeed=function() return 30 end
            u.getDistanceAndEteToVehicle=function() return 100,15 end
            u.setMaxSpeed=function(self,s) self.speed=s end
            u.startCourse=function(self,course) self.course=course end
            u.settings={reverseSpeed={getValue=function() return 8 end}}
            u.getAllTrailersFull=function() return false end
            u.isDriveUnloadNowRequested=function() return false end
            u.ppc={getRelevantWaypointIx=function() return 1 end}
            v.getCpDriveStrategy=function() return u end
            function place(x,z,t)
                v.rootNode.x=x; v.rootNode.z=z; v.rootNode.t=t
                local a,b=H.math.position(v.rootNode,0,-9.8)
                trailer.rootNode.x=a; trailer.rootNode.z=b; trailer.rootNode.t=t
                a,b=H.math.position(v.rootNode,0,-3.3)
                trailer.joint.node.x=a; trailer.joint.node.z=b; trailer.joint.node.t=t
            end
        ''')

    def route(self):
        self.lua.execute('''
            data=Q.take(u,'prepare'); data.world=world
            data.searchGeneration=data.generation; data.goal={x=0,z=30,t=0}
            local path={}
            for i=0,120 do path[#path+1]={x=0,z=i*.25,t=0} end
            Q.startRoute(data,path)
        ''')

    def test_ppc_segment_start_behind_actual_rig_does_not_abort_valid_route(self):
        self.route()
        self.lua.execute('''
            place(0,3.1,0)
            Q.speed(u)
            assert(data.path and u.speed==15 and data.liveClear)
            densityCount=30; g_currentMission.time=201
            Q.speed(u)
            assert(not data.path and u.speed==0 and data.reason:find('standing crop',1,true))
            assert(not Q.targetAvailable(u,{x=0,z=30,t=0}))
        ''')

    def test_projection_deviation_and_real_obstacle_fail_closed(self):
        for change in ('place(4,3,0)', 'collision=1'):
            self.setUp(); self.route()
            self.lua.execute(change+'; Q.speed(u); assert(u.speed==0 and not data.path)')

    def test_last_waypoint_does_not_claim_unaligned_trailer_is_parked(self):
        self.route()
        self.lua.execute('''
            place(0,30,0); trailer.rootNode.t=math.rad(25)
            assert(Q.onLast(u) and not data.parkedGoal)
            assert(data.reason=='whole train not aligned at destination')
        ''')

    def test_stages_are_frozen_between_deadline_transitions_and_use_queue_speed(self):
        self.lua.execute('''
            local points={}
            for z=0,600 do points[#points+1]={x=0,z=z} end
            fc=Course(v,points,false); fc.currentWaypoint=401
            c={vehicle={lastSpeedReal=0},fieldWorkCourse=fc,course=fc,
                getClosestFieldworkWaypointIx=function() return fc.currentWaypoint end}
            snapshot={driver=c,vehicle=c.vehicle,position={x=0,z=400},fill=0,capacity=20000,rate=50,callPercent=80}
            Q.combines={a=snapshot}; data=Q.take(u,'prepare'); data.assignment={combine='a'}
            local eta=Q.preparationEta(u,snapshot)
            assert(eta>39) -- capped travel speed plus whole-rig straightening
            local initial=assert(Q.target(u)); assert(data.stage.phase==1)
            for i=1,20 do
                fc.currentWaypoint=401+i; snapshot.fill=i*50
                assert(Q.target(u)==initial)
            end
            snapshot.fill=11000
            local middle=assert(Q.target(u)); assert(data.stage.phase==2 and middle~=initial)
            snapshot.fill=14500
            local near=assert(Q.target(u)); assert(data.stage.phase==3)
            assert(fc.currentWaypoint-1-near.z>=27 and fc.currentWaypoint-1-near.z<=29)
            snapshot.fill=14000; assert(Q.target(u)==near)
            Q.failed(data,'destination occupied'); data.failedGoals={}
            data.goal=near; Q.failed(data,'destination occupied'); Q.cancel(u)
            assert(Q.target(u)~=near)
        ''')

    def pending_preparation(self):
        self.lua.execute('''
            Q.refresh=function() end; Q.schedule=function() end
            snapshot={vehicle={lastSpeedReal=0},position={x=0,z=100},fill=0,capacity=20000,rate=50,callPercent=80}
            Q.combines={a=snapshot,b=snapshot}
            data=Q.take(u,'prepare'); data.assignment={combine='a'}; data.stage={phase=1}
            Q.request(u,{x=0,z=30,t=0})
            assert(data.search)
            search=data.search; generation=data.generation
            Q.target=function() return nil end
        ''')

    def test_long_preparation_search_retargets_when_unloading_deadline_becomes_urgent(self):
        self.pending_preparation()
        self.lua.execute('''
            g_currentMission.time=3000; Q.tick(u)
            assert(data.search==search and data.generation==generation)
            snapshot.fill=19500; g_currentMission.time=6000; Q.tick(u)
            assert(not data.search and data.generation>generation and not data.stage)
        ''')

    def test_changed_assignment_or_successor_role_discards_stale_search(self):
        for change in ("data.assignment.combine='b'", 'data.assignment.successor=true', 'data.assignment.future=true'):
            with self.subTest(change=change):
                self.setUp(); self.pending_preparation()
                self.lua.execute(change+'''
                    g_currentMission.time=3000; Q.tick(u)
                    assert(not data.search and data.generation>generation and not data.stage)
                ''')

    def test_slots_exclude_ad_access_turn_reservations_and_bends(self):
        self.lua.execute('''
            local points={}
            for z=0,150 do points[#points+1]={x=0,z=z} end
            local course=Course(v,points,false)
            assert(Q.stagingCandidate(u,course,81))
            u.invertedStartPositionMarkerNode={x=0,z=80,t=0}
            assert(not Q.stagingCandidate(u,course,81))
            u.invertedStartPositionMarkerNode=nil
            local previousPrune=Q.pruneTurnReservations
            Q.pruneTurnReservations=function() end
            Q.turnTraffic={other={area=function() return true end}}
            assert(not Q.stagingCandidate(u,course,81))
            Q.turnTraffic={}
            Q.pruneTurnReservations=previousPrune
            course:getWaypoint(85).attributes:setRowEnd(true)
            assert(not Q.stagingCandidate(u,course,81))
        ''')

    def test_physical_near_arrival_precedes_configured_triggers_with_search_delay(self):
        for threshold in (60,80,90):
            self.setUp()
            self.lua.globals().threshold=threshold
            self.lua.execute('''
                local points={}
                for z=0,190 do points[#points+1]={x=0,z=z} end
                local course=Course(v,points,false); course.currentWaypoint=101
                local harvester={lastSpeedReal=.001}
                local combine={vehicle=harvester,fieldWorkCourse=course,course=course,
                    getClosestFieldworkWaypointIx=function() return course.currentWaypoint end}
                local snapshot={driver=combine,vehicle=harvester,position={x=0,z=100},capacity=20000,
                    callPercent=threshold,fill=20000*threshold/100-2250,rate=50}
                Q.combines={a=snapshot}; data=Q.take(u,'prepare'); data.assignment={combine='a'}
                local goal=assert(Q.target(u)); assert(data.stage.phase==3)
                Q.request(u,goal)
                local done,path,reason
                for i=1,100000 do
                    done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                    if done then break end
                end
                assert(done and path,reason)
                local elapsed=10 -- delayed background search, not charged as a frame cost
                g_currentMission.time=elapsed*1000; Q.startRoute(data,path)
                local poses=W.poses(data.world.model)
                local previous=poses[1]
                for i=2,#path do
                    local p=path[i]
                    elapsed=elapsed+math.sqrt((p.x-previous.x)^2+(p.z-previous.z)^2)/(15/3.6)
                    poses=H.advance(data.world.model,poses,p)
                    assert(W.clear(data.world,poses))
                    place(p.x,p.z,p.t)
                    trailer.rootNode.x=poses[2].x; trailer.rootNode.z=poses[2].z; trailer.rootNode.t=poses[2].t
                    local ci=1
                    for j,k in ipairs(data.courseToPath) do if k<=i then ci=j else break end end
                    u.ppc.getRelevantWaypointIx=function() return ci end
                    g_currentMission.time=elapsed*1000; Q.speed(u)
                    assert(data.path and u.speed==15)
                    previous=p
                end
                assert(elapsed<45,'rig must be aligned before the configured trigger')
                assert(Q.onLast(u) and data.parkedGoal==goal)
                assert(145-goal.z>=26 and 145-goal.z<=29)
                assert(Q.target(u)==goal,'hold the completed stage rather than chase')
            ''')

    def test_ad_circle_excludes_body_edges_and_containment_even_with_clear_corners(self):
        self.lua.execute('''
            u.invertedStartPositionMarkerNode={x=0,z=0,t=0}
            local model={bodies={{left=2,right=-2,front=2,back=-2.05}},links={}}
            local poses={{x=0,z=27,t=0}}
            for _,p in ipairs(W.rectangle(model.bodies[1],poses[1],1)) do
                assert(math.sqrt(p.x*p.x+p.z*p.z)>24)
            end
            assert(not Q.stagingClear(u,poses,model))
            model.bodies[1].front=50; model.bodies[1].back=-50
            poses[1].z=0
            assert(not Q.stagingClear(u,poses,model))
        ''')


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        PreparationTests.setUp(self)
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine','AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT/f'scripts/ai/strategies/{name}.lua').read_text())
        self.lua.execute('''
            attempts=0; nativeFailures=0
            AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine=function(self,x,z)
                attempts=attempts+1; lastX=x; lastZ=z
            end
            AIDriveStrategyUnloadCombine.onPathfindingFailedToStationaryTarget=function() nativeFailures=nativeFailures+1 end
        ''')
        self.lua.execute((ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text())
        self.lua.execute('''
            setmetatable(u,AIDriveStrategyUnloadCombine)
            u.states=AIDriveStrategyUnloadCombine.myStates; u.state=u.states.WAITING_FOR_PATHFINDER
            waiting=true; reference={x=0,z=40,t=0}
            cv={getIsCpActive=function() return active end,
                getCpDriveStrategy=function() return {isWaitingForUnload=function() return waiting end} end}
            active=true; u.combineToUnload=cv
            u.getPipeOffsetReferenceNode=function() return reference end
            u.startWaitingForSomethingToDo=function(self) self.combineToUnload=nil; self.state=self.states.IDLE end
            ov={rootNode={x=0,z=40,t=0},size={width=3,length=5},getIsCpActive=function() return true end}
            ot={rootNode={x=0,z=30,t=0},size={width=3,length=10}}
            ov.getAttachedImplements=function() return {{object=ot}} end
            outgoing={vehicle=ov,states=u.states,state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL}
            Q.data(outgoing).nativeDeparture=true; Q.data(u)
        ''')

    def test_occupied_goal_waits_for_whole_outgoing_train_then_calls_native_once(self):
        self.lua.execute('''
            u:startPathfindingToWaitingCombine(0,-1)
            assert(attempts==0 and u.queueData.deferredApproach and u.combineToUnload==cv)
            ov.rootNode.x=50 -- tractor clear but its trailer still blocks
            g_currentMission.time=1001; Q.resumeWaitingApproach(u); assert(attempts==0)
            ot.rootNode.x=50
            g_currentMission.time=2002; Q.resumeWaitingApproach(u)
            assert(attempts==1 and lastX==0 and lastZ==-1 and not u.queueData.deferredApproach)
            assert(u.combineToUnload==cv and u.state==u.states.WAITING_FOR_PATHFINDER)
        ''')

    def test_occupation_during_search_defers_only_that_failure(self):
        self.lua.execute('''
            ov.rootNode.x=50; ot.rootNode.x=50
            u:startPathfindingToWaitingCombine(0,0); assert(attempts==1)
            ov.rootNode.x=0; ot.rootNode.x=0
            u:onPathfindingFailedToStationaryTarget()
            assert(nativeFailures==0 and u.queueData.deferredApproach)
            ov.rootNode.x=50; ot.rootNode.x=50; u.queueData.deferredApproach=nil
            u:onPathfindingFailedToStationaryTarget(); assert(nativeFailures==1)
        ''')

    def test_timeout_and_changed_assignment_do_not_stop_job_or_resume_stale_goal(self):
        self.lua.execute('''
            u:startPathfindingToWaitingCombine(0,0)
            g_currentMission.time=60001; Q.resumeWaitingApproach(u)
            assert(not u.combineToUnload and u.state==u.states.IDLE and attempts==0)
            assert(u.queueData.approachRetryAt==70001)
            u.combineToUnload=cv; u.state=u.states.WAITING_FOR_PATHFINDER
            u:startPathfindingToWaitingCombine(0,0)
            u.combineToUnload={}; Q.resumeWaitingApproach(u)
            assert(not u.queueData.deferredApproach and attempts==0)
        ''')

    def test_same_combine_resuming_or_moving_invalidates_stationary_approach(self):
        for change in ('waiting=false','reference.z=45','reference.t=math.rad(20)'):
            self.setUp()
            self.lua.execute('u:startPathfindingToWaitingCombine(0,0); '+change+'''
                Q.resumeWaitingApproach(u)
                assert(not u.queueData.deferredApproach and not u.combineToUnload and attempts==0)
                assert(u.state==u.states.IDLE)
            ''')


if __name__ == '__main__':
    unittest.main()
