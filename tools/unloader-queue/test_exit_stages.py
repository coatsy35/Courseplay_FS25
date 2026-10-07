"""Row -> headland -> AD journeys using the production articulated route code."""
import sys
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0,str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT=ROOT


class ExitJourneyTests(unittest.TestCase):
    def setUp(self):
        runtime.EngineBoundaryTests.setUp(self)
        self.lua.execute('''
            Q=CpUnloaderQueue; W=CpUnloaderQueueWorld; S=CpUnloaderQueueSearch; H=HeadlandLoopGeometry
            v.cpGetFieldPolygon=function()
                return {{x=-120,z=-40},{x=120,z=-40},{x=120,z=350},{x=-120,z=350}}
            end
            u.setMaxSpeed=function() end
            u.startCourse=function(self,course) self.course=course end
            u.settings={reverseSpeed={getValue=function() return 10 end}}
            u.getFieldSpeed=function() return 15 end
            u.ppc={getReverserNode=function() return trailer.steeringAxleNode end}
            handedOver=0
            u.onTrailerFull=function() handedOver=handedOver+1 end
            nodes={{id=1,x=80,z=0,out={2}},{id=2,x=90,z=0,out={3}},{id=3,x=110,z=0,out={}}}
            FS25_AutoDrive={ADGraphManager={getWayPointById=function(_,id) return nodes[id] end,
                getWayPointsInRange=function(_,p,minimum,maximum)
                    local result={}
                    for _,n in ipairs(nodes) do
                        local d=math.sqrt((n.x-p.x)^2+(n.z-p.z)^2)
                        if d>minimum and d<=maximum then result[#result+1]=n end
                    end
                    return result
                end,
                pathFromTo=function(_,start,destination)
                    local result={}; for i=start+1,destination do result[#result+1]=nodes[i] end; return result
                end}}
            v.ad={stateModule={getMode=function() return 2 end,getSecondWayPoint=function() return 3 end}}
            data=Q.take(u,'exit')
            data.departure={width=30,row={{x=0,z=25},{x=0,z=100},{x=0,z=200},{x=0,z=260}},
                position={x=0,z=260},headlands={{{x=-100,z=0,t=math.pi/2},{x=100,z=0,t=math.pi/2}}}}
            -- Engine crop map: harvested centre row and headland, standing crop elsewhere.
            W.cropFree=function(_,rectangle)
                for i,a in ipairs(rectangle) do
                    local b=rectangle[i%#rectangle+1]
                    for j=0,10 do
                        local x,z=a.x+(b.x-a.x)*j/10,a.z+(b.z-a.z)*j/10
                        if not (math.abs(z)<=15 or (math.abs(x)<=18 and z>=0 and z<=280)) then return false end
                    end
                end
                return true
            end
            function place(x,z,t)
                v.rootNode.x=x; v.rootNode.z=z; v.rootNode.t=t
                local a,b=H.math.position(v.rootNode,0,-9.8)
                trailer.rootNode.x=a; trailer.rootNode.z=b; trailer.rootNode.t=t
                a,b=H.math.position(v.rootNode,0,-3.3)
                trailer.joint.node.x=a; trailer.joint.node.z=b; trailer.joint.node.t=t
            end
            function driveLeg(goal,corridor)
                Q.request(u,goal,corridor)
                assert(data.search,data.reason)
                local done,path,reason
                for i=1,200000 do
                    done,path,reason=S.step(data.search,1)
                    if done then break end
                end
                assert(done and path,reason or 'no completed path')
                local poses=W.poses(data.world.model)
                for i=2,#path do poses=H.advance(data.world.model,poses,path[i]) end
                for i,p in ipairs(poses) do
                    local n=i==1 and v.rootNode or trailer.rootNode
                    n.x=p.x; n.z=p.z; n.t=p.t
                end
                local x,z=H.math.position(v.rootNode,0,-3.3)
                trailer.joint.node.x=x; trailer.joint.node.z=z; trailer.joint.node.t=v.rootNode.t
                Q.startRoute(data,path)
                assert(Q.onLast(u))
                g_currentMission.time=g_currentMission.time+1000
            end
        ''')

    def test_complete_mid_row_departure_before_ad_handover(self):
        self.lua.execute('''
            place(0,240,math.pi)
            local stages={}
            for leg=1,15 do
                local goal,corridor=Q.exitTarget(u)
                assert(goal,data.reason)
                stages[goal.exitStage]=true
                if goal.exitStage=='row return' then
                    assert(math.abs(goal.x)<0.01 and goal.z>=25)
                    assert(not Q.canFinishExit(u))
                end
                driveLeg(goal,corridor)
                if not goal.exitIntermediate then Q.finishExit(u); break end
                assert(handedOver==0)
            end
            assert(handedOver==1 and stages['row return'] and stages['headland entry'] and stages['AD approach'])
        ''')

    def test_row_target_is_local_and_points_back_to_headland(self):
        self.lua.execute('''
            place(0,240,0)
            local goal=assert(Q.exitTarget(u))
            assert(goal.exitStage=='row return' and goal.z==190 and goal.x==0)
            assert(math.cos(goal.t)<-0.99 and goal.exitIntermediate)
        ''')

    def test_loaded_rig_turns_back_from_pipe_side_then_returns_down_row(self):
        self.lua.execute('''
            place(10,240,0)
            local goal,corridor=Q.exitTarget(u)
            driveLeg(goal,corridor)
            assert(v.rootNode.z<200 and math.cos(v.rootNode.t)<-0.99)
            assert(handedOver==0)
        ''')

    def test_direct_turns_in_both_directions_finish_with_aligned_trailer(self):
        for side in (-1,1):
            with self.subTest(side=side):
                self.setUp()
                self.lua.globals().side=side
                self.lua.execute('''
                    place(0,40,math.pi)
                    local world=assert(W.new(u))
                    local goal={x=side*50,z=0,t=side*math.pi/2}
                    local search=assert(S.new(world,goal))
                    search.directOnly=true
                    local done,path,reason
                    for i=1,10000 do done,path,reason=S.step(search,1); if done then break end end
                    assert(done and path,reason)
                    local poses=W.poses(world.model)
                    for i=2,#path do poses=H.advance(world.model,poses,path[i]) end
                    for _,p in ipairs(poses) do assert(math.abs(H.math.delta(p.t,goal.t))<math.rad(10)) end
                ''')

    def test_obstructed_row_uses_validated_detour_inside_harvested_corridor(self):
        self.lua.execute('''
            place(0,190,math.pi)
            overlapBox=function(x,y,z,rx,t,rz,w,h,l,callback,detector)
                local dx,dz=-x,163-z
                detector.collidingShapes=(math.abs(dx*math.cos(t)-dz*math.sin(t))<w+1.5 and
                    math.abs(dx*math.sin(t)+dz*math.cos(t))<l+3) and 1 or 0
            end
            local goal,corridor=Q.exitTarget(u)
            driveLeg(goal,corridor)
            assert(v.rootNode.z<145 and handedOver==0)
        ''')

    def test_perimeter_journey_links_split_bands_without_crop_shortcut(self):
        self.lua.execute('''
            place(0,0,math.pi/2)
            data.departure.headlands={{{x=-100,z=0},{x=90,z=0}},{{x=90,z=0},{x=90,z=250}}}
            nodes[1].x=90; nodes[1].z=160
            nodes[2].x=90; nodes[2].z=170
            nodes[3].x=90; nodes[3].z=190
            W.cropFree=function(_,rectangle)
                for i,a in ipairs(rectangle) do
                    local b=rectangle[i%#rectangle+1]
                    for j=0,10 do
                        local x,z=a.x+(b.x-a.x)*j/10,a.z+(b.z-a.z)*j/10
                        if not (math.abs(z)<=15 or math.abs(x-90)<=15) then return false end
                    end
                end
                return true
            end
            for i=1,10 do
                local goal,corridor=Q.exitTarget(u); assert(goal,data.reason)
                if i==1 then assert(goal.x==50 and goal.z==0 and goal.exitIntermediate) end
                driveLeg(goal,corridor)
                if not goal.exitIntermediate then Q.finishExit(u); break end
                assert(handedOver==0)
            end
            assert(handedOver==1)
        ''')

    def test_short_headland_band_has_valid_entry_and_handover(self):
        self.lua.execute('''
            place(0,40,math.pi)
            data.departure.headlands={{{x=-40,z=0},{x=40,z=0}}}
            nodes[1].x=35; nodes[2].x=45; nodes[3].x=55
            local goal,corridor=Q.exitTarget(u)
            assert(goal and goal.exitStage=='headland entry' and math.abs(goal.x)==35)
            driveLeg(goal,corridor)
            goal,corridor=Q.exitTarget(u); assert(goal and not goal.exitIntermediate)
            driveLeg(goal,corridor); Q.finishExit(u)
            assert(handedOver==1)
        ''')

    def test_tick_advances_stages_and_cannot_handover_midfield(self):
        self.lua.execute('''
            place(0,240,math.pi)
            Q.refresh=function() end; Q.schedule=function() end
            u.states={IDLE={}}
            for i=1,15 do
                data.nextAttempt=0; Q.tick(u)
                if handedOver>0 then break end
                assert(data.goal and data.search,data.reason)
                local goal,corridor=data.goal,data.corridor
                driveLeg(goal,corridor)
                if goal.exitIntermediate then assert(handedOver==0) end
            end
            assert(handedOver==1)
        ''')

    def test_rejected_row_target_selects_another_without_waiving_crop(self):
        self.lua.execute('''
            place(0,240,math.pi)
            local goal=assert(Q.exitTarget(u)); data.goal=goal
            Q.failed(data,'destination: standing crop','destination')
            local alternative=assert(Q.exitTarget(u))
            assert(alternative.z~=goal.z and alternative.exitStage=='row return')
            W.cropFree=function() return false end
            Q.request(u,alternative)
            assert(not data.search and data.reason=='start: standing crop' and handedOver==0)
        ''')

    def test_headland_entry_does_not_require_outgoing_road_heading(self):
        self.lua.execute('''
            place(0,40,math.pi)
            nodes[2].x=80; nodes[2].z=-20
            local goal=assert(Q.exitTarget(u))
            assert(goal.exitStage=='headland entry' and math.abs(math.sin(goal.t))>0.99)
            assert(goal.accept(W.settledPoses(W.model(v),goal),W.model(v)))
            assert(not Q.canFinishExit(u))
        ''')

    def test_blocked_and_reserved_headland_entries_are_not_repeated(self):
        self.lua.execute('''
            place(0,40,math.pi)
            local first=assert(Q.exitTarget(u)); data.goal=first
            Q.failed(data,'destination: standing crop','destination')
            local second=assert(Q.exitTarget(u))
            assert(second.x~=first.x)
            local other={vehicle=v}
            Q.members[other]={goal=second}
            local third=Q.exitTarget(u)
            assert(not third or math.abs(third.x-second.x)>10)
        ''')

    def test_multitool_perimeter_includes_other_lane_without_mutating_course(self):
        self.lua.execute('''
            local course=Course(v,{{x=-100,z=0},{x=100,z=0}},false)
            local other=Course(v,{{x=-100,z=-15},{x=100,z=-15}},false)
            for _,c in ipairs({course,other}) do
                for i=1,2 do
                    c:getWaypoint(i).attributes:setHeadlandPassNumber(1)
                    c:getWaypoint(i).attributes:setBoundaryId('F')
                end
            end
            course.multiVehicleData={waypoints={[-1]=course.waypoints,[1]=other.waypoints}}
            local original=course.waypoints
            local bands=Q.headlands(course)
            assert(#bands==2 and course.waypoints==original)
            other.waypoints[1].z=999
            for _,band in ipairs(bands) do assert(band[1].z~=999) end
        ''')

    def test_active_course_headland_offsets_are_preserved(self):
        self.lua.execute('''
            local course=Course(v,{{x=-100,z=0},{x=100,z=0}},false)
            for i=1,2 do
                course:getWaypoint(i).attributes:setHeadlandPassNumber(1)
                course:getWaypoint(i).attributes:setBoundaryId('F')
            end
            course:setOffset(3,2)
            local bands=Q.headlands(course)
            for i=1,2 do
                local x,_,z=course:getWaypointPosition(i)
                assert(bands[1][i].x==x and bands[1][i].z==z)
            end
        ''')

    def test_search_work_allowance_is_independent_of_frame_interval(self):
        for interval in (16,50,100):
            with self.subTest(frame_ms=interval):
                self.setUp()
                self.lua.globals().interval=interval
                self.lua.execute('''
                    data.search={}; data.searchGeneration=data.generation; data.searchWorkMs=14998
                    S.step=function() return false end
                    openIntervalTimer=function() return 1 end
                    readIntervalTimerMs=function() return 2 end
                    closeIntervalTimer=function() end
                    g_updateLoopIndex=1; g_currentMission.time=interval; Q.schedule()
                    assert(data.search and data.searchWorkMs==15000)
                    g_updateLoopIndex=2; g_currentMission.time=2*interval; Q.schedule()
                    assert(not data.search and data.searchWorkMs==15002)
                ''')

    def test_unenriched_multitool_lane_preserves_offsets_without_mutation(self):
        self.lua.execute('''
            local course=Course(v,{{x=-100,z=0},{x=100,z=0}},false)
            local raw={Waypoint({x=-100,z=-15}),Waypoint({x=100,z=-15})}
            for _,lane in ipairs({course.waypoints,raw}) do
                for _,wp in ipairs(lane) do
                    wp.attributes:setHeadlandPassNumber(1)
                    wp.attributes:setBoundaryId('F')
                end
            end
            assert(raw[1].dx==nil and raw[2].dz==nil)
            course.multiVehicleData={waypoints={[-1]=course.waypoints,[1]=raw}}
            course:setOffset(3,2)
            local bands=Q.headlands(course)
            local found=false
            for _,band in ipairs(bands) do
                if band[1].z<0 then
                    assert(band[1].x==-98 and band[1].z==-12)
                    assert(band[2].x==102 and band[2].z==-12)
                    found=true
                end
            end
            assert(found and raw[1].dx==nil and raw[2].dz==nil and raw[1].x==-100)
        ''')


if __name__=='__main__': unittest.main()
