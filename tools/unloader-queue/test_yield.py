"""Native priority requests, queue resumption and real whole-train escape searches."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE / 'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT = ROOT


class YieldTests(unittest.TestCase):
    def setUp(self):
        runtime.EngineBoundaryTests.setUp(self)
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine', 'AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT / f'scripts/ai/strategies/{name}.lua').read_text())
        self.lua.execute((ROOT / 'scripts/ai/CpUnloaderQueueHooks.lua').read_text())
        self.lua.execute('''
            Q=CpUnloaderQueue; W=CpUnloaderQueueWorld; H=HeadlandLoopGeometry; G=CpUnloaderQueueGeometry
            setmetatable(u,AIDriveStrategyUnloadCombine)
            u.states=AIDriveStrategyUnloadCombine.myStates; u.state=u.states.IDLE
            u.releaseCombine=function(self) self.combineToUnload=nil end
            u.debugSparse=function() end
            u.setMaxSpeed=function(self,speed) self.speed=speed end
            u.isDriveUnloadNowRequested=function() return false end
            u.getAllTrailersFull=function() return false end
            u.settings={fullThreshold={getValue=function() return 85 end},reverseSpeed={getValue=function() return 10 end}}
            u.getFieldSpeed=function() return 15 end
            u.startCourse=function(self,course) self.course=course end
            u.ppc={getReverserNode=function() return trailer.steeringAxleNode end}
            v.getCpDriveStrategy=function() return u end
            AIUtil.getLength=function() return 18 end
            function makeHarvester(x,z,t)
                local h={rootNode={x=x,z=z,t=t},size={width=3.5,length=8},active=true}
                h.getAIDirectionNode=function() return h.rootNode end
                h.getIsCpActive=function() return h.active end
                local header={rootNode={x=x+5*math.sin(t),z=z+5*math.cos(t),t=t},size={width=15.2,length=2}}
                h.getAttachedImplements=function() return {{object=header}} end
                local c=setmetatable({vehicle=h},AIDriveStrategyCombineCourse)
                c.debug=function() end
                c.getWorkWidth=function() return 15.2 end
                c.alwaysNeedsUnloader=function() return false end
                c.isVehicleInProximity=function() return c.near end
                c.getCurrentCourse=function() return c.course end
                c.ppc={getRelevantWaypointIx=function() return 1 end}
                h.getCpDriveStrategy=function() return c end
                return h,c,header
            end
            harvester,c,header=makeHarvester(0,12,math.pi)
            c.near=true
            function place(x,z,t)
                v.rootNode.x=x; v.rootNode.z=z; v.rootNode.t=t
                local a,b=H.math.position(v.rootNode,0,-9.8)
                trailer.rootNode.x=a; trailer.rootNode.z=b; trailer.rootNode.t=t
                a,b=H.math.position(v.rootNode,0,-3.3)
                trailer.joint.node.x=a; trailer.joint.node.z=b; trailer.joint.node.t=t
            end
            function nativeRequest() c:onBlockingVehicle(v,false) end
            function includeHarvesterCollision()
                overlapBox=function(x,y,z,rx,ry,rz,w,h,l,callback,detector)
                    local probe=G.rectangle({x=x,z=z,heading=ry},{width=2*w,length=2*l},0)
                    detector.collidingShapes=0
                    for _,body in ipairs(W.currentBodies(harvester)) do
                        if G.overlap(probe,W.rectangle(body.body,body.pose,0)) then detector.collidingShapes=1 end
                    end
                end
            end
            Q.refresh=function() end -- allocation is independent of this traffic regression
            nativeQueueTarget=Q.target
            Q.target=function() return nil end
        ''')

    def test_native_request_enters_yield_and_repeated_request_preserves_search(self):
        self.lua.execute('''
            Q.take(u,'prepare'); nativeRequest()
            assert(Q.owns(u) and u.queueData.operation=='yield')
            local data=u.queueData; data.search={}; local generation=data.generation
            nativeRequest()
            assert(data.search and data.generation==generation)
            assert(not u:isAllowedToBeCalled() and not u:call(harvester,{}))
        ''')

    def test_yield_uses_native_move_away_warning_policy_but_keeps_proximity(self):
        self.lua.execute('''
            u.collisionAvoidanceController={isCollisionWarningActive=function() return true end}
            Q.take(u,'prepare'); u.speed=10; u:checkCollisionWarning(); assert(u.speed==0)
            nativeRequest(); u.speed=10; u:checkCollisionWarning(); assert(u.speed==10)
            assert(u:isProximitySpeedControlEnabled())
            assert(not u:ignoreProximityObject(nil,harvester,true,false))
        ''')

    def test_native_sensor_request_cannot_be_cancelled_by_straight_geometry(self):
        self.lua.execute('''
            place(25,0,0); Q.take(u,'prepare'); nativeRequest()
            assert(Q.yieldTarget(u) and u.queueData.operation=='yield')
            g_currentMission.time=10000
            Q.yieldTarget(u,true)
            assert(u.queueData.operation=='yield')
        ''')

    def test_safe_combine_pass_resumes_queue_without_forcing_tractor_move(self):
        self.lua.execute('''
            place(25,0,0); Q.take(u,'prepare'); nativeRequest()
            c.near=false
            assert(Q.yieldTarget(u)==nil and u.queueData.operation=='yield')
            g_currentMission.time=2100; Q.tick(u)
            assert(u.queueData.operation=='prepare' and not u.queueData.search)
        ''')

    def test_preparation_resumes_after_clearance(self):
        self.lua.execute('''
            place(25,0,0); Q.take(u,'prepare')
            nativeRequest(); c.near=false
            Q.yieldTarget(u,true); g_currentMission.time=2100
            Q.yieldTarget(u,true)
            assert(u.queueData.operation=='prepare')
        ''')

    def test_stopped_harvester_releases_yield_without_stale_tick_state(self):
        self.lua.execute('''
            Q.take(u,'prepare'); nativeRequest(); harvester.active=false
            Q.tick(u)
            assert(u.queueData.operation=='prepare')
        ''')

    def test_completed_yield_route_waits_for_live_clearance_before_preparation(self):
        self.lua.execute('''
            place(25,0,0); Q.take(u,'prepare'); nativeRequest()
            local data=u.queueData
            data.path={{x=25,z=0,t=0}}; data.course={}; u.course=data.course
            assert(Q.onLast(u) and data.operation=='yield')
            Q.yieldTarget(u,true); assert(not data.yieldRequests[harvester].clearSince)
            c.near=false; g_currentMission.time=1000; Q.yieldTarget(u,true)
            g_currentMission.time=3100; Q.tick(u)
            assert(data.operation=='prepare')
        ''')

    def test_unavailable_envelope_does_not_claim_clearance(self):
        self.lua.execute('''
            Q.take(u,'prepare'); nativeRequest()
            Q.yieldArea=function() return nil end
            c.near=false; g_currentMission.time=10000
            assert(Q.yieldTarget(u)==nil and u.queueData.operation=='yield')
        ''')

    def test_yield_outside_field_remains_bounded_to_local_verge(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return {{x=-40,z=110},{x=40,z=110},{x=40,z=250},{x=-40,z=250}} end
            Q.take(u,'prepare'); nativeRequest()
            local w=assert(W.new(u)); assert(not w.entrance)
            assert(not W.clear(w,W.poses(w.model)))
        ''')

    def test_two_harvesters_must_both_clear(self):
        self.lua.execute('''
            place(25,0,0); Q.take(u,'prepare'); nativeRequest()
            local second,other=makeHarvester(30,0,0); other.near=true
            assert(Q.priority(u,second))
            harvester.active=false; Q.yieldTarget(u,true)
            assert(u.queueData.operation=='yield')
            second.active=false; Q.yieldTarget(u,true)
            assert(u.queueData.operation=='prepare')
        ''')

    def test_header_sweep_follows_live_route_without_modifying_it(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            local points={{x=0,z=0},{x=0,z=8},{x=10,z=14},{x=25,z=14},{x=70,z=14}}
            c.course=Course(harvester,points,true)
            local course=c.course
            local area=assert(Q.yieldArea(harvester))
            local small={left=.5,right=-.5,front=.5,back=-.5}
            assert(area(W.rectangle(small,{x=22,z=14,t=0})))
            assert(area(W.rectangle(small,{x=7,z=5,t=0}))) -- header-only coverage
            assert(not area(W.rectangle(small,{x=0,z=40,t=0}))) -- straight-ahead strip is not the turn
            assert(not area(W.rectangle(small,{x=65,z=14,t=0}))) -- bounded horizon
            assert(c.course==course and c.course:getNumberOfWaypoints()==#points)
        ''')

    def test_whole_trailer_must_clear_not_just_tractor(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=30}},true)
            place(0,45,0); c.near=false
            Q.take(u,'prepare'); nativeRequest(); Q.yieldTarget(u,true)
            assert(u.queueData.operation=='yield' and not u.queueData.yieldRequests[harvester].clearSince)
            place(0,65,0); g_currentMission.time=300; Q.yieldTarget(u,true)
            g_currentMission.time=2400; Q.yieldTarget(u,true)
            assert(u.queueData.operation=='prepare')
        ''')

    def test_native_direction_switches_do_not_sweep_a_phantom_half_turn(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=10},
                {x=0,z=9,rev=true},{x=0,z=3,rev=true},{x=0,z=4},{x=0,z=20}},true)
            local area=assert(Q.yieldArea(harvester))
            local tiny={left=.05,right=-.05,front=.05,back=-.05}
            assert(area(W.rectangle(tiny,{x=7,z=8,t=0})))
            assert(not area(W.rectangle(tiny,{x=9.5,z=8,t=0})), 'phantom rotation at a direction switch')
        ''')

    def test_dense_waypoints_preserve_the_same_bounded_swept_area(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            local points={}
            for i=0,400 do points[#points+1]={x=0,z=i/10} end
            c.course=Course(harvester,points,true)
            local area=assert(Q.yieldArea(harvester),'dense points exhausted the envelope')
            local tiny={left=.05,right=-.05,front=.05,back=-.05}
            assert(area(W.rectangle(tiny,{x=7,z=30,t=0})))
            assert(not area(W.rectangle(tiny,{x=0,z=40,t=0})))
        ''')

    def test_dense_curve_covers_header_corners_between_samples(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            local points={}
            for i=0,320 do
                local angle=i*math.pi/320
                points[#points+1]={x=8*(1-math.cos(angle)),z=8*math.sin(angle)}
            end
            c.course=Course(harvester,points,true)
            local area=assert(Q.yieldArea(harvester))
            local tiny={left=.01,right=-.01,front=.01,back=-.01}
            for i=1,320 do
                local angle=(i-.5)*math.pi/320
                local pose={x=8*(1-math.cos(angle)),z=8*math.sin(angle),t=angle}
                for _,corner in ipairs(W.rectangle({left=7.6,right=-7.6,front=6,back=-4},pose,0)) do
                    assert(area(W.rectangle(tiny,{x=corner.x,z=corner.z,t=0})))
                end
            end
        ''')

    def test_truly_excessive_sweep_keeps_explicit_fail_closed_limit(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            local points={}
            -- Forward gear throughout: these are real requested half-turns,
            -- not reverse cusps that should preserve physical heading.
            for i=0,25 do points[#points+1]={x=0,z=i%2} end
            c.course=Course(harvester,points,true)
            local area,reason=Q.yieldArea(harvester)
            assert(not area and reason=='harvester route envelope sample limit')
        ''')

    def test_multiple_native_cusps_remain_available_for_yield_and_resume(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            local points={{x=0,z=0},{x=0,z=8},{x=0,z=7,rev=true},
                {x=0,z=3,rev=true},{x=0,z=4},{x=0,z=9},
                {x=0,z=8,rev=true},{x=0,z=5,rev=true},{x=0,z=6},{x=0,z=20}}
            c.course=Course(harvester,points,true)
            place(0,20,0); c.near=true
            Q.take(u,'prepare'); nativeRequest()
            assert(Q.yieldTarget(u),'ordinary reversing turn must permit yielding')
            place(35,0,0); c.near=false
            g_currentMission.time=300; Q.yieldTarget(u,true)
            g_currentMission.time=2400; Q.yieldTarget(u,true)
            assert(u.queueData.operation=='prepare')
        ''')

    def test_reverse_course_envelope_keeps_vehicle_heading(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.course=Course(harvester,{{x=0,z=0,rev=true},{x=0,z=-8,rev=true},{x=0,z=-20,rev=true}},true)
            local area=assert(Q.yieldArea(harvester))
            local body={left=.5,right=-.5,front=.5,back=-.5}
            assert(area(W.rectangle(body,{x=7,z=-15,t=0})))
            assert(not area(W.rectangle(body,{x=7,z=-27,t=0})))
        ''')

    def test_verge_yield_can_search_but_still_rejects_crop_islands_and_obstacles(self):
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return {{x=-40,z=10},{x=40,z=10},{x=40,z=150},{x=-40,z=150}} end
            Q.take(u,'prepare'); nativeRequest()
            local w=assert(W.new(u)); assert(w.entrance)
            local p=W.poses(w.model); assert(W.clear(w,p))
            densityCount=20; assert(not W.clear(w,p)); densityCount=0
            collision=1; assert(not W.clear(w,p)); collision=0
            w.boundary.islands={{{x=-1,z=-1},{x=1,z=-1},{x=1,z=1},{x=-1,z=1}}}
            assert(not W.clear(w,p)); w.boundary.islands={}
            assert(not W.clear(w,W.settledPoses(w.model,{x=90,z=0,t=0})))
            W.delete(w)
        ''')

    def test_actual_search_moves_from_verge_and_resumes_queue(self):
        self.lua.execute('''
            includeHarvesterCollision()
            c.course=Course(harvester,{{x=0,z=12},{x=0,z=4},{x=0,z=5,rev=true},
                {x=0,z=9,rev=true},{x=0,z=8},{x=0,z=-10}},true)
            v.cpGetFieldPolygon=function() return {{x=-80,z=10},{x=80,z=10},{x=80,z=180},{x=-80,z=180}} end
            Q.take(u,'prepare'); nativeRequest()
            local goal=assert(Q.yieldTarget(u))
            Q.request(u,goal); local data=u.queueData
            local done,path,reason
            for i=1,300000 do
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path,reason or 'yield search did not complete')
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=H.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
            end
            for i,p in ipairs(poses) do
                local n=i==1 and v.rootNode or trailer.rootNode
                n.x=p.x; n.z=p.z; n.t=p.t
            end
            local x,z=H.math.position(v.rootNode,0,-3.3)
            trailer.joint.node.x=x; trailer.joint.node.z=z; trailer.joint.node.t=v.rootNode.t
            Q.startRoute(data,path); assert(Q.onLast(u)); c.near=false
            Q.yieldTarget(u,true); g_currentMission.time=2100; Q.yieldTarget(u,true)
            assert(data.operation=='prepare')
            -- Complete recovery into a real straight headland slot, including
            -- articulated route validation and final trailer alignment.
            c.fieldWorkCourse=Course(harvester,{{x=50,z=20},{x=50,z=50},{x=50,z=80},
                {x=50,z=110},{x=50,z=140},{x=50,z=170}},false)
            for i=1,6 do c.fieldWorkCourse:getWaypoint(i).attributes:setHeadlandPassNumber(1) end
            Q.combines={test={driver=c,position={x=0,z=12}}}
            u.isServingPosition=function() return true end
            u.invertedStartPositionMarkerNode={x=50,z=10,t=0}
            data.assignment={}
            local parking=assert(nativeQueueTarget(u))
            assert(parking.x==50 and math.abs(H.math.delta(parking.t,0))<0.001)
            Q.request(u,parking)
            for i=1,100000 do
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path,reason or 'return to aligned parking failed')
            poses=W.poses(data.world.model)
            for i=2,#path do
                poses=H.advance(data.world.model,poses,path[i]); assert(W.clear(data.world,poses))
            end
            for _,p in ipairs(poses) do
                assert(math.abs(H.math.delta(p.t,parking.t))<math.rad(5))
            end
            Q.startRoute(data,path); Q.onLast(u)
            assert(data.operation=='prepare' and data.parkedGoal==parking)
        ''')

    def test_unavailable_geometry_holds_without_repeating_two_messages(self):
        self.lua.execute('''
            local messages={}
            u.debug=function(_,format,reason) messages[#messages+1]=reason end
            Q.take(u,'prepare'); nativeRequest(); messages={}
            Q.yieldArea=function() return nil,'harvester body geometry unavailable' end
            for i=1,20 do g_currentMission.time=i*250; Q.tick(u) end
            assert(#messages==1 and messages[1]:find('body geometry unavailable',1,true))
            assert(u.queueData.operation=='yield' and not u:isAllowedToBeCalled())
        ''')

    def test_forward_pass_can_win_over_slow_reverse(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,22,math.pi); c.near=true
            includeHarvesterCollision()
            u.settings.reverseSpeed.getValue=function() return 1 end
            Q.take(u,'prepare'); nativeRequest()
            Q.request(u,assert(Q.yieldTarget(u)))
            local done,path,reason
            for i=1,300000 do
                done,path,reason=CpUnloaderQueueSearch.step(u.queueData.search,1)
                if done then break end
            end
            assert(done and path and not path.reverse,reason or 'forward clearance did not win')
        ''')

    def test_failed_yield_stays_owned_and_cannot_be_called(self):
        self.lua.execute('''
            Q.take(u,'prepare'); nativeRequest(); densityCount=20
            Q.request(u,assert(Q.yieldTarget(u)))
            assert(not u.queueData.search and u.queueData.reason:find('standing crop',1,true))
            assert(u.queueData.operation=='yield' and not u:isAllowedToBeCalled())
        ''')

    def test_detour_failure_forward_escape_clears_whole_reserved_turn(self):
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0); c.near=false
            c.course=Course(harvester,{{x=0,z=0},{x=0,z=15},{x=20,z=20}},true)
            place(0,25,0); includeHarvesterCollision()
            v.cpGetFieldPolygon=function() return {{x=-80,z=-80},{x=80,z=-80},{x=80,z=180},{x=-80,z=180}} end
            Q.take(u,'prepare'); nativeRequest()
            local request=u.queueData.yieldRequests[harvester]
            request.turnClearance=assert(Q.yieldArea(harvester,c.course,math.huge,1600))
            request.preferForward=true
            Q.request(u,assert(Q.yieldTarget(u)))
            local data=u.queueData
            assert(data.search,data.reason or 'escape search did not start')
            local done,path,reason
            for i=1,300000 do
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path and not path.reverse,reason or 'no forward clearance')
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=H.advance(data.world.model,poses,path[i])
                assert(W.clear(data.world,poses),'escape intersects live collision or crop')
            end
            for i,p in ipairs(poses) do
                assert(not request.turnClearance(W.rectangle(data.world.model.bodies[i],p)),
                    'trailer remains in reserved turn')
            end
        ''')


if __name__ == '__main__': unittest.main()
