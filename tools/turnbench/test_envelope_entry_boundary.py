"""Initial CP approach placement and transport/deployment phase regressions.

The recorded outer headland centreline is an INSET proxy, not the detected
field boundary. It deliberately leaves the outer half-width unavailable.
"""
import json
import unittest
from pathlib import Path
import test_envelope_initial_entry
import test_ingame_envelope

ROOT=Path(__file__).resolve().parents[2]


class BoundaryEntryTests(unittest.TestCase):
    def setUp(self):
        test_envelope_initial_entry.InitialEntryTests.setUp(self)

    def test_saved_short_pike_uses_more_headland_and_respects_full_width(self):
        points=json.loads((Path(__file__).parent/'fixtures/t7-first-pike-outer-headland.json').read_text())
        self.lua.globals().field=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local f,p=initialFixture()
local s=f.strategy;s.frontMarkerDistance=-3.33;s.backMarkerDistance=-17.4;s.workWidth=5.6
f.vehicle.cpGetFieldPolygon=function() return field end
local c={getWaypointPosition=function() return -158.259,0,-118.820 end,
    getWaypointYRotation=function() return 0 end,getNumberOfHeadlands=function() return 9 end}
local offset,fits=EnvelopeTurnGeometry.outerEntryOffset(s,c,1,-11.27)
assert(fits and offset < -24 and offset > -26,'must use the available outer headland')
-- Widening the tool must bring its target inward on this converging corner.
s.workWidth=12
local wide=EnvelopeTurnGeometry.outerEntryOffset(s,c,1,-11.27)
assert(wide>offset,'wide tool target ignored the angled boundary')
''')

    def test_density_gap_cannot_be_skipped_to_reach_more_distant_field(self):
        self.lua.execute('''
local f=initialFixture();local s=f.strategy
s.frontMarkerDistance=2;s.backMarkerDistance=-5;s.workWidth=4
f.vehicle.cpGetFieldPolygon=function() return nil end
CpFieldUtil.isOnField=function(_,z) return z > -25 or z < -30 end
local c={getWaypointPosition=function() return 0,0,0 end,
    getWaypointYRotation=function() return 0 end,getNumberOfHeadlands=function() return 9 end}
