"""Run the shipped Lua planner through CP's real Dubins solver, without GIANTS."""
import math
import unittest
from pathlib import Path
from engine import Bridge, Scenario


class InGameEnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = Bridge(Scenario())
        self.lua = self.bridge.lua
        self.lua.execute("""
g_updateLoopIndex=1
function getName() return 'test node' end
require('PurePursuitController')
require('EnvelopeTurnPlanner')
require('EnvelopeTurnGeometry')
require('EnvelopeCourseTurn')
""")
        self.lua.execute('''
function envelopeFixture(width,length,hitch,front,back,angle,rows,headland)
    local E=EnvelopeTurnPlanner
    local target=width*rows
    local slope=math.tan(math.rad(angle))
    local p={radius=9,width=width,headland=headland,lookahead=3,loweringLead=0.5,
        start={x=0,z=back+2.4,t=0,phi=0},goal={x=target,z=slope*target,t=math.pi},
        hitchX=0,hitchZ=-hitch,length=length>0 and length or nil,
        front=-front,slope=slope,workCentreX=0,maxArticulation=math.rad(85),work={},footprint={}}
    for _,rear in ipairs({false,true}) do
        for _,side in ipairs({-1,1}) do
            local m={x=side*width/2,z=(length>0 and hitch or 0)-(rear and back or front),
                towed=length>0,rear=rear}
            p.work[#p.work+1]=m
            p.footprint[#p.footprint+1]=m
        end
    end
    for _,x in ipairs({-1.9,1.9}) do
        for _,z in ipairs({-2,4}) do p.footprint[#p.footprint+1]={x=x,z=z} end
    end
    p.contains=function(x,z) return z-slope*x <= headland*math.sqrt(1+slope*slope)-0.5 and
        x>=-200 and x<=200 and z>=-450 end
    p.dubins=function(start,goal,radius)
        local path=PathfinderUtil.findAnalyticPathFromStartToGoal(PathfinderUtil.dubinsSolver,
            State3D(start.x,-start.z,CpMathUtil.angleFromGame(start.t)),
            State3D(goal.x,-goal.z,CpMathUtil.angleFromGame(goal.t)),radius)
        if not path then return nil end
        local points={}
        for _,w in ipairs(path) do points[#points+1]={x=w.x,z=-w.y} end
        return points
    end
    p.newTracker=function(path) return EnvelopeTurnGeometry.tracker(p,path) end
    return p
end
''')
        self.lua.execute(Path(__file__).with_name('ingame-envelope-fixture.lua').read_text())

    def test_pw_straight_pike_and_large_headland(self):
        for angle, headland in [(0,50.4),(25,50.4),(0,100.8)]:
            with self.subTest(angle=angle, headland=headland):
                p = self.lua.globals().envelopeFixture(5.6,11.1,1.9,4.6,18.3,angle,1,headland)
                r = self.lua.globals().EnvelopeTurnPlanner.plan(p)
                self.assertTrue(r['ok'], (r['reason'],r['attempts']))
                self.assertLessEqual(r['entryError'], .1)
                self.assertLess(r['maxArticulation'], math.radians(85))
                print('PW',angle,headland,r['attempts'],r['bias'],r['entryError'])

    def test_drills_short_to_long(self):
        for width in (6,12):
            for angle in (10,25,45):
                with self.subTest(width=width,angle=angle):
                    p=self.lua.globals().envelopeFixture(width,9,2,11,12,angle,7,72 if width==12 else 54)
                    r=self.lua.globals().EnvelopeTurnPlanner.plan(p)
                    self.assertTrue(r['ok'],(r['reason'],r['attempts']))

    def test_boundary_rejects_insufficient_room(self):
        p=self.lua.globals().envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,15)
        r=self.lua.globals().EnvelopeTurnPlanner.plan(p)
        self.assertFalse(r['ok'])

    def test_geometry_reads_coupling_markers_and_joint_limits(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
local f=makeEnvelopeLiveFixture(p)
local q,reason=EnvelopeTurnGeometry.capture(f.turn)
assert(q,reason)
assert(math.abs(q.length-11.1)<1e-6)
assert(math.abs(q.hitchZ+1.9)<1e-6)
assert(math.abs(q.front+4.6)<1e-6)
assert(#q.footprint>50)
f.vehicle.spec_attacherJoints.attacherJoints[1].upperRotLimit[2]=math.rad(50)
q=EnvelopeTurnGeometry.capture(f.turn)
assert(math.abs(q.maxArticulation-math.rad(50))<1e-6)
f.vehicle.cpGetFieldPolygon=function() return nil end
q,reason=EnvelopeTurnGeometry.capture(f.turn)
assert(not q and reason:find('field polygon'))
''')

    def test_live_lower_gate_waits_and_does_not_lower_displaced_tool(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
local f=makeEnvelopeLiveFixture(p)
local q=assert(EnvelopeTurnGeometry.capture(f.turn))
f.turn.geometry=q
-- On the target tractor line, 0.6 m before the leading soil marker enters.
local s={x=p.goal.x,z=-4.6+0.6,t=math.pi,phi=math.pi}
f:setPose(s)
g_currentMission.time=0
assert(not f.turn:endTurn(16))
assert(f.object.lowerCount==1 and f.strategy.resumed==0)
g_currentMission.time=1000
assert(not f.turn:endTurn(16) and f.object.lowerCount==1)
g_currentMission.time=2600
assert(f.turn:endTurn(16) and f.strategy.resumed==0)
s.z=s.z-0.7
f:setPose(s)
assert(f.turn:endTurn(16) and f.strategy.resumed==1)

-- Parallel but 0.3 m displaced must fail; tractor heading alone passes.
f=makeEnvelopeLiveFixture(p)
f.turn.geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
s={x=p.goal.x+0.3,z=-4.6+0.6,t=math.pi,phi=math.pi}
f:setPose(s)
assert(not f.turn:endTurn(16))
assert(f.vehicle.stopped and f.object.lowerCount==0 and f.strategy.resumed==0)

-- Alignment can be lost on the exact hand-off frame, after hydraulics finish.
f=makeEnvelopeLiveFixture(p)
f.turn.geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
s={x=p.goal.x,z=-4.6+0.6,t=math.pi,phi=math.pi}
f:setPose(s)
g_currentMission.time=0
assert(not f.turn:endTurn(16))
s.x=s.x+0.3; s.z=s.z-0.7
f:setPose(s)
g_currentMission.time=3000
assert(not f.turn:endTurn(16))
assert(f.vehicle.stopped and f.strategy.resumed==0)
''')

    def test_no_last_waypoint_escape_and_cancellation_cleanup(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
local f=makeEnvelopeLiveFixture(p)
f.turn.result={ok=true}
f.turn:onWaypointPassed(5,{getNumberOfWaypoints=function() return 5 end})
assert(f.vehicle.stopped and f.strategy.resumed==0)
local q=assert(EnvelopeTurnGeometry.capture(f.turn))
f.turn.geometry=q
q.newTracker({{x=0,z=0},{x=0,z=10}})
assert(q.activeTracker)
f.turn:release()
assert(not q.activeTracker and not f.turn.planner)
''')

    def test_concave_polygon_and_island_reserve(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local polygon={{x=0,z=0},{x=10,z=0},{x=10,z=10},{x=6,z=10},{x=6,z=4},{x=4,z=4},{x=4,z=10},{x=0,z=10}}
assert(E.inside({x=2,z=8},polygon,0.5))
assert(not E.inside({x=5,z=8},polygon,0.5))
assert(not E.inside({x=3.8,z=8},polygon,0.5))
local island={{x=0,z=0},{x=2,z=0},{x=2,z=2},{x=0,z=2}}
assert(not E.outside({x=1,z=1},island,0.5))
assert(not E.outside({x=2.3,z=1},island,0.5))
assert(E.outside({x=3,z=1},island,0.5))
''')

    def test_unsupported_rigs_and_headlands_remain_stock(self):
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(6,9,2,11,12,0,1,54))
assert(EnvelopeTurnGeometry.supported(f.vehicle))
f.vehicle.spec_articulatedAxis={componentJoint=true}
assert(not EnvelopeTurnGeometry.supported(f.vehicle))
f.vehicle.spec_articulatedAxis=nil
f.object.spec_wheels={wheels={{steering={steeringAxleScale=1}}}}
assert(not EnvelopeTurnGeometry.supported(f.vehicle))
f.context.isHeadlandCorner=function() return true end
assert(not EnvelopeTurnGeometry.enabled(f.vehicle,f.context))
''')

    def test_end_to_end_runtime_pursuit_hydraulics_and_handoff(self):
        for angle,headland in [(0,50.4),(25,50.4),(0,100.8)]:
            with self.subTest(angle=angle,headland=headland):
                p=self.lua.globals().envelopeFixture(5.6,11.1,1.9,4.6,18.3,angle,1,headland)
                self.lua.globals().driveEnvelopeLiveFixture(p)

    def test_mounted_and_opposite_direction_runtime(self):
        # Nine 6 m headlands for the mounted forward-turn case. A smaller
        # headland may need the separate reversing family, not yet integrated.
        for values in [(6,0,0,3,5,25,1,54),(5.6,11.1,1.9,4.6,18.3,-25,-1,50.4)]:
            with self.subTest(values=values):
                p=self.lua.globals().envelopeFixture(*values)
                self.lua.globals().driveEnvelopeLiveFixture(p)

if __name__ == '__main__':
    unittest.main()
