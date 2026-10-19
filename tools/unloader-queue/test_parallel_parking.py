"""3041: parallel waiting slots and bounded unloader-to-unloader clearance."""
from pathlib import Path
import sys
import unittest
SOURCE=Path(__file__).resolve().parents[2]
ROOT=Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0,str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
import test_yield as yielding
import test_combined_recovery as combined
runtime.ROOT=yielding.ROOT=combined.ROOT=ROOT

class ParkingTests(unittest.TestCase):
    def setUp(self):
        combined.PreparationTests.setUp(self)
        self.lua.execute('''
            points={}; for z=-80,180 do points[#points+1]={x=50,z=z} end
            fc=Course(v,points,false)
            c={fieldWorkCourse=fc,course=fc,getClosestFieldworkWaypointIx=function() return 221 end}
            Q.combines={a={driver=c,position={x=50,z=140}}}
            u.isServingPosition=function() return true end
            Q.take(u,'prepare')
        ''')

    def test_unassigned_and_future_rigs_park_on_completed_centre_rows(self):
        self.lua.execute('''
            for _,assignment in ipairs({false,{future=true}}) do
                u.queueData.assignment=assignment or nil
                local goal=assert(Q.target(u))
                assert(goal.parking and #goal.choices>1)
                for _,p in ipairs(goal.choices) do
                    assert(p.x==50 and p.z<140)
                    assert(math.abs(math.sin(p.t))<0.001,'crosswise centre parking')
                    assert(p.accept(W.settledPoses(world.model,p),world.model))
                end
            end
        ''')

    def test_opposite_parallel_direction_is_usable_without_turning_in_place(self):
        self.lua.execute('''
            place(50,90,math.pi)
            local goal=assert(Q.poolTarget(u))
            assert(math.abs(H.math.delta(goal.t,math.pi))<0.001)
            local opposite=assert(Q.stagingCandidate(u,fc,141,true))
            assert(math.abs(H.math.delta(opposite.t,math.pi))<0.001)
            Q.request(u,{x=opposite.x,z=opposite.z,t=opposite.t,parking=true,choices={opposite}})
            local done,path,reason
            for i=1,10000 do done,path,reason=CpUnloaderQueueSearch.step(u.queueData.search,1); if done then break end end
            assert(done and path,reason)
            local poses=W.poses(u.queueData.world.model)
            for i=2,#path do poses=H.advance(u.queueData.world.model,poses,path[i]); assert(W.clear(u.queueData.world,poses)) end
            for _,p in ipairs(poses) do assert(math.abs(H.math.delta(p.t,math.pi))<math.rad(10)) end
        ''')

    def test_future_uncut_rows_cannot_crowd_out_completed_headland(self):
        self.lua.execute('''
            -- Closer future rows used to occupy the entire shortlist.
            local ps={}; for z=-80,180 do ps[#ps+1]={x=0,z=z} end
            local future=Course(v,ps,false)
            Q.combines.future={driver={fieldWorkCourse=future,course=future,
                getClosestFieldworkWaypointIx=function() return 1 end},position={x=0,z=-80}}
            for i=1,fc:getNumberOfWaypoints() do fc:getWaypoint(i).attributes:setHeadlandPassNumber(1) end
            local goal=assert(Q.poolTarget(u))
            for _,p in ipairs(goal.choices) do assert(p.x==50,'uncut row displaced harvested slot') end
            densityCount=1
            Q.request(u,goal)
            assert(not u.queueData.search and u.queueData.reason:find('standing crop',1,true),'parking crossed actual crop')
        ''')

    def test_native_foreground_keeps_small_parking_slice_without_duplicate_frame_work(self):
        self.lua.execute('''
            local native={getCpDriveStrategy=function() return {pathfinderController={pathfinder={}}} end}
            g_currentMission.vehicleSystem.vehicles={native}
            local data=u.queueData
            Q.request(u,{x=0,z=60,t=0,arrival=true,choices={{x=0,z=60,t=0}}})
            local ticks=0
            openIntervalTimer=function() ticks=0; return 1 end
            readIntervalTimerMs=function() ticks=ticks+0.25; return ticks end
            for i=1,3000 do
                g_updateLoopIndex=i; g_currentMission.time=i*30
                Q.schedule()
                local work=data.searchWorkMs
                Q.schedule(); assert(data.searchWorkMs==work,'duplicate frame work')
                if data.path then break end
            end
            assert(data.path and data.searchWorkMs>0,'native coroutine starved arrival clearance')
        ''')