local offset,fits=EnvelopeTurnGeometry.outerEntryOffset(s,c,1,-8)
assert(fits and offset>-16 and offset < -15)
''')

    def test_indexed_polygon_matches_original_with_concavity_and_reserve(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local polygon={{x=0,z=0},{x=10,z=0},{x=10,z=10},{x=6,z=10},
    {x=6,z=4},{x=4,z=4},{x=4,z=10},{x=0,z=10}}
for _,reserve in ipairs({0,.5,1}) do
    local inside=E.polygonChecker(polygon,reserve,true)
    local outside=E.polygonChecker(polygon,reserve,false)
    for x=-2,12,.25 do for z=-2,12,.25 do
        local point={x=x,z=z}
        assert(inside(point)==E.inside(point,polygon,reserve))
        assert(outside(point)==E.outside(point,polygon,reserve))
    end end
end
''')

    def test_cp_transport_handover_waits_for_straight_not_arc(self):
        source=(ROOT/'scripts/ai/strategies/AIDriveStrategyDriveToFieldWorkStart.lua').read_text()
        start=source.index('function AIDriveStrategyDriveToFieldWorkStart:onWaypointChange(')
        end=source.index('\nend',start)+4
        self.lua.execute('AIDriveStrategyDriveToFieldWorkStart={}\n'+source[start:end])
        self.lua.execute('''
local f=initialFixture();local s=f.strategy;local handed=0
s.envelopeEntry=true;s.envelopeEntryHeading=0;s.states.WORK_START_REACHED={}
s.emergencyBrake={set=function() end};s.debug=function() end
s.job={setStartFieldWorkCourse=function() handed=handed+1 end,setStartPosition=function() end}
s.setCurrentTaskFinished=function() end
local course={isCloseToLastWaypoint=function(_,distance) assert(distance==1);return true end,
    getNumberOfWaypoints=function() return 3 end,getWaypointYRotation=function() return math.rad(10) end}
local change=AIDriveStrategyDriveToFieldWorkStart.onWaypointChange
change(s,1,course);assert(handed==0,'prepared implements on remaining arc')
course.getWaypointYRotation=function() return 0 end
f.vehicle:getAIDirectionNode().t=math.rad(10)
change(s,1,course);assert(handed==0,'prepared while tractor still turning')
f.vehicle:getAIDirectionNode().t=0
change(s,1,course);assert(handed==1)
''')

    def test_straight_prepared_plough_is_not_recentred(self):
        test_ingame_envelope.InGameEnvelopeTests.load_stock_plough_fixture(self)
        self.lua.execute('''
local f=initialFixture();local c=addStockPloughFixture(f)
f.object.animation=f.context:shouldPlowBeOnTheLeft() and 1 or 0
f.strategy.raiseControllerEvent=function() error('unnecessary centring/turnover on straight') end
assert(f.starter:prepareInitialPosition())
assert(not f.starter.initialNeedsWorkingGeometry and f.object.sideCommands==0)
''')

    def test_transport_centres_once_and_never_rotates_a_folded_plough(self):
        source=(ROOT/'scripts/ai/strategies/AIDriveStrategyDriveToFieldWorkStart.lua').read_text()
        start=source.index('function AIDriveStrategyDriveToFieldWorkStart:prepareEnvelopeTransport(')
        end=source.index('\nend',start)+4
        self.lua.execute('AIDriveStrategyDriveToFieldWorkStart={}\n'+source[start:end])
        self.lua.execute('''
local count,playing,allowed=0,false,false
local object={spec_plow={rotationPart={turnAnimation='turn'}},
    getIsAnimationPlaying=function() return playing end,
    getIsPlowRotationAllowed=function() return allowed end}
PlowCenterTurnEvent={sendEvent=function(o) assert(o==object);count=count+1;playing=true end}
local s={envelopeEntry=true,vehicle={getChildVehicles=function() return {object} end}}
local prepare=AIDriveStrategyDriveToFieldWorkStart.prepareEnvelopeTransport
assert(prepare(s) and count==0,'rotated a transport-folded plough')
s.envelopeCentredPloughs=nil;allowed=true
assert(not prepare(s) and count==1)
for i=1,180 do assert(not prepare(s) and count==1) end
playing=false
assert(prepare(s) and count==1,'repeated centring after animation')
s.envelopeCentredPloughs=nil
s.settings={foldImplementAtEnd={getValue=function() return true end}}
s.vehicle.getIsAIReadyToDrive=function() return true end
assert(prepare(s) and count==1,'overrode completed GIANTS transport preparation')
s.envelopeCentredPloughs=nil;playing=true
assert(not prepare(s),'bypassed a physical transport animation')
''')

    def test_all_cp_turnover_commands_obey_the_envelope_phase(self):
        test_ingame_envelope.InGameEnvelopeTests.load_stock_plough_fixture(self)
        self.lua.execute('''
local f=initialFixture();local c=addStockPloughFixture(f)
c.driveStrategy=f.strategy
f.strategy.state=f.strategy.states.TURNING
f.strategy.aiTurn={envelopeAlignment=true,canDeployPlough=function() return false end}
c:rotate(false);c:onTurnEndProgress(f.context.workStartNode,false,true,false)
c:onLowering()
assert(f.object.sideCommands==0,'a generic CP event bypassed the arc gate')
f.strategy.aiTurn.canDeployPlough=function() return true end
c:onTurnEndProgress(f.context.workStartNode,false,true,false)
assert(f.object.sideCommands==1)
''')

    def test_elapsed_time_does_not_reject_an_unfinished_search(self):
        self.lua.execute("""
local f=initialFixture();f.starter:getDriveData(16)
local g=assert(f.starter.guard)
g.geometry={}
local updates=0;g.planner={update=function() updates=updates+1 end}
for _,time in ipairs({1500,3000,10000}) do
    g_currentMission.time=time;g:updatePlanner()
    assert(updates>0 and not f.vehicle.stopped and f.object.lowerCount==0)
end
""")

    def test_exhausted_search_stops_without_lowering(self):
        self.lua.execute("""
local f=initialFixture();f.starter:getDriveData(16)
local g=assert(f.starter.guard)
f.starter.recoveryAttempted=true
g.geometry={}
g.planner={update=function() return {ok=false,reason='all candidates exhausted',attempts=96} end}
g_currentMission.time=10000;g:updatePlanner()
assert(f.vehicle.stopped and f.object.lowerCount==0)
""")

    def test_search_error_stops_without_driving_unchecked_path(self):
        self.lua.execute("""
local f=initialFixture();f.starter:getDriveData(16)
local g=assert(f.starter.guard)
f.starter.recoveryAttempted=true
g.geometry={};g.planner={update=function() error('invalid search data') end}
g:updatePlanner()
assert(f.vehicle.stopped and f.object.lowerCount==0)
""")


if __name__=='__main__': unittest.main()
