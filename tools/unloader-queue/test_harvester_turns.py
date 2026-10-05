"""Regression coverage for the non-stock header-width corridor veto."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE


class HarvesterTurnTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT = ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute('''
            g_currentMission.time=0
            polygon={{x=0,z=-100},{x=100,z=-100},{x=100,z=100},{x=0,z=100}}
            vehicle={spec_combine={},size={width=3.5},cpGetFieldPolygon=function() return polygon end,
                stopCurrentAIJob=function() error('unexpected stopped harvester') end}
            route=Course(vehicle,{{x=4,z=-20},{x=4,z=-10},{x=4,z=0}},true)
            context={straightEntryDistance=10,isHeadlandCorner=function() return false end}
            turn=setmetatable({vehicle=vehicle,workWidth=15.2,turnCourse=route,turnContext=context,
                debug=function() end,generateCalculatedTurn=function() error('unexpected route rewrite') end},CourseTurn)
        ''')

    def test_existing_harvester_edge_route_has_no_extra_width_veto(self):
        self.lua.execute('''
            assert(not FieldworkBoundary.containsCourse(FieldworkBoundary.forVehicle(vehicle,15.2),route))
            assert(turn:fitCalculatedTurnToBoundary())
            assert(turn.turnCourse==route and context.straightEntryDistance==10)
        ''')

    def test_other_implements_keep_explicit_corridor_validation(self):
        self.lua.execute('''
            vehicle.spec_combine=nil; context.straightEntryDistance=nil
            assert(not turn:fitCalculatedTurnToBoundary())
        ''')

    def test_direct_queue_boundary_queries_remain_strict_for_harvesters(self):
        self.lua.execute('''
            local queueBoundary=FieldworkBoundary.forVehicle(vehicle,0)
            assert(queueBoundary and not FieldworkBoundary.contains(queueBoundary,1,0))
            assert(not FieldworkBoundary.contains(queueBoundary,-10,0))
            vehicle.cpGetIslandPolygons=function() return {
                {{x=3,z=-2},{x=6,z=-2},{x=6,z=2},{x=3,z=2}}} end
            assert(not FieldworkBoundary.contains(FieldworkBoundary.forVehicle(vehicle,0),4,0))
        ''')

    def test_native_turn_search_inputs_remain_intact(self):
        self.lua.execute('''
            for _,onField in ipairs({false,true}) do
                local args
                PathfinderUtil.findPathForTurn=function(...) args={...}; return {},{done=false} end
                turn.turnContext.getTurnEndNodeAndOffsets=function() return 'target',-4 end
                turn.turnContext.getBoundaryId=function() return 'field-edge' end
                turn.driveStrategy={getFrontAndBackMarkers=function() return 3,-6 end,
                    getAllowReversePathfinding=function() return true end,
                    getWorkWidth=function() return 15.2 end,isTurnOnFieldActive=function() return onField end,
                    setPathfindingDoneCallback=function() end}
                turn.states={WAITING_FOR_PATHFINDER={}}; turn.turningRadius=9
                turn.fieldWorkCourse=route
                turn:generatePathfinderTurn(true)
                assert(args[1]==vehicle and args[3]=='target' and args[4]==-4 and args[5]==9)
                assert(args[6] and args[7]==route and args[8]==15.2 and args[9]==-6)
                assert(args[10]==onField and args[11]=='field-edge' and args[12]==nil)
                vehicle.spec_combine=nil
                turn:generatePathfinderTurn(true)
                assert(args[12] and args[12].margin==7.6)
                vehicle.spec_combine={}
            end
        ''')

    def test_successful_pathfinder_turn_is_installed_after_native_ending(self):
        self.lua.execute('''
            AIUtil.getDirectionNodeToReverserNodeOffset=function() return 0 end
            turn.turnContext.appendPathfinderEndingTurnCourse=function(_,course)
                -- Engine-independent stand-in for the appended ending section.
                assert(course:getNumberOfWaypoints()==3); return 2
            end
            local installed,initialised
            turn.ppc={setCourse=function(_,course) installed=course end,
                initialize=function(_,ix) initialised=ix end}
            turn.states={TURNING={}}
            turn:onPathfindingDone({{x=4,y=20,t=0},{x=4,y=10,t=0},{x=4,y=0,t=0}})
            assert(installed==turn.turnCourse and initialised==1 and turn.state==turn.states.TURNING)
        ''')

    def test_connecting_fallback_is_not_stopped_by_header_width(self):
        self.lua.execute((SOURCE/'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('''
            for _,harvester in ipairs({true,false}) do
                local f=preparationFixture(20,false,false)
                f.vehicle.spec_combine=harvester and {} or nil
                f.vehicle.cpGetFieldPolygon=function() return polygon end
                f.vehicle.size={width=3.5}
                AIUtil.getSteeringParameters=function() return 9,0 end
                AIUtil.getTurningRadius=function() return 9 end
                local c=setmetatable(f.turn.turnContext,RowStartOrFinishContext)
                c.turnStartWpIx=c.turnEndWpIx; c.workWidth=15.2
                c.workStartNode={x=4,z=0,t=0}; c.vehicleAtTurnEndNode={x=4,z=0,t=0}
                c.frontMarkerDistance=4; c.backMarkerDistance=-6
                local approach=Course(f.vehicle,{{x=4,z=-43},{x=4,z=-42},{x=4,z=-41}},true)
                local starter=StartRowOnly(f.vehicle,f.strategy,f.turn.ppc,c,approach)
                assert(starter.entryOutsideBoundary==not harvester)
                if harvester then
                    f.vehicle.stopCurrentAIJob=function() error('fallback stopped') end
                    approach:setCurrentWaypointIx(1)
                    starter:getDriveData()
                    assert(starter.state==starter.states.DRIVING_TO_ROW)
                end
            end
        ''')


if __name__ == '__main__':
    unittest.main()