class TrafficTests(unittest.TestCase):
    def setUp(self):
        yielding.YieldTests.setUp(self)
        self.lua.execute('''
            local field={{x=-100,z=-100},{x=100,z=-100},{x=100,z=200},{x=-100,z=200}}
            ov,_,ot=fixture({single=true,field=field})
            ov.size.length=5; ot.size={width=3,length=6}; ot.getAIMarkers=nil
            ov.active=true; ov.getIsCpActive=function() return ov.active end
            o=setmetatable({vehicle=ov,states=u.states,state=u.states.DRIVING_TO_COMBINE,turningRadius=10,
                settings=u.settings,debug=function() end,getFieldSpeed=u.getFieldSpeed,
                setMaxSpeed=u.setMaxSpeed,startCourse=u.startCourse,
                isDriveUnloadNowRequested=function() return manual or false end,
                getAllTrailersFull=function() return full or false end},AIDriveStrategyUnloadCombine)
            o.driveUnloadNowRequested={get=function() return manual or false end}
            ov.getCpDriveStrategy=function() return o end
            ov.rootNode.x=0; ov.rootNode.z=20; ov.rootNode.t=math.pi
            ot.rootNode.x=0; ot.rootNode.z=29.8; ot.rootNode.t=math.pi
            ot.joint.node.x=0; ot.joint.node.z=23.3; ot.joint.node.t=math.pi
            local av,a=makeHarvester(50,160,0); local bv,b=makeHarvester(-50,160,0)
            for _,c in ipairs({a,b}) do
                c.hasAutoAimPipe=function() return false end
                c.isDischarging=function() return discharge or false end
            end
            u.combineToUnload=av; o.combineToUnload=bv; owner=av; otherOwner=bv
            u.state=u.states.DRIVING_TO_COMBINE
            local points={}; for z=-80,180 do points[#points+1]={x=50,z=z} end
            fc=Course(v,points,false)
            a.fieldWorkCourse=fc; a.course=fc; a.getClosestFieldworkWaypointIx=function() return 221 end
            Q.combines={a={driver=a,position={x=50,z=140}}}
            u.isServingPosition=function() return true end; o.isServingPosition=u.isServingPosition
            u.getCurrentCourse=function() return u.course end
            o.getCurrentCourse=function() return o.course end
            u.course=Course(v,{{x=0,z=0},{x=0,z=80}},true)
            o.course=Course(ov,{{x=0,z=20},{x=0,z=-40}},true)
            u.ppc.getRelevantWaypointIx=function() return 1 end
            o.ppc={getRelevantWaypointIx=function() return 1 end}
            Q.data(u); Q.data(o)
            Q.target=nativeQueueTarget
            -- The native waiting transition releases ownership; physics stays
            -- at the engine boundary, while routes use the real articulated search.
            u.startWaitingForSomethingToDo=function(self) self:releaseCombine(); self.state=self.states.IDLE end
            o.releaseCombine=u.releaseCombine; o.startWaitingForSomethingToDo=u.startWaitingForSomethingToDo
            overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                local box=G.rectangle({x=x,z=z,heading=ry},{width=2*w,length=2*l},0)
                detector.collidingShapes=collision
                for _,item in ipairs(W.currentBodies(ov)) do
                    if G.overlap(box,W.rectangle(item.body,item.pose,0)) then detector.collidingShapes=1 end
                end
            end
        ''')

    def begin(self):
        self.lua.execute('''
            assert(Q.beginTrailerTraffic(u,ov))
            assert(Q.owns(u) and u.queueData.trailerTraffic and o.queueData.trailerWait==u)
            assert(u.combineToUnload==owner and o.combineToUnload==otherOwner)
            assert(Q.trailerTrafficHold(o) and not u:isAllowedToBeCalled() and not o:isAllowedToBeCalled())
            assert(Q.beginTrailerTraffic(o,v),'reverse callback changed the selected yielder')
            data=u.queueData
        ''')

    def test_checked_clearance_keeps_owners_until_full_rig_is_parked_parallel(self):
        self.begin()
        self.lua.execute('''
            local goal=Q.yieldTarget(u)
            Q.request(u,goal)
            local done,path,reason
            for i=1,300000 do done,path,reason=CpUnloaderQueueSearch.step(data.search,1); if done then break end end
            assert(done and path,reason or 'parallel escape failed')
            Q.startRoute(data,path)
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=H.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
            end
            local p=poses[1]; place(p.x,p.z,p.t)
            ot.rootNode.x=0 -- peer remains stopped throughout the checked route
            trailer.rootNode.x=poses[2].x; trailer.rootNode.z=poses[2].z; trailer.rootNode.t=poses[2].t
            assert(Q.onLast(u) and data.parkedGoal)
            assert(math.abs(math.sin(data.parkedGoal.t))<0.001)
            assert(u.combineToUnload==owner and Q.trailerTrafficHold(o))
            assert(Q.updateTrailerTraffic(u))
            assert(not u.combineToUnload and o.combineToUnload==otherOwner and not Q.trailerTrafficHold(o))
            assert(data.parkedGoal and Q.arrived(u,data.parkedGoal))
        ''')

    def test_real_blocking_hook_and_harvester_takeover_clear_the_pair(self):
        self.lua.execute('''
            u:onBlockingVehicle(ov,false)
            assert(u.queueData.trailerTraffic and Q.trailerTrafficHold(o))
            u:onBlockingVehicle(harvester,false)
            assert(not u.queueData.trailerTraffic and not Q.trailerTrafficHold(o))
            assert(u.queueData.yieldRequests and u.queueData.yieldRequests[harvester])
        ''')

    def test_departure_and_deleted_waiter_release_both_sides(self):
        for event in ('manual=true', 'full=true', 'Q.remove(o)'):
            self.setUp(); self.begin()
            self.lua.execute(event+'''
                assert(not Q.trailerTrafficHold(o))
                assert(Q.updateTrailerTraffic(u))
                assert(not data.trailerTraffic and not Q.trailerTrafficHold(o))
            ''')

    def test_traffic_observation_does_not_consume_native_manual_departure_request(self):
        self.lua.execute('''
            local consumed=0
            u.driveUnloadNowRequested={get=function() return true end}
            u.isDriveUnloadNowRequested=function() consumed=consumed+1; return true end
            assert(not Q.beginTrailerTraffic(u,ov) and consumed==0)
            assert(u.driveUnloadNowRequested:get())
        ''')

    def test_manual_combine_restart_defers_traffic_until_combine_controller_returns(self):
        self.lua.execute('''
            local originalController=owner:getCpDriveStrategy()
            local originalCourse=u.course
            local restart={states={DRIVING={}},getCurrentCourse=function() return fc end}
            owner.getCpDriveStrategy=function() return restart end
            for i=1,100 do
                Q.checkTrailerTraffic(u)
                assert(not Q.beginTrailerTraffic(u,ov))
                assert(u.combineToUnload==owner and u.course==originalCourse and not Q.owns(u))
            end
            owner.getCpDriveStrategy=function() return originalController end
            Q.checkTrailerTraffic(u)
            assert(u.queueData.trailerTraffic and Q.trailerTrafficHold(o))
        ''')

    def test_progress_timer_starts_with_this_clearance_not_old_parking(self):
        self.lua.execute('u.queueData.progressTime=0; g_currentMission.time=100000')
        self.begin()
        self.lua.execute('''
            assert(not Q.updateTrailerTraffic(u),'old route clock immediately cancelled clearance')
            g_currentMission.time=159000; place(2,0,0)
            assert(not Q.updateTrailerTraffic(u))
            g_currentMission.time=201000; assert(not Q.updateTrailerTraffic(u))
            g_currentMission.time=220001; assert(Q.updateTrailerTraffic(u))
            assert(not Q.trailerTrafficHold(o))
        ''')

    def test_transfer_departure_reverse_and_crop_keep_native_control(self):
        for guard in ('discharge=true','u.queueData.nativeDeparture=true',
                      'u.state=u.states.MOVING_BACK','densityCount=1','collision=1'):
            self.setUp()
            self.lua.execute(guard+'''
                local state=u.state; local course=u.course
                assert(not Q.beginTrailerTraffic(u,ov))
                assert(u.state==state and u.course==course and u.combineToUnload==owner)
                assert(not Q.trailerTrafficHold(o))
            ''')

    def test_stopped_rig_on_immediate_route_is_cleared_before_contact(self):
        self.lua.execute('''
            Q.checkTrailerTraffic(u)
            assert(u.queueData.trailerTraffic and Q.trailerTrafficHold(o))
        ''')

    def test_moving_or_distant_traffic_does_not_trigger_early_hold(self):
        for change in ('ov.lastSpeedReal=.005','ov.rootNode.z=100'):
            self.setUp()
            self.lua.execute(change+'''
                Q.checkTrailerTraffic(u)
                assert(not u.queueData.trailerTraffic and not Q.trailerTrafficHold(o))
            ''')

if __name__=='__main__': unittest.main()
