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

    def test_short_route_is_considered_before_broad_search_exhausts(self):
        self.lua.execute("""
local E=EnvelopeTurnPlanner
local p=envelopeFixture(6,11,2,4,16,35,1,55)
p.deploymentLead=20
local calls=0
E.newDirectSearch=function()
    return {getProgress=function() return calls end,update=function()
        calls=calls+1
        return {ok=true,attempts=1,path={{x=0,z=0},{x=0,z=1}}}
    end}
end
local search=E.newSearch(p)
local result=search:update(1)
assert(calls==1 and result and result.ok,
    'a ready short route must not wait for the broad catalogue to exhaust')
""")

    def test_ground_state_does_not_veto_contained_geometry(self):
        self.lua.execute("""
local f=makeEnvelopeLiveFixture(envelopeFixture(6,11,2,4,16,0,1,55))
CpFieldUtil.isOnField=function(x,z) return x<10 end
local p=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(p.contains(20,0) and not p.contains(201,0))
assert(not p.boundaryFailures['field ground data'])
assert(p.boundaryFailures['polygon clearance'].x==201)
assert(#p.fieldPolygon==4 and #p.bounds==2)
assert(not p.bounds[1].towed and p.bounds[2].towed)
""")

    def test_loaded_course_detects_boundary_before_raise_and_resumes_preparation(self):
        self.lua.execute("""
local p=envelopeFixture(6,11,2,4,16,0,1,55)
local f=makeEnvelopeLiveFixture(p);local turn=f.turn
local original=f.vehicle.cpGetFieldPolygon
local polygon=nil;local running=false;local requests=0;local searches=0
f.vehicle.cpGetFieldPolygon=function() return polygon end
f.vehicle.cpIsFieldBoundaryDetectionRunning=function() return running end
f.vehicle.cpDetectFieldBoundary=function() requests=requests+1;running=true end
EnvelopeTurnPlanner.newSearch=function()
    searches=searches+1
    return {update=function() return {ok=false,attempts=1} end}
end
turn:updatePreparation()
assert(requests==1 and not turn.preparationDone and searches==0)
turn:updatePreparation()
assert(requests==1 and not turn.preparationDone)
polygon=original();running=false
turn:updatePreparation()
assert(searches==1 and turn.preparationDone)
assert(f.strategy.raised==0 and f.object.lowerCount==0 and not f.vehicle.stopped)
""")

    def test_ground_state_never_bypasses_an_island(self):
        self.lua.execute("""
local f=makeEnvelopeLiveFixture(envelopeFixture(6,11,2,4,16,0,1,55))
f.vehicle.cpGetIslandPolygons=function()
 return {{{x=10,z=-5},{x=20,z=-5},{x=20,z=5},{x=10,z=5}}}
end
CpFieldUtil.isOnField=function() return true end
local p=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(not p.contains(15,0) and p.contains(25,0))
assert(p.boundaryFailures['island clearance'])
""")

    def test_elapsed_time_does_not_reject_an_unfinished_search(self):
        self.lua.execute("""
local f=makeEnvelopeLiveFixture(envelopeFixture(6,9,2,11,12,0,1,54))
local g=f.turn
g.geometry={}
local updates=0;g.planner={update=function() updates=updates+1 end}
for _,time in ipairs({1500,3000,10000}) do
    g_currentMission.time=time;g:updatePlanner()
    assert(updates>0 and not f.vehicle.stopped and f.object.lowerCount==0)
end
""")

    def test_exhausted_search_stops_without_lowering(self):
        self.lua.execute("""
local f=makeEnvelopeLiveFixture(envelopeFixture(6,9,2,11,12,0,1,54))
local g=f.turn
g.geometry={}
g.planner={update=function() return {ok=false,reason='all candidates exhausted',attempts=96} end}
g_currentMission.time=10000;g:updatePlanner()
assert(f.vehicle.stopped and f.object.lowerCount==0)
""")

    def test_search_error_stops_without_driving_unchecked_path(self):
        self.lua.execute("""
local f=makeEnvelopeLiveFixture(envelopeFixture(6,9,2,11,12,0,1,54))
local g=f.turn
g.geometry={};g.planner={update=function() error('invalid search data') end}
g:updatePlanner()
assert(f.vehicle.stopped and f.object.lowerCount==0)
""")
