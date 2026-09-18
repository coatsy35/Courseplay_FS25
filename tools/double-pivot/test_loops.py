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
            assert(math.abs(m.links[2].maxArticulation-math.pi/3)<1e-6)
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
            local validate,rootFits=HeadlandLoopGeometry.validate,HeadlandLoopGeometry.rootCourseFits
            local calls=0
            HeadlandLoopGeometry.rootCourseFits=function() return true end
            HeadlandLoopGeometry.validate=function()
                calls=calls+1
                return calls==2, calls==2 and math.rad(10) or 'synthetic rejection'
            end
            local course,reason=HeadlandLoopGeometry.plan(maneuver,model,.5)
            HeadlandLoopGeometry.validate,HeadlandLoopGeometry.rootCourseFits=validate,rootFits
            assert(course and calls>1, 'planner did not try another Dubins word')
            assert(string.find(reason,'Dubins 3'), tostring(reason))
        ''')

    def test_transient_search_starts_at_configured_radius(self):
        self.lua.execute('''
            local field={{x=-200,z=-200},{x=200,z=-200},{x=200,z=200},{x=-200,z=200}}
            local v,c=fixture({internal=true,field=field})
            local model=assert(HeadlandLoopGeometry.detect(v))
            local maneuver={vehicle=v,vehicleDirectionNode=v.rootNode,turnContext=c,
                turningRadius=10,workWidth=25.6,steeringLength=9.8}
            local minimum,validate,rootFits=HeadlandLoopGeometry.minimumRadius,
                HeadlandLoopGeometry.validate,HeadlandLoopGeometry.rootCourseFits
            HeadlandLoopGeometry.minimumRadius=function() return 20 end
            HeadlandLoopGeometry.rootCourseFits=function() return true end
            HeadlandLoopGeometry.validate=function() return true,math.rad(10) end
            local course,reason=HeadlandLoopGeometry.plan(maneuver,model,.5)
            HeadlandLoopGeometry.minimumRadius,HeadlandLoopGeometry.validate,
                HeadlandLoopGeometry.rootCourseFits=minimum,validate,rootFits
            assert(course and string.find(reason,'radius 10.0 m'), tostring(reason))
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
            assert(plannedRadius>15.5 and plannedRadius<50, tostring(reason))
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
                t:startTurn()
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

    def test_all_runtime_lua_compiles(self):
        check = self.lua.eval('function(code,name) local f,e=load(code,name); assert(f,e) end')
        for file in ROOT.rglob('*.lua'):
            if 'out' in file.relative_to(ROOT).parts or 'test' in file.relative_to(ROOT).parts:
                continue
            check(file.read_text(encoding='utf-8-sig'), file.as_posix())


if __name__ == '__main__':
    unittest.main(verbosity=2)
