"""Exercise approach lookahead with real Course/PPC methods at a planar engine boundary."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else SOURCE


class ApproachLookaheadTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute((SOURCE / 'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute('''
            AIDriveStrategyCourse = {}; VariableWorkWidth={}; AIDriveStrategyFieldCourse={}
            Utils={overwrittenFunction=function(original) return original end}
        ''')
        for name in ['AIDriveStrategyFieldWorkCourse', 'AIDriveStrategyCombineCourse']:
            self.lua.execute((ROOT / f'scripts/ai/strategies/{name}.lua').read_text())
        self.lua.execute((ROOT / 'scripts/ai/PurePursuitController.lua').read_text())
        self.lua.execute('''
            function fixture(angles, reverseIx)
                local points={}; local x,z=0,0
                for i,angle in ipairs(angles) do
                    points[i]={x=x,z=z,rev=i==reverseIx}
                    x=x+2*math.sin(math.rad(angle)); z=z+2*math.cos(math.rad(angle))
                end
                local course=Course({},points,true)
                local ppc=setmetatable({normalLookAheadDistance=6,shortLookaheadDistance=3,
                    baseLookAheadDistance=3,temporaryLookAheadDistance={get=function() end}},PurePursuitController)
                local states={DRIVING_TO_WORK_START_WAYPOINT={},WORKING={},TURNING={}}
                local driver=setmetatable({course=course,ppc=ppc,states=states,
                    state=states.DRIVING_TO_WORK_START_WAYPOINT,
                    calculateTightTurnOffset=function(self) self.parentCalls=(self.parentCalls or 0)+1 end},
                    AIDriveStrategyCombineCourse)
                return driver
            end
            angles={}; for i=1,60 do angles[i]=0 end
            c=fixture(angles)
        ''')

    def test_forward_approach_uses_eight_metres_without_rewriting_course(self):
        self.lua.execute('''
            local course=c.course; local before={}
            for i,wp in ipairs(course.waypoints) do before[i]={wp.x,wp.z,wp.rev} end
            c:onWaypointChange(1,course)
            assert(c.parentCalls==1 and c.ppc.baseLookAheadDistance==8 and c.course==course)
            for i,wp in ipairs(course.waypoints) do
                assert(wp.x==before[i][1] and wp.z==before[i][2] and wp.rev==before[i][3])
            end
            c.ppc:setCurrentLookaheadDistance(0)
            assert(c.ppc:getLookaheadDistance()==8)
        ''')

    def test_gentle_curve_and_angle_wrap_use_long_lookahead(self):
        self.lua.execute('''
            for _,start in ipairs({0,179,-179}) do
                for i=1,60 do angles[i]=start+i end
                c=fixture(angles); c:onWaypointChange(1,c.course)
                assert(c.ppc.baseLookAheadDistance==8)
            end
        ''')

    def test_sharp_bend_reverts_before_the_corner(self):
        self.lua.execute('''
            c:onWaypointChange(1,c.course)
            for i=6,60 do angles[i]=90 end
            local bent=fixture(angles); c.course=bent.course
            c:onWaypointChange(1,c.course)
            assert(c.ppc.baseLookAheadDistance==3)
        ''')

    def test_tight_smooth_curve_uses_short_lookahead(self):
        self.lua.execute('''
            for i=1,60 do angles[i]=i*5 end
            c=fixture(angles); c:onWaypointChange(1,c.course)
            assert(c.ppc.baseLookAheadDistance==3)
        ''')

    def test_reverse_and_upcoming_direction_change_use_short_lookahead(self):
        self.lua.execute('''
            for _,reverseIx in ipairs({1,6}) do
                c=fixture(angles,reverseIx); c.ppc:setLookaheadDistance(8)
                c:onWaypointChange(1,c.course)
                assert(c.ppc.baseLookAheadDistance==3)
            end
        ''')

    def test_final_entry_reverts_to_short_lookahead(self):
        self.lua.execute('''
            c:onWaypointChange(1,c.course)
            c:onWaypointChange(55,c.course)
            assert(c.ppc.baseLookAheadDistance==3)
            c:onWaypointChange(60,c.course)
            assert(c.ppc.baseLookAheadDistance==3)
        ''')

    def test_other_states_and_stale_course_do_not_override_native_settings(self):
        self.lua.execute('''
            -- PREPARING, TURNING, unloading and other non-approach states.
            for _,state in ipairs({{},c.states.TURNING,c.states.WORKING}) do
                c.state=state; c.ppc:setLookaheadDistance(4)
                c:onWaypointChange(1,c.course)
                assert(c.ppc.baseLookAheadDistance==4)
            end
            c.state=c.states.DRIVING_TO_WORK_START_WAYPOINT
            c:onWaypointChange(1,fixture(angles).course)
            assert(c.ppc.baseLookAheadDistance==4)
        ''')

    def test_temporary_short_override_and_normal_reset_remain_effective(self):
        self.lua.execute('''
            c:onWaypointChange(1,c.course)
            c.ppc.temporaryLookAheadDistance.get=function() return 3 end
            c.ppc:setCurrentLookaheadDistance(0)
            assert(c.ppc:getLookaheadDistance()==3)
            c.ppc.temporaryLookAheadDistance.get=function() end
            c.ppc:setNormalLookaheadDistance()
            assert(c.ppc.baseLookAheadDistance==6 and c.ppc.shortLookaheadDistance==3)
        ''')

    def test_other_fieldwork_implements_keep_native_approach_lookahead(self):
        self.lua.execute('''
            setmetatable(c,AIDriveStrategyFieldWorkCourse)
            c:onWaypointChange(1,c.course)
            assert(c.parentCalls==1 and c.ppc.baseLookAheadDistance==3)
        ''')


if __name__ == '__main__':
    unittest.main()
