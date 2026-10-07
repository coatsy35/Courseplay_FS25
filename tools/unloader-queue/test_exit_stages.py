"""Row -> headland -> AD journeys using the production articulated route code."""
import sys
import json
import heapq
import math
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
            openIntervalTimer=function() return 1 end
            readIntervalTimerMs=function() return 0 end
            closeIntervalTimer=function() end
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

    def test_narrow_work_width_keeps_row_join_connected_and_completes_handover(self):
        self.lua.execute('''
            data.departure.width=15.2
            place(0,70,math.pi)
            local stages={}
            for leg=1,12 do
                local goal,corridor=Q.exitTarget(u); assert(goal,data.reason)
                stages[goal.exitStage]=true
                for z=0,25 do assert(corridor({{x=0,z=z}}), 'gap between row and headland') end
                driveLeg(goal,corridor)
                if not goal.exitIntermediate then Q.finishExit(u); break end
                assert(handedOver==0)
            end
            assert(handedOver==1 and stages['row approach'] and stages['headland entry'])
        ''')

    def test_complete_exit_invokes_native_full_job_handover_through_queue_hook(self):
        self.lua.execute((ROOT/'scripts/CpObject.lua').read_text())
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine','AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT/f'scripts/ai/strategies/{name}.lua').read_text())
        self.lua.execute((ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text())
        self.lua.execute('''
            local fullMessage={}
            AIMessageErrorIsFull={new=function() return fullMessage end}
            v.stopCurrentAIJob=function(_,message)
                assert(message==fullMessage and Q.canFinishExit(u))
                handedOver=handedOver+1
            end
            u.onTrailerFull=AIDriveStrategyUnloadCombine.onTrailerFull
            data.departure.width=15.2
            place(0,70,math.pi)
            for leg=1,12 do
                local goal,corridor=Q.exitTarget(u); assert(goal,data.reason)
                driveLeg(goal,corridor)
                if not goal.exitIntermediate then Q.finishExit(u); break end
                assert(handedOver==0)
            end
            assert(handedOver==1 and data.handover)
        ''')

    def test_traffic_clearance_rejoins_row_from_actual_rig_without_crop_waiver(self):
        self.lua.execute('''
            data.departure.width=15.2
            place(22,175,math.pi)
            -- An already harvested adjacent strip is available after native backup.
            W.cropFree=function(_,rectangle)
                for _,p in ipairs(rectangle) do
                    if math.abs(p.x)>35 or p.z<0 or p.z>280 then return false end
                end
                return true
            end
            local goal,corridor=Q.exitTarget(u)
            local world=assert(W.new(u))
            assert(W.clear(world,W.poses(world.model),corridor))
            assert(not corridor({{x=70,z=175}}), 'local re-entry must not allow a field shortcut')
            driveLeg(goal,corridor)
            assert(math.abs(v.rootNode.x)<1.5 and v.rootNode.z<140 and handedOver==0)
            place(22,175,math.pi)
            goal,corridor=Q.exitTarget(u)
            W.cropFree=function() return false end
            Q.request(u,goal,corridor)
            assert(not data.search and data.reason=='start: standing crop')
            W.cropFree=function() return true end; collision=1
            Q.request(u,goal,corridor)
            assert(not data.search and data.reason=='start: vehicle or obstacle')
        ''')

    def test_actual_two_harvester_headlands_use_row_approach_before_turning(self):
        geometry=json.loads((SOURCE/'tools/unloader-queue/fixtures/two-harvester-headlands.json').read_text())
        self.lua.globals().realbands=self.lua.table_from([
            self.lua.table_from([self.lua.table_from(dict(x=x,z=z)) for x,z in band])
            for band in geometry['bands']])
        self.lua.execute('''
            v.cpGetFieldPolygon=function()
                return {{x=-1000,z=-2000},{x=1000,z=-2000},{x=1000,z=1000},{x=-1000,z=1000}}
            end
            -- Isolate the actual course corridor; separate tests enforce crop/obstacles.
            W.cropFree=function() return true end
            u.turningRadius=9
            place(-92.4,-935.9,math.rad(171))
            data.departure={width=15.2,headlands=realbands,
                row={{x=-85.58,z=-979.08},{x=-180.7,z=-378.6}},position={x=-180.7,z=-378.6}}
            local approach,corridor=Q.exitTarget(u)
            assert(approach.exitStage=='row approach')
            driveLeg(approach,corridor)
            local goal,corridor=Q.exitTarget(u)
            assert(goal.exitStage=='headland entry')
            assert(math.abs(goal.x+38.3099)<0.1 and math.abs(goal.z+971.9073)<0.1)
            -- Both stages must succeed as direct checked routes, avoiding the
            -- former repeated exhaustive searches of a diagonal entry.
            Q.request(u,goal,corridor); assert(data.search,data.reason)
            data.search.directOnly=true
            local done,path,reason
            for i=1,3000 do done,path,reason=S.step(data.search,1); if done then break end end
            assert(done and path,reason or 'entry used exhaustive search')
            local poses=W.poses(data.world.model)
            for i=2,#path do poses=H.advance(data.world.model,poses,path[i]) end
            assert(goal.accept(poses,data.world.model) and handedOver==0)
        ''')

    def test_saved_field_and_ad_network_complete_onward_handover(self):
        geometry=json.loads((SOURCE/'tools/unloader-queue/fixtures/two-harvester-headlands.json').read_text())
        network=json.loads((SOURCE/'tools/unloader-queue/fixtures/two-harvester-ad-connections.json').read_text())
        self.lua.globals().fieldEdge=self.lua.table_from([
            self.lua.table_from(dict(x=x,z=z)) for x,z in geometry['fieldBoundaryEstimate']])
        self.lua.globals().realbands=self.lua.table_from([
            self.lua.table_from([self.lua.table_from(dict(x=x,z=z)) for x,z in band])
            for band in geometry['bands']])
        self.lua.globals().adnodes=self.lua.table_from({n['id']:self.lua.table_from(
            dict(n,out=self.lua.table_from(n['out']))) for n in network['nodes']})
        # Route every retained node, not only the two older entry neighbourhoods.
        # This is a directed-distance graph adapter, not AutoDrive turn policy.
        by_id={node['id']:node for node in network['nodes']}
        incoming={node_id:[] for node_id in by_id}
        for node in by_id.values():
            for other in node['out']:
                if other in by_id:
                    incoming[other].append((node['id'],math.hypot(
                        node['x']-by_id[other]['x'],node['z']-by_id[other]['z'])))
        destination=network['destination']['waypointId']
        costs={destination:0}; next_hop={}; pending=[(0,destination)]
        while pending:
            cost,node_id=heapq.heappop(pending)
            if cost!=costs[node_id]: continue
            for previous,length in incoming[node_id]:
                candidate=cost+length
                if candidate<costs.get(previous,float('inf')):
                    costs[previous]=candidate; next_hop[previous]=node_id
                    heapq.heappush(pending,(candidate,previous))
        routes={}
        for start in by_id:
            route=[]; node_id=start
            while node_id in next_hop:
                node_id=next_hop[node_id]; route.append(node_id)
            if node_id==destination: routes[start]=self.lua.table_from(route)
        self.lua.globals().adpaths=self.lua.table_from(routes)
        self.lua.execute('''
            v.cpGetFieldPolygon=function() return fieldEdge end
            -- Recorded route geometry; live crop, scenery and GIANTS driving
            -- remain external boundaries. Other tests exercise their rejection.
            W.cropFree=function() return true end
            FS25_AutoDrive.ADGraphManager={
                getWayPointById=function(_,id) return adnodes[id] end,
                getWayPointsInRange=function(_,p,minimum,maximum)
                    local ids={}
                    for id,n in pairs(adnodes) do
                        local d=math.sqrt((p.x-n.x)^2+(p.z-n.z)^2)
                        if d>minimum and d<maximum then ids[#ids+1]=id end
                    end
                    return ids
                end,
                pathFromTo=function(_,start,finish)
                    assert(finish==10675)
                    local path={}
                    for _,id in ipairs(adpaths[start] or {}) do path[#path+1]=adnodes[id] end
                    return path
                end}
            v.ad.stateModule.getSecondWayPoint=function() return 10675 end
            u.turningRadius=9
            Q.refresh=function() end; Q.schedule=function() end
            u.states={IDLE={}}
            local cases={
                {x=-92.4,z=-935.9,t=171,row={{x=-85.58,z=-979.08},{x=-180.7,z=-378.6}}},
                {x=-137.2,z=-264.5,t=351,row={{x=-144.34,z=-219.45},{x=-99.6,z=-502}}},
                -- Logged /325 headland-entry target at 22:28:12 on 7 October.
                -- Include its local AD nodes even outside older route snapshots.
                -- Earlier row geometry is representative, not logged in full.
                {x=-181.4,z=-1000.1,t=270,onHeadland=true,
                    row={{x=-130,z=-990},{x=-200,z=-550}}}
            }
            for _,case in ipairs(cases) do
                place(case.x,case.z,math.rad(case.t))
                data=Q.take(u,'exit'); handedOver=0
                data.departure={width=15.2,headlands=realbands,row=case.row,position=case.row[2]}
                local stages={}
                for leg=1,12 do
                    data.nextAttempt=0; Q.tick(u)
                    for attempt=1,400 do
                        if not data.exitConnectionPending then break end
                        g_currentMission.time=g_currentMission.time+200; Q.tick(u)
                    end
                    assert(not data.exitConnectionPending,'headland candidate scan did not finish')
                    if handedOver>0 then break end
                    local goal,corridor=data.goal,data.corridor
                    assert(goal and data.search,data.reason)
                    stages[goal.exitStage]=true
                    driveLeg(goal,corridor)
                    assert(handedOver==0)
                end
                assert(handedOver==1,data.reason)
                if not case.onHeadland then assert(stages['row approach'] and stages['headland entry']) end
            end
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
            place(0,25,math.pi)
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
            place(0,25,math.pi)
            nodes[2].x=80; nodes[2].z=-20
            local goal=assert(Q.exitTarget(u))
            assert(goal.exitStage=='headland entry' and math.abs(math.sin(goal.t))>0.99)
            assert(goal.accept(W.settledPoses(W.model(v),goal),W.model(v)))
            assert(not Q.canFinishExit(u))
        ''')

    def test_blocked_and_reserved_headland_entries_are_not_repeated(self):
        self.lua.execute('''
            place(0,25,math.pi)
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

    def test_narrow_headland_connection_uses_actual_rig_width(self):
        self.lua.execute('''
            data.departure.width=15.2
            data.departure.headlands={{{x=0,z=-100},{x=0,z=100}}}
            data.departure.row={{x=0,z=0},{x=80,z=0}}
            nodes={{id=1,x=5,z=0,out={2}},{id=2,x=5,z=20,out={3}},{id=3,x=5,z=40,out={}}}
            place(0,0,0)
            W.cropFree=function(_,rectangle)
                for _,p in ipairs(rectangle) do if math.abs(p.x)>7.6 then return false end end
                return true
            end
            local node,_,site=Q.connectedNode(u,{x=0,z=0,t=0},data.departure,20)
            assert(node and site.x==0)
            assert(Q.canFinishExit(u),'turning-radius margin falsely rejects a clear headland connection')
            W.cropFree=function(_,rectangle)
                for _,p in ipairs(rectangle) do if p.x>4 then return false end end
                return true
            end
            local clear,reason=Q.canFinishExit(u)
            assert(not clear and reason=='perimeter connection obstructed')
        ''')

    def test_headland_scan_reaches_later_connected_nodes_in_bounded_batches(self):
        for elapsed, batch in ((0,8),(3,1)):
            with self.subTest(measured_ms=elapsed):
                self.setUp()
                self.lua.globals().elapsed=elapsed
                self.lua.globals().batch=batch
                self.lua.execute('''
                    nodes={}
                    for id=1,40 do nodes[id]={id=id,x=-80+id*4,z=0,out={100}} end
                    nodes[100]={id=100,x=1000,z=0,out={}}
                    v.ad.stateModule.getSecondWayPoint=function() return 100 end
                    FS25_AutoDrive.ADGraphManager.pathFromTo=function() return {nodes[100]} end
                    readIntervalTimerMs=function() return elapsed end
                    local visits=0; local node
                    for attempt=1,40 do
                        local before=visits
                        node=Q.connectedNode(u,{x=-80,z=0},data.departure,200,function(candidate)
                            visits=visits+1; return candidate.id==28
                        end)
                        assert(visits-before<=batch)
                        if node then break end
                        assert(data.exitConnectionPending)
                    end
                    assert(node and node.id==28 and visits==28)
                    assert(not data.exitConnectionPending and not data.exitConnectionScan)
                    Q.connectedNode(u,{x=-80,z=0},data.departure,200,function() return false end)
                    assert(data.exitConnectionScan)
                    Q.cancel(u)
                    assert(not data.exitConnectionScan and not data.exitConnectionPending)
                ''')

    def test_exit_tries_other_direct_goals_before_hybrid_search(self):
        self.lua.execute('''
            place(10,240,0)
            local goal,corridor=Q.exitTarget(u)
            assert(#goal.choices==3)
            -- This rig cannot settle its articulation in the 35 m option, but
            -- can turn safely into the 50 m option using the real route code.
            local short,long=goal.choices[2],goal.choices[1]
            goal.choices={short,long}
            Q.request(u,goal,corridor)
            local search=data.search
            assert(search and search.corridor==corridor and search.firstValid)
            local done,path,reason
            for i=1,20000 do
                done,path,reason=S.step(search,1)
                assert(not search.fallback, 'expanded hybrid search before trying another direct target')
                if search.active then assert(search.active.expanded==0) end
                if done then break end
            end
            assert(done and path,reason or 'direct alternatives did not complete')
            assert(path.goal==long and search.index==2)
            local poses=W.poses(data.world.model)
            for i=2,#path do
                poses=H.advance(data.world.model,poses,path[i])
                assert(W.clear(data.world,poses,corridor))
            end
            Q.startRoute(data,path)
            assert(data.goal==long)
            Q.onLast(u)
            assert(data.parkedGoal==long)
        ''')

    def test_choice_fallback_preserves_exit_corridor(self):
        self.lua.execute('''
            place(0,240,math.pi)
            local goal,corridor=Q.exitTarget(u)
            local search=assert(S.choices(assert(W.new(u)),goal.choices,corridor))
            -- Bypass only direct candidates to exercise fallback construction.
            search.index=#search.choices+1
            S.step(search,1)
            assert(search.fallback and search.fallback.corridor==corridor)
            local invalid,reason=S.choices(assert(W.new(u)),goal.choices,function() return false end)
            assert(not invalid and reason)
        ''')

    def test_exit_searches_precede_parking_and_rotate_within_priority(self):
        self.lua.execute('''
            data.search={}; data.searchGeneration=data.generation
            local second=setmetatable({vehicle=v,queueData=false},{__index=u})
            local exit2=Q.take(second,'exit')
            exit2.search={}; exit2.searchGeneration=exit2.generation
            local parking=setmetatable({vehicle=v,queueData=false},{__index=u})
            local prepare=Q.take(parking,'prepare')
            prepare.search={}; prepare.searchGeneration=prepare.generation
            local advances={}
            S.step=function(search) advances[#advances+1]=search; return false end
            openIntervalTimer=function() return 1 end
            readIntervalTimerMs=function() return 2 end
            closeIntervalTimer=function() end
            for i=1,2 do
                g_updateLoopIndex=i; g_currentMission.time=i*16; Q.schedule(); Q.schedule()
            end
            assert(#advances==2 and advances[1]~=advances[2])
            assert(advances[1]~=prepare.search and advances[2]~=prepare.search)
            data.search=nil; exit2.search=nil
            g_updateLoopIndex=3; g_currentMission.time=48; Q.schedule()
            assert(#advances==3 and advances[3]==prepare.search)
        ''')

    def test_search_work_allowance_is_independent_of_frame_interval(self):
        for interval in (16,50,100):
            with self.subTest(frame_ms=interval):
                self.setUp()
                self.lua.globals().interval=interval
                self.lua.execute('''
                    data.search={}; data.searchGeneration=data.generation; data.searchWorkMs=998
                    S.step=function() return false end
                    openIntervalTimer=function() return 1 end
                    readIntervalTimerMs=function() return 2 end
                    closeIntervalTimer=function() end
                    g_updateLoopIndex=1; g_currentMission.time=interval; Q.schedule()
                    assert(data.search and data.searchWorkMs==1000)
                    g_updateLoopIndex=2; g_currentMission.time=2*interval; Q.schedule()
                    assert(not data.search and data.searchWorkMs==1002)
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
