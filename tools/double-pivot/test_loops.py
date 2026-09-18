"""Production Lua loop planner at a planar GIANTS boundary, not game physics."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute((SOURCE / 'tools/double-pivot/engine-boundary.lua').read_text(encoding='utf-8-sig'))

    def test_detection_uses_two_independent_hitches_and_unfolded_width(self):
        self.lua.execute('''
            local v,c,d,cart=fixture()
            local m=assert(HeadlandLoopGeometry.detect(v))
            assert(#m.links==2 and math.abs(m.width-25.6)<1e-6)
            assert(math.abs(m.links[1].length-6.5)<1e-6)
            assert(math.abs(m.links[1].hitch+3.3)<1e-6)
            assert(math.abs(m.links[2].length-8.08)<1e-6)
            assert(math.abs(m.links[2].hitch+4.47)<1e-6)
            assert(HeadlandLoopGeometry.minimumRadius(m,10)>10)
            assert(not HeadlandLoopGeometry.minimumRadius(m,0))
        ''')

    def test_internal_drawbar_is_split_into_two_pivots(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local v,c,d,cart=fixture({internal=true,width=30})
            local m=assert(G.detect(v))
            assert(#m.links==3 and m.internalPivots==1)
            assert(math.abs(m.links[2].length-3.78)<.02 and m.links[2].internal)
            assert(math.abs(m.links[3].length-4.30)<.02 and m.links[3].internal)
            assert(math.abs(m.links[2].maxArticulation-G.maxArticulation)<1e-6)
            assert(math.abs(m.links[3].maxArticulation-math.pi/3)<1e-6)
            assert(math.abs(m.width-30)<1e-6)
        ''')

    def test_working_width_does_not_inflate_axle_turning_radius(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local narrow=assert(G.detect(fixture({internal=true,width=8})))
            local wide=assert(G.detect(fixture({internal=true,width=30})))
            local nr,wr=assert(G.minimumRadius(narrow,10)),assert(G.minimumRadius(wide,10))
            assert(math.abs(nr-wr)<.001, string.format('width changed radius %.2f -> %.2f',nr,wr))
        ''')

    def test_unsupported_geometry_is_not_silently_modelled(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            v,c,d,cart=fixture({single=true}); assert(not G.detect(v))
            v,c,d,cart=fixture(); cart.steeringAxleNode=nil; assert(not G.detect(v))
            v,c,d,cart=fixture(); cart.joint.node.x=2; assert(not G.detect(v))
            v,c,d,cart=fixture(); cart.spec_wheels.wheels[1].steering.steeringAxleScale=1; assert(not G.detect(v))
            v,c,d,cart=fixture(); v.children[2]={object=cart}; assert(not G.detect(v))
        ''')

    def test_second_link_length_changes_radius_but_width_does_not(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local narrow=G.detect(fixture({width=8,cartLength=5}))
            local wide=G.detect(fixture({width=40,cartLength=5}))
            local long=G.detect(fixture({width=8,cartLength=14}))
            assert(math.abs(G.minimumRadius(wide,10)-G.minimumRadius(narrow,10))<.001)
            assert(G.minimumRadius(long,10)>G.minimumRadius(narrow,10))
        ''')

    def test_straight_motion_and_independent_circle_solution(self):
        # Independently integrate an on-axle one-trailer circle, whose steady
        # articulation is asin(L/R) and axle radius sqrt(R*R-L*L).
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local m={links={{length=6,hitch=0}}}
            local poses={{x=0,z=0,t=0},{x=0,z=-6,t=0}}
            for i=1,100 do poses=G.advance(m,poses,{x=0,z=i*.1,t=0}) end
            assert(math.abs(poses[2].x)<1e-9 and math.abs(poses[2].z-4)<1e-9)
            local R=15
            poses={{x=0,z=0,t=0},{x=0,z=-6,t=0}}
            for i=1,12000 do
                local t=i*.002
                poses=G.advance(m,poses,{x=R*(1-math.cos(t)),z=R*math.sin(t),t=t})
            end
            local angle=poses[1].t-poses[2].t
            assert(math.abs(angle-math.asin(6/R))<.002)
            local r=math.sqrt((poses[2].x-R)^2+poses[2].z^2)
            assert(math.abs(r-math.sqrt(R*R-36))<.02)
        ''')

    def test_footprint_rejects_island_inside_and_boundary_between_corners(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local field={{x=-50,z=-50},{x=50,z=-50},{x=50,z=50},{x=-50,z=50}}
            local island={{x=2,z=2},{x=3,z=2},{x=3,z=3},{x=2,z=3}}
            local v=fixture({field=field,islands={island}})
            local b={left=5,right=-5,front=5,back=-5}
            assert(not G.bodyFits(b,{x=0,z=0,t=0},G.getBoundary(v)))
            assert(G.bodyFits(b,{x=-20,z=0,t=0},G.getBoundary(v)))
            assert(not G.bodyFits(b,{x=48,z=0,t=0},G.getBoundary(v)))
        ''')

    def test_declared_body_checks_boundary_without_treating_working_width_as_solid(self):
        self.lua.execute('''
            local field={{x=-10,z=-40},{x=10,z=-40},{x=10,z=20},{x=-10,z=20}}
            local v=fixture({internal=true,width=30,field=field})
            local m=assert(HeadlandLoopGeometry.detect(v))
            local boundary=assert(HeadlandLoopGeometry.getBoundary(v))
            local pose={x=0,z=-9.8,t=0}
            assert(not HeadlandLoopGeometry.bodyFits(m.bodies[2],pose,boundary))
            assert(HeadlandLoopGeometry.bodyFits(m.bodies[2].collision,pose,boundary))
        ''')

    def test_real_loop_generation_both_sides_and_configured_speed_allowances(self):
        for side in [-1, 1]:
            for lead in [0.5, 8.0]:
                with self.subTest(side=side, lead=lead):
                    self.lua.globals().SIDE = side
                    self.lua.globals().LEAD = lead
                    self.lua.execute('''
                        local v,c=fixture({side=SIDE})
                        local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,LEAD)
                        assert(m.chainPlanned and m.course, 'no planned course')
                        assert(m.course:isForwardOnly())
                        for i=1,m.course:getNumberOfWaypoints() do
                            assert(not m.course:getUseTightTurnOffset(i))
                            local x,_,z=m.course:getWaypointPosition(i)
                            assert(x==x and z==z)
                        end
                    ''')

    def test_impossible_field_returns_no_unchecked_course(self):
        self.lua.execute('''
            local field={{x=-2,z=-2},{x=2,z=-2},{x=2,z=2},{x=-2,z=2}}
            local v,c=fixture({field=field})
            local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,.5)
            assert(m.chainPlanned and not m.course)
        ''')

    def test_planner_checks_non_shortest_dubins_words(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,field=field})
            local model=assert(HeadlandLoopGeometry.detect(v))
            local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=25.6,steeringLength=9.8}
            local search=HeadlandLoopGeometry.createSearch(maneuver,model,.5)
            while search.phase=='preparing' do assert(not search:step()) end
            local words={}
            local last=-math.huge
            for _,candidate in ipairs(search.candidates) do
                words[candidate.name]=true
                assert(candidate.score>=last)
                last=candidate.score
            end
            local count=0
            for _ in pairs(words) do count=count+1 end
            assert(count==6, 'search omitted a Dubins word')
        ''')

    def test_transient_search_starts_at_configured_radius(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,field=field})
            local model=assert(HeadlandLoopGeometry.detect(v))
            local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=25.6,steeringLength=9.8}
            HeadlandLoopGeometry.minimumRadius=function() return 20 end
            local search=HeadlandLoopGeometry.createSearch(maneuver,model,.5)
            while search.phase=='preparing' do assert(not search:step()) end
            local configured,shortEntry=false,false
            for _,candidate in ipairs(search.candidates) do
                configured=configured or candidate.radius==10
                shortEntry=shortEntry or candidate.entry<1
            end
            assert(configured and shortEntry, 'search discarded transient corner approaches')
        ''')

    def test_internal_pivot_uses_chain_planner_and_detected_width(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,width=30,field=field})
            local model=assert(HeadlandLoopGeometry.detect(v))
            local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=8,steeringLength=9.8}
            local course,reason=HeadlandLoopGeometry.plan(maneuver,model,.5)
            assert(course, tostring(reason))
            assert(string.find(reason,'3 pivots %(1 internal%)'))
            local plannedRadius=tonumber(string.match(reason,'radius ([%d.]+)'))
            assert(plannedRadius>=10 and plannedRadius<50, tostring(reason))
            local m=LoopTurnManeuver(v,c,v.rootNode,10,8,9.8,.5)
            assert(m.chainPlanned and m.course, tostring(reason))
        ''')

    def test_internal_pivot_refuses_an_unchecked_field_boundary(self):
        self.lua.execute('''
            local v,c=fixture({internal=true})
            local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,.5)
            assert(m.chainPlanned and not m.course)
        ''')

    def test_internal_pivot_uses_map_boundary_when_job_cache_is_empty(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,mapField=field})
            assert(v.cpGetFieldPolygon==nil)
            local boundary=assert(HeadlandLoopGeometry.getBoundary(v))
            assert(boundary.source=='map field')
            local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,.5)
            assert(m.chainPlanned and m.course)
        ''')

    def test_width_fallback_rejects_a_field_crossing(self):
        self.lua.execute('''
            local field={{x=-2,z=-2},{x=2,z=-2},{x=2,z=2},{x=-2,z=2}}
            local v,c=fixture({internal=true,field=field})
            local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,.5)
            assert(not m.course)
        ''')

    def test_clearance_rejects_jack_knifed_physical_bodies(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local a={left=5,right=-5,front=5,back=-5}
            local b={left=4,right=-4,front=6,back=-6}
            assert(not G.bodiesOverlap(a,{x=0,z=0,t=0},b,{x=0,z=-12,t=0}))
            assert(G.bodiesOverlap(a,{x=0,z=0,t=0},b,{x=0,z=-5,t=math.pi/2}))
            b.virtual=true
            assert(not G.bodiesOverlap(a,{x=0,z=0,t=0},b,{x=0,z=-5,t=math.pi/2}))
        ''')

    def test_boundary_success_and_world_rotation(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            for _,side in ipairs({-1,1}) do
                local v,c=fixture({side=side,field=field})
                local m=LoopTurnManeuver(v,c,v.rootNode,10,25.6,9.8,.5)
                assert(m.course and m.chainPlanned)
            end
            local G=HeadlandLoopGeometry
            local m={links={{length=6,hitch=-2},{length=8,hitch=-3}}}
            for _,angle in ipairs({-3.1,-1,0,1,3.1}) do
                local poses={{x=0,z=0,t=angle},{x=-8*math.sin(angle),z=-8*math.cos(angle),t=angle},
                    {x=-19*math.sin(angle),z=-19*math.cos(angle),t=angle}}
                for i=1,100 do poses=G.advance(m,poses,{x=i*.1*math.sin(angle),z=i*.1*math.cos(angle),t=angle}) end
                assert(math.abs(poses[3].t-angle)<1e-8)
            end
        ''')

    def test_course_turn_stops_without_installing_a_rejected_course(self):
        self.lua.execute('''
            local field={{x=-2,z=-2},{x=2,z=-2},{x=2,z=2},{x=-2,z=2}}
            for _,internal in ipairs({false,true}) do
                local v,c=fixture({field=field,internal=internal})
                c.isHeadlandCorner=function() return true end
                local stopped=false
                v.stopCurrentAIJob=function() stopped=true end
                AIMessageCpErrorNoPathFound={new=function() return {} end}
                local t=setmetatable({vehicle=v,turnContext=c,workWidth=25.6,turningRadius=10,steeringLength=9.8,
                    settings={loopTurnsOnHeadland={getValue=function() return true end},turnSpeed={getValue=function() return 17 end}},
                    driveStrategy={getLoweringDurationMs=function() return 1500 end},
                    states={TURNING={}},ppc={setCourse=function() error('must not install rejected course') end}},CourseTurn)
                t.debug=function() end
                AITurn.canTurnOnField=function() return true end
                v.getLastSpeed=function() return 0 end
                openIntervalTimer=function() return 1 end
                readIntervalTimerMs=function() return 5 end
                closeIntervalTimer=function() end
                t:startTurn()
                assert(not stopped and t.state==t.states.WAITING_FOR_LOOP)
                t:updateLoopSearch()
                t:updateLoopSearch()
                assert(stopped and not t.turnCourse)
            end
        ''')

    def test_integration_retains_user_speed_and_disables_moving_chain_offset(self):
        self.lua.execute('''
            for _,speed in ipairs({6,17,30}) do
                local v,c=fixture()
                c.isHeadlandCorner=function() return true end
                local t=setmetatable({vehicle=v,turnContext=c,workWidth=25.6,turningRadius=10,steeringLength=9.8,
                    settings={loopTurnsOnHeadland={getValue=function() return true end},turnSpeed={getValue=function() return speed end}},
                    driveStrategy={getLoweringDurationMs=function() return 1500 end}},CourseTurn)
                t.debug=function() end
                t:generateCalculatedTurn()
                assert(t.turnCourse and not t.enableTightTurnOffset)
                assert(t:getForwardSpeed()==speed)
            end
        ''')

    def test_actual_sampled_articulation_rejects_a_tight_two_pivot_loop(self):
        self.lua.execute('''
            local v,c=fixture()
            local model=HeadlandLoopGeometry.detect(v)
            local course=Course.createFromNode(v,v.rootNode,0,0,12.8,1,false)
            local path=PathfinderUtil.findAnalyticPath(PathfinderUtil.dubinsSolver,v.rootNode,0,13.3,c.workStartNode,0,-9.8,10)
            course:append(Course.createFromAnalyticPath(v,path,true))
            local ix=course:getNumberOfWaypoints()
            c:appendEndingTurnCourse(course,9.8)
            local ok,reason=HeadlandLoopGeometry.validate(model,course,nil,ix,c.vehicleAtTurnEndNode,.5)
            assert(not ok and (reason=='articulation' or reason=='implement clearance'), tostring(reason))
        ''')

    def test_optimised_clearance_matches_independent_corner_projection(self):
        self.lua.execute("""
            local function reference(a,pa,b,pb)
                local function corners(body,pose)
                    local front,back=body.front-2,body.back+2
                    if front<=back then front,back=body.front,body.back end
                    local out={}
                    for _,x in ipairs({body.left,body.right}) do
                        for _,z in ipairs({front,back}) do
                            out[#out+1]={x=pose.x+x*math.cos(pose.t)+z*math.sin(pose.t),
                                z=pose.z-x*math.sin(pose.t)+z*math.cos(pose.t)}
                        end
                    end
                    return out
                end
                local ac,bc=corners(a,pa),corners(b,pb)
                for _,t in ipairs({pa.t,pa.t+math.pi/2,pb.t,pb.t+math.pi/2}) do
                    local amin,amax,bmin,bmax=math.huge,-math.huge,math.huge,-math.huge
                    for _,p in ipairs(ac) do local q=p.x*math.cos(t)-p.z*math.sin(t);amin=math.min(amin,q);amax=math.max(amax,q) end
                    for _,p in ipairs(bc) do local q=p.x*math.cos(t)-p.z*math.sin(t);bmin=math.min(bmin,q);bmax=math.max(bmax,q) end
                    if amax<=bmin or bmax<=amin then return false end
                end
                return true
            end
            math.randomseed(312)
            for i=1,2000 do
                local a={left=math.random()*10,right=-math.random()*4,front=math.random()*10,back=-math.random()*10}
                local b={left=math.random()*6,right=-math.random()*5,front=math.random()*9,back=-math.random()*12}
                local pa={x=100,z=-200,t=math.random()*6.28}
                local pb={x=85+math.random()*30,z=-215+math.random()*30,t=math.random()*6.28}
                assert(HeadlandLoopGeometry.bodiesOverlap(a,pa,b,pb)==reference(a,pa,b,pb), 'rectangle SAT changed')
            end
        """)

    def test_checked_row_handover_uses_distance_and_validates_live_cart(self):
        self.lua.execute("""
            local G=HeadlandLoopGeometry
            local field={{x=-100,z=-100},{x=100,z=-100},{x=100,z=150},{x=-100,z=150}}
            local v,c,d,cart=fixture({internal=true,field=field})
            local model=assert(G.detect(v))
            local turn=Course.createFromNode(v,v.rootNode,0,0,60,1,false)
            turn.chainReturn={x=0,z=0,t=0,model=model,boundary=G.getBoundary(v)}
            local row=Course.createFromNode(v,v.rootNode,0,-30,70,.5,false)
            local ix,covered=G.getContinuation(v,row,1,turn)
            assert(ix>10 and covered, 'dense waypoints blocked a valid forward continuation')
            local resumed
            AIDriveStrategyCourse={onTurnEndProgressEvent=1}
            local strategy={fieldWorkCourse=row,raiseControllerEvent=function() end,
                resumeFieldworkAfterTurn=function(_,startIx)
                    local actual,found=row:getNextFwdWaypointIxFromVehiclePosition(startIx,v.rootNode,12.8,10)
                    assert(found and actual==ix, 'merged ten-waypoint search still stopped')
                    resumed=actual
                end}
            local t=setmetatable({vehicle=v,turnContext=c,turnCourse=turn,driveStrategy=strategy,
                ppc={isReversing=function() return false end,restorePreviouslyRegisteredListeners=function() end}},CourseTurn)
            t.getLowerImplementNode=function() return c.workStartNode end
            t:resumeFieldworkAfterTurn(1)
            assert(resumed==ix, 'turn did not supply its checked continuation index')
            cart.rootNode.t=math.rad(12);cart.joint.rootNode.t=math.rad(8)
            assert(not G.isAligned(v,v.rootNode))
            assert(G.canContinueOnCheckedRow(v,row,1,turn), 'safe straight work waited for the trailing cart')
            d.rootNode.t=math.rad(9)
            assert(not G.canContinueOnCheckedRow(v,row,1,turn), 'working drill was not aligned')
            d.rootNode.t=0;cart.rootNode.t=math.rad(80)
            assert(not G.canContinueOnCheckedRow(v,row,1,turn), 'excessive cart articulation was accepted')
            cart.rootNode.t=math.rad(12)
            row.isTurnStartAtIx=function(_,i) return i==ix+5 end
            assert(not G.canContinueOnCheckedRow(v,row,1,turn), 'handover crossed the next corner')
            row.isTurnStartAtIx=function() return false end
            row.waypoints[ix+20].x=80
            assert(not G.canContinueOnCheckedRow(v,row,1,turn), 'unmatched continuation was accepted')
        """)

    def test_saved_return_resolves_late_handover_and_checks_earlier_continuation(self):
        self.lua.execute((SOURCE / 'tools/double-pivot/saxlingham-corner.lua').read_text())
        self.lua.execute("""
            local G=HeadlandLoopGeometry
            local v,c,m=saxlinghamCorner()
            local turn=assert(G.plan({vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=25.6,steeringLength=9.8},m,1.68))
            local row=saxlinghamReturn(v)
            local target=c.workStartNode
            v.rootNode.x=target.x+49*math.sin(target.t)
            v.rootNode.z=target.z+49*math.cos(target.t);v.rootNode.t=target.t
            local _,oldFound=row:getNextFwdWaypointIxFromVehiclePosition(1,v.rootNode,12.8,10)
            assert(not oldFound, 'did not reproduce the live ten-waypoint handover failure')
            local ix,covered=G.getContinuation(v,row,1,turn)
            assert(ix and ix>10 and covered, 'actual headland continuation was not found')
            -- Earlier return: drill aligned, cart still lagging. Reconstruct
            -- measured-link poses and validate the real slightly curved row.
            v.rootNode.x=target.x+30*math.sin(target.t)
            v.rootNode.z=target.z+30*math.cos(target.t)
            local parent={x=v.rootNode.x,z=v.rootNode.z,t=target.t}
            for i,link in ipairs(m.links) do
                local angle=target.t+math.rad(({4,15,12})[i])
                local x=parent.x+link.hitch*math.sin(parent.t)-link.length*math.sin(angle)
                local z=parent.z+link.hitch*math.cos(parent.t)-link.length*math.cos(angle)
                local node=link.positionNode or link.node
                node.x=x;node.z=z;node.t=angle;link.node.t=angle
                parent={x=x,z=z,t=angle}
            end
            assert(not G.isAligned(v,c.vehicleAtTurnEndNode))
            local ok,why=G.canContinueOnCheckedRow(v,row,1,turn)
            assert(ok, 'safe earlier handover still waited for the cart: '..tostring(why))
        """)

    def test_all_runtime_lua_compiles(self):
        check = self.lua.eval('function(code,name) local f,e=load(code,name); assert(f,e) end')
        for file in ROOT.rglob('*.lua'):
            if 'out' in file.relative_to(ROOT).parts or 'test' in file.relative_to(ROOT).parts:
                continue
            check(file.read_text(encoding='utf-8-sig'), file.as_posix())

    def test_saved_saxlingham_corner_passes_chain_checks_and_mirrored_start_variations(self):
        self.lua.execute((SOURCE / 'tools/double-pivot/saxlingham-corner.lua').read_text())
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            for _,case in ipairs({{0,1},{-1,1},{1,1},{0,-1}}) do
                local v,c,m=saxlinghamCorner(case[1],case[2])
                assert(math.abs(math.deg(m.links[1].maxArticulation)-78)<.001)
                assert(math.abs(math.deg(m.links[2].maxArticulation)-40)<.001)
                assert(math.abs(math.deg(m.links[3].maxArticulation)-60)<.001)
                local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                    turningRadius=10,workWidth=25.6,steeringLength=9.8}
                local constructions,init=0,Course.init
                Course.init=function(self,...) constructions=constructions+1;return init(self,...) end
                local course,reason=G.plan(maneuver,m,1.68)
                Course.init=init
                assert(constructions==1, 'built Course metadata for rejected routes')
                assert(course, string.format('start %.1f mirror %d: %s',case[1],case[2],reason))
                assert(course:isForwardOnly() and course.temporary and course.chainReturn)
                local chainLength=0
                for _,link in ipairs(m.links) do chainLength=chainLength+link.length-link.hitch end
                local _,_,reserve=course:getWaypointLocalPosition(c.vehicleAtTurnEndNode,course:getNumberOfWaypoints())
                assert(reserve>=2*chainLength+c.frontMarkerDistance-c.backMarkerDistance-1.01,
                    'trimmed the live settling reserve to the prediction')
                local entry
                for i=1,course:getNumberOfWaypoints() do
                    if TurnManeuver.hasTurnControl(course,i,TurnManeuver.LOWER_IMPLEMENT_AT_TURN_END) then entry=entry or i end
                end
                assert(entry and entry>10)
                local b=G.getBoundary(v)
                -- Finer replay of the produced course: no early
                -- exit when settling is first reached, all remaining points.
                local old=G.step;G.step=.2
                local ok,why=G.validate(m,course,b,entry,c.vehicleAtTurnEndNode,1.68)
                G.step=old
                assert(ok, tostring(why))
                for i=entry,course:getNumberOfWaypoints() do
                    local d=course:getWaypointYRotation(i)-c.vehicleAtTurnEndNode.t
                    assert(math.abs(math.atan2(math.sin(d),math.cos(d)))<.02, 'lowering starts before the straight')
                end
                local firstHeading=course:getWaypointYRotation(10)
                assert(case[2]*(firstHeading-m.root.t)<0, 'loop initially turns outwards')
            end
        ''')

    def test_hitch_limits_use_each_coupling_not_the_cart_internal_joint(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local v,c,d,cart=fixture({internal=true})
            local attachment=v.children[1]
            attachment.lowerRotLimit={0,math.rad(70),0}
            attachment.upperRotLimit={0,math.rad(65),0}
            assert(math.abs(math.deg(G.getHitchLimit(v,attachment,d.joint))-70)<.001)
            local m=assert(G.detect(v))
            assert(math.abs(math.deg(m.links[1].maxArticulation)-70)<.001)
            assert(math.abs(math.deg(m.links[2].maxArticulation)-45)<.001)
            assert(math.abs(math.deg(m.links[3].maxArticulation)-60)<.001)
            attachment.lowerRotLimit={0,0,0};attachment.upperRotLimit={0,0,0}
            assert(not G.detect(v), 'locked hitch became a free pivot')
        ''')

    def test_live_chain_handover_waits_for_cart_but_preserves_lowering_stop(self):
        self.lua.execute('''
            local v,c,d,cart=fixture({internal=true})
            c.vehicleAtTurnEndNode={x=0,z=0,t=0}
            local ready,resumed,stopped=false,false,false
            cart.rootNode.t=math.rad(12)
            v.getLastSpeed=function() return 8 end
            v.stopCurrentAIJob=function() stopped=true end
            AIMessageCpErrorNoPathFound={new=function() return {} end}
            local course=Course.createFromNode(v,v.rootNode,0,0,40,1,false)
            course.chainReturn={x=0,z=0,t=0,lateralTolerance=4}
            local t=setmetatable({vehicle=v,turnContext=c,turnCourse=course,
                workStartHandler={lowerImplementsAsNeeded=function() return 1 end,allLowered=function() return true end},
                driveStrategy={getCanContinueWork=function() return ready end},
                ppc={isReversing=function() return false end},states={ENDING_TURN={}}},CourseTurn)
            t.state=t.states.ENDING_TURN
            t.debug=function() end
            t.getLowerImplementNode=function() return c.workStartNode end
            t.resumeFieldworkAfterTurn=function() resumed=true end
            assert(t:endTurn(16)==false and not resumed, 'seeder drove while still lowering')
            ready=true
            assert(t:endTurn(16)==true and not resumed, 'handed back with unaligned cart')
            t:onWaypointPassed(course:getNumberOfWaypoints(),course)
            assert(stopped and not resumed, 'left the checked return with unaligned cart')
            cart.rootNode.t=0;cart.joint.rootNode.t=math.rad(8)
            assert(t:endTurn(16)==true and not resumed, 'ignored cart drawbar')
            cart.joint.rootNode.t=0
            assert(t:endTurn(16)==true and resumed)
        ''')

    def test_checked_return_lowers_at_existing_line_without_general_lateral_relaxation(self):
        self.lua.execute('''
            local v,c,d=fixture()
            local line={x=0,z=0,t=0}
            WorkWidthUtil.getAIMarkers=function()
                return {x=9.8,z=-.2,t=0},{x=-15.8,z=-.2,t=0},{x=-3,z=-2,t=0}
            end
            AIUtil.hasAIImplementWithSpecialization=function() return true end
            local h=setmetatable({vehicle=v,turnContext=c,
                settings={turnSpeed={getValue=function() return 8 end}},
                driveStrategy={getLoweringDurationMs=function() return 500 end,getImplementLowerEarly=function() return true end},
                logger={debugSparse=function() end}},WorkStartHandler)
            assert(not h:shouldLowerThisImplement(d,line,false))
            c.chainReturnLateralTolerance=4
            local lower,dz=h:shouldLowerThisImplement(d,line,false)
            assert(lower and math.abs(dz+.2)<.001, 'shifted the work-start plane')
            d.rootNode.t=math.rad(12)
            assert(not h:shouldLowerThisImplement(d,line,false), 'lowered the crooked drill')
            d.rootNode.t=math.rad(4)
            assert(h:shouldLowerThisImplement(d,line,false), 'blocked the aligned drill')
            d.rootNode.t=0
            c.chainReturnLateralTolerance=nil
            assert(not h:shouldLowerThisImplement(d,line,false))
            local pose={x=0,z=0,t=0}
            v.rootNode={x=0,z=-3,t=0}
            assert(not HeadlandLoopGeometry.isOnReturn(v,pose), 'PPC lookahead lowered on the curve')
            v.rootNode.z=0;v.rootNode.t=math.rad(20)
            assert(not HeadlandLoopGeometry.isOnReturn(v,pose))
            v.rootNode.t=0
            assert(HeadlandLoopGeometry.isOnReturn(v,pose))
        ''')

    def test_incremental_search_matches_offline_result_with_bounded_validation(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,field=field})
            local m=assert(G.detect(v))
            local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=25.6,steeringLength=9.8}
            local expected=assert(G.plan(maneuver,m,.5))
            local search=G.createSearch(maneuver,m,.5)
            local advances,updates=0,0
            local advance=G.advance
            G.advance=function(...) advances=advances+1; return advance(...) end
            repeat
                advances=0
                search:step()
                assert(advances<=32, 'validation blocked instead of yielding')
                updates=updates+1
                assert(updates<20000, 'search did not terminate')
            until search.done
            G.advance=advance
            assert(updates>1 and search.course)
            assert(math.abs(search.course:getLength()-expected:getLength())<.001)
        ''')

    def test_runtime_waits_for_braking_and_installs_only_completed_search(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,field=field})
            c.isHeadlandCorner=function() return true end
            local speed,installed,closed=12,0,0
            v.getLastSpeed=function() return speed end
            v.stopCurrentAIJob=function() error('valid loop unexpectedly rejected') end
            openIntervalTimer=function() return 1 end
            readIntervalTimerMs=function() return 5 end
            closeIntervalTimer=function() closed=closed+1 end
            AITurn.canTurnOnField=function() return true end
            local t=setmetatable({vehicle=v,turnContext=c,workWidth=25.6,turningRadius=10,steeringLength=9.8,
                settings={loopTurnsOnHeadland={getValue=function() return true end},turnSpeed={getValue=function() return 17 end}},
                driveStrategy={getLoweringDurationMs=function() return 1500 end},states={TURNING={}},
                ppc={setCourse=function(_,course) assert(course); installed=installed+1 end,initialize=function() end}},CourseTurn)
            t.debug=function() end
            t:startTurn()
            local _,_,_,limit=t:getDriveData(16)
            assert(limit==0 and not t.loopManeuver and installed==0)
            t.startRecoveryTurn=function() error('waiting triggered blocked recovery') end
            t:onBlocked()
            speed=0
            t:getDriveData(16)
            assert(t.loopManeuver.search and installed==0)
            local updates=0
            while t.state==t.states.WAITING_FOR_LOOP do
                local _,_,_,limit=t:getDriveData(16)
                assert(limit==0)
                updates=updates+1
                assert(updates<20000)
            end
            assert(t.state==t.states.TURNING and installed==1 and closed==updates)
            assert(t:getForwardSpeed()==17 and not t.enableTightTurnOffset)
        ''')

    def test_unfolded_work_area_boundary_and_narrow_chassis_are_both_checked(self):
        self.lua.execute('''
            local G=HeadlandLoopGeometry
            local field={{x=-10,z=-50},{x=10,z=-50},{x=10,z=50},{x=-10,z=50}}
            local v,c,drill=fixture({field=field})
            local m=G.detect(v)
            local b=G.getBoundary(v)
            local pose={x=0,z=-9.8,t=0}
            assert(G.bodyFits(m.bodies[2].collision,pose,b))
            assert(not G.bodyFits(m.bodies[2],pose,b), 'wide working bar escaped boundary validation')
        ''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
