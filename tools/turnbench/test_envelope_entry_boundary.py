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
