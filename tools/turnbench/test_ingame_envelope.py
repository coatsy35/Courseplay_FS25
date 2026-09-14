"""Run the shipped Lua planner through CP's real Dubins solver, without GIANTS."""
import math
import unittest
import xml.etree.ElementTree as ET
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
productionTurningRadius = AIUtil.getTurningRadius
-- FS25 does not expose this desktop Lua library. Keep it absent for ALL tests.
coroutine=nil
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

    def test_loaded_course_detects_boundary_once_and_waits_for_islands(self):
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
local polygon=f.vehicle:cpGetFieldPolygon()
local calls,running=0,false
f.vehicle.cpGetFieldPolygon=function() return nil end
f.vehicle.cpIsFieldBoundaryDetectionRunning=function() return running end
f.vehicle.cpDetectFieldBoundary=function(_,x,z) calls=calls+1; running=true end
g_currentMission.time=0
assert(not f.turn:ensureFieldBoundary() and calls==1)
assert(not f.turn:ensureFieldBoundary() and calls==1 and not f.vehicle.stopped)
f.vehicle.cpGetFieldPolygon=function() return polygon end
-- A polygon delivered while the detector is running is not final yet.
assert(not f.turn:ensureFieldBoundary())
running=false
assert(f.turn:ensureFieldBoundary() and not f.vehicle.stopped)
-- A different field's cached polygon must not be used for this course.
f.turn.boundaryStarted=nil
f.vehicle.cpGetFieldPolygon=function() return {{x=1000,z=1000},{x=1100,z=1000},{x=1000,z=1100}} end
assert(not f.turn:ensureFieldBoundary() and calls==2)
running=false
f.vehicle.cpGetFieldPolygon=function() return nil end
assert(not f.turn:ensureFieldBoundary() and f.vehicle.stopped)
''')

    def load_stock_plough_fixture(self):
        self.lua.execute('''
package.path=ROOT..'/scripts/ai/controllers/?.lua;'..package.path
require('ImplementController')
require('PlowController')
function addStockPloughFixture(f)
    local o=f.object
    o.spec_plow={rotationPart={turnAnimation='turn'}}
    o.animation,o.playing,o.sideCommands=0.5,false,0
    o.getIsAnimationPlaying=function(self) return self.playing end
    o.getAnimationTime=function(self) return self.animation end
    o.getIsPlowRotationAllowed=function() return true end
    o.setRotationMax=function(self,side)
        self.sideCommands=self.sideCommands+1
        self.targetAnimation=side and 1 or 0
        self.playing=true
        self.animationEnd=g_currentMission.time+500
    end
    local c=PlowController(f.vehicle,o)
    c.debug=function() end
    f.strategy.controllers={c}
    f.controller=c
    f.strategy.raiseControllerEvent=function(_,event,...)
        if event==AIDriveStrategyCourse.onTurnEndProgressEvent then c:onTurnEndProgress(...) end
        if event==AIDriveStrategyCourse.onLoweringEvent then c:onLowering() end
    end
    PlowCenterTurnEvent={sendEvent=function(implement) implement.animation=0.5; implement.playing=true end}
    f.turn.states.ENVELOPE_ROTATING={name='ROTATING'}
    f.turn.states.ENVELOPE_PLANNING={name='PLANNING'}
    f.turn.states.ENVELOPE_PREPARING={name='PREPARING'}
    return c
end
''')

    def test_stock_plough_stays_centred_until_the_approach(self):
        self.load_stock_plough_fixture()
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
local c=addStockPloughFixture(f)
g_currentMission.time=0
c:onFinishRow(false) -- actual CP controller centres at row end
f.turn:startTurn()
f.turn:prepare()
assert(not f.turn.planner and f.object.sideCommands==0)
f.object.playing=false
f.turn:prepare()
assert(f.turn.planner and f.turn.needsWorkingGeometry and f.object.sideCommands==0)
assert(not c:isFullyRotated()) -- still centred, not on either working side
f.turn:release()
''')

    def test_centred_collision_outline_is_smaller_with_safe_scan_fallback(self):
        self.load_stock_plough_fixture()
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
for _,m in ipairs(p.work) do m.x=m.x*0.1 end -- centred soil markers
local f=makeEnvelopeLiveFixture(p)
addStockPloughFixture(f)
f.turn.needsWorkingGeometry=true
local scannerFactory=VehicleSizeScanner
local missed=false
VehicleSizeScanner=function()
    local scanner=scannerFactory()
    scanner._measureDimension=function(self,object,reference,distance,last,axis)
        self.scannedVehicleFound=not (missed and axis=='x' and distance<0)
        return (distance>0 and 1 or -1)*(axis=='x' and 0.5 or 4)
    end
    return scanner
end
local function trailerWidth(q)
    local lo,hi=math.huge,-math.huge
    for _,m in ipairs(q.footprint) do
        if m.towed then lo,hi=math.min(lo,m.x),math.max(hi,m.x) end
    end
    return hi-lo
end
local q=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(trailerWidth(q)<1.01)
missed=true
q=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(trailerWidth(q)>=5.6-1e-8) -- never trust a missed collision probe
''')

    def test_stock_plough_rotation_and_remeasured_entry_complete(self):
        self.load_stock_plough_fixture()
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4)
local completedFixture
p.configureFixture=function(f)
    addStockPloughFixture(f)
    f.turn.needsWorkingGeometry=true
    completedFixture=f
end
p.tickFixture=function(f)
    if f.object.playing and g_currentMission.time>=f.object.animationEnd then
        f.object.animation=f.object.targetAnimation
        f.object.playing=false
        -- The working side changes the marker offsets. The entry must be
        -- remeasured, not lowered against the saved centred marker positions.
        for _,m in ipairs(p.work) do m.x=m.x+0.2 end
    end
end
driveEnvelopeLiveFixture(p)
assert(completedFixture.object.sideCommands==1)
assert(not completedFixture.turn.needsWorkingGeometry)
assert(completedFixture.object.lowerCount==1)
''')

    def test_narrow_centred_plough_expands_before_pike_entry(self):
        self.load_stock_plough_fixture()
        self.lua.execute('''
for _,angle in ipairs({25,-41.5}) do
    local p=envelopeFixture(5.6,11.31,1.3,4.6,18.3,angle,angle>0 and 1 or -1,50.4)
    for _,m in ipairs(p.work) do m.x=m.x*0.1 end
    p.configureFixture=function(f)
        addStockPloughFixture(f)
        f.turn.needsWorkingGeometry=true
    end
    p.tickFixture=function(f)
        if f.object.playing and g_currentMission.time>=f.object.animationEnd then
            f.object.animation=f.object.targetAnimation
            f.object.playing=false
            for _,m in ipairs(p.work) do m.x=m.x/0.1 end
        end
    end
    driveEnvelopeLiveFixture(p)
end
''')

    def test_rotation_timeout_never_lowers_or_resumes(self):
        self.load_stock_plough_fixture()
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
addStockPloughFixture(f)
f.turn.needsWorkingGeometry=true
f.turn.state=f.turn.states.ENVELOPE_ROTATING
f.turn.rotationStarted=0
f.object.playing=true
g_currentMission.time=31000
f.turn:updateRotation()
assert(f.vehicle.stopped and f.object.lowerCount==0 and f.strategy.resumed==0)
''')

    def test_invalid_remaining_approach_is_replanned_before_driving(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
p.start={x=p.goal.x,z=15,t=math.pi,phi=math.pi}
local f=makeEnvelopeLiveFixture(p)
local t=f.turn
t.states.ENVELOPE_PLANNING={name='PLANNING'}
t.ppc=PurePursuitController(f.vehicle)
t.ppc:setShortLookaheadDistance()
function getTimeSec() return os.clock() end
-- This stale approach drives straight out of the field. Fresh working
-- geometry must reject it and search a checked replacement while stationary.
t:startPlanning({{x=0,z=p.start.z},{x=0,z=200}})
local updates=0
repeat
    local _,_,_,speed=t:getDriveData(16)
    assert(speed==0 and f.object.lowerCount==0)
    updates=updates+1
until t.state~=t.states.ENVELOPE_PLANNING or updates>10000
assert(t.state==t.states.TURNING and t.result.ok and t.result.repairedApproach)
assert(updates>1 and not t.geometry.activeTracker)
t:release()
t.ppc:delete()
''')

    def test_live_v05_rotation_snapshot_has_a_local_entry_correction(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
-- Recorded at 17:17:52 on 14 September, after v0.5 rotated the PW.
-- Field vertices were not logged: this is a tracking/alignment replay, not
-- a reconstruction of that field's boundary or GIANTS' tyre/joint physics.
local p=envelopeFixture(5.6,11.31,1.35,3.62,17.277,-41.5,-1,45.1)
p.start={x=-229.380,z=-34.264,t=math.rad(163.897),phi=math.rad(169.825)}
p.goal={x=-229.703,z=-50.040,t=-math.pi}
p.hitchX=-0.02;p.hitchZ=-1.35;p.lookahead=2.695;p.trackingRadius=5.389
p.work={{x=2.776,z=-3.157,towed=true},{x=-2.714,z=-2.274,towed=true},
 {x=2.776,z=-15.927,towed=true,rear=true},{x=-2.714,z=-15.927,towed=true,rear=true}}
p.workCentreX=(2.776-2.714)/2+p.hitchX
p.footprint=p.work
p.contains=function() return true end
local search=E.newApproachSearch(p)
local result
repeat result=search:update(256) until result
assert(result.ok and result.repairedApproach,result.reason)
assert(result.entryError<=E.edgeTolerance and result.distance<40)
for i=2,#result.path do
    local a,b=result.path[i-1],result.path[i]
    local _,forward=E.localPoint(b,{x=a.x,z=a.z,t=p.goal.t})
    assert(forward>0) -- no second loop or backwards hook
end
-- The same correction must fail when its actual footprint has no clearance.
p.contains=function() return false end
search=E.newApproachSearch(p)
repeat result=search:update(256) until result
assert(not result.ok)
''')

    def test_remeasurement_keeps_outgoing_headland_depth(self):
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4))
local q=assert(EnvelopeTurnGeometry.capture(f.turn))
f.turn.headlandSeed=q.headland
f:setPose({x=5.6,z=20,t=math.pi,phi=math.pi})
f.context.getDistanceToFieldEdge=function() error('must not measure into field after rotation') end
local working=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(working.headland==q.headland)
''')

    def test_live_v07_snapshot_finds_steering_lead_without_long_search(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
-- Post-rotation v0.7 log, 18:11:02 on 14 September. As with the v0.5 replay,
-- no field polygon or GIANTS physics is reconstructed from these log values.
for _,mirror in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.44,1.348,3.842,17.826,-41.5,-1,45.1)
    p.start={x=-229.605*mirror,z=-34.290,t=math.rad(163.844)*mirror,phi=math.rad(-177.447)*mirror}
    p.goal={x=-229.703*mirror,z=-50.040,t=-math.pi*mirror}
    p.hitchX=-0.018*mirror;p.hitchZ=-1.348;p.lookahead=2.695;p.trackingRadius=5.389
    p.slope=p.slope*mirror
    p.work={{x=3.385*mirror,z=-2.494,towed=true},{x=-2.167*mirror,z=-2.797,towed=true},
        {x=3.385*mirror,z=-16.478,towed=true,rear=true},{x=-2.167*mirror,z=-16.478,towed=true,rear=true}}
    p.workCentreX=(3.385-2.167)/2*mirror+p.hitchX;p.footprint=p.work
    p.contains=function() return true end
    local search=E.newApproachSearch(p)
    local result
    repeat result=search:update(256) until result
    assert(result.ok and result.repairedApproach,result.reason)
    assert(result.attempts<20 and result.entryError<=E.edgeTolerance)
    assert(math.abs(result.bias)>0.1 and result.distance<40)
    for i=2,#result.path do
        local a,b=result.path[i-1],result.path[i]
        local _,forward=E.localPoint(b,{x=a.x,z=a.z,t=p.goal.t})
        assert(forward>0) -- steering lead remains an approach, never a second loop
    end
end
''')

    def test_local_search_is_bounded_and_cannot_turn_back_out(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
-- Facing away from entry requires another manoeuvre, not a local correction.
local search=EnvelopeTurnPlanner.newApproachSearch(p)
local result,updates=nil,0
repeat result=search:update(10);updates=updates+1 until result or updates>200
assert(result and not result.ok and result.attempts<=96)
assert(not p.activeTracker)
''')

    def test_rotating_tool_direction_frame_controls_geometry_and_entry(self):
        self.lua.execute('''
local E,G=EnvelopeTurnPlanner,EnvelopeTurnGeometry
for _,skew in ipairs({-12.3,12.3}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
    local f=makeEnvelopeLiveFixture(p)
    local correct=f.object.steeringAxleNode
    -- A skewed body reference must not become the direction to align with the
    -- row. Real tools expose a dedicated travel frame for exactly this case.
    local body={x=correct.x,z=correct.z,t=correct.t+math.rad(skew)}
    f.object.steeringAxleNode=body
    f.object.getAIToolReverserDirectionNode=function() return correct end
    local pivot={x=0.5,z=16,t=0}
    f.object.getAITurnRadiusLimitation=function() return nil,pivot end
    local q=assert(G.capture(f.turn))
    assert(q.trailerNode==correct and math.abs(q.length-p.length)<1e-8)
    assert(math.abs(q.declaredPivotX-0.5)<1e-8)
    assert(math.abs(math.deg(q.directionOffset)+skew)<1e-6)
    for i,m in ipairs(q.work) do
        assert(math.abs(m.x-p.work[i].x)<1e-8 and math.abs(m.z-p.work[i].z)<1e-8)
    end
    f:setPose({x=p.goal.x,z=-4,t=math.pi,phi=math.pi})
    body.x,body.z,body.t=correct.x,correct.z,correct.t+math.rad(skew)
    local aligned,error,angle=G.assessLive(q,f.vehicle)
    assert(aligned and error<1e-8 and angle<1e-8)
    -- Demonstrate the old false rejection from the same physical markers.
    f.object.getAIToolReverserDirectionNode=function() return nil end
    local wrong=assert(G.capture(f.turn))
    aligned,error,angle=G.assessLive(wrong,f.vehicle)
    assert(not aligned and angle>math.rad(12))
    assert(G.trailerDirectionNode(f.object)==body) -- ordinary tools retain fallback
end
''')

    def test_skewed_tool_reference_completes_runtime_entry(self):
        self.lua.execute('''
for _,side in ipairs({-1,1}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,side,50.4)
    p.configureFixture=function(f)
        local direction=f.object.steeringAxleNode
        local body={x=direction.x,z=direction.z,t=direction.t+side*math.rad(12.3)}
        f.object.steeringAxleNode=body
        f.object.getAIToolReverserDirectionNode=function() return direction end
        local setPose=f.setPose
        f.setPose=function(self,state)
            setPose(self,state)
            body.x,body.z,body.t=direction.x,direction.z,direction.t+side*math.rad(12.3)
        end
    end
    driveEnvelopeLiveFixture(p)
end
''')

    def test_projected_geometry_matches_live_markers_on_both_rolled_sides(self):
        self.lua.execute('''
-- Full orthogonal yaw/pitch/roll transforms, unlike the ordinary flat fixture.
local flatDirection=localDirectionToWorld
function localDirectionToWorld(n,x,y,z)
    local roll,pitch=n.roll or 0,n.pitch or 0
    x,y=x*math.cos(roll)-y*math.sin(roll),x*math.sin(roll)+y*math.cos(roll)
    y,z=y*math.cos(pitch)-z*math.sin(pitch),y*math.sin(pitch)+z*math.cos(pitch)
    return flatDirection(n,x,y,z)
end
function localToWorld(n,x,y,z)
    local a,b,c=localDirectionToWorld(n,x,y,z)
    return n.x+a,(n.y or 0)+b,n.z+c
end
function getWorldTranslation(n) return n.x,n.y or 0,n.z end
for _,side in ipairs({-1,1}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,side,50.4)
    p.axleOffsetX=side*0.8
    local f=makeEnvelopeLiveFixture(p)
    f.object.rootNode.roll=side==1 and math.pi or 0
    f.object.rootNode.pitch=math.rad(12*side)
    f.object.rootNode.y=1.2
    f.object.input.node.y=0.8
    local q,reason=EnvelopeTurnGeometry.capture(f.turn)
    assert(q,reason)
    assert(math.abs(q.length-p.length)<1e-8)
    assert(math.abs(q.axleOffsetX-p.axleOffsetX)<1e-8)
    local _,error,angle,contact=EnvelopeTurnPlanner.assess(q,q.start)
    local _,liveError,liveAngle,liveContact=EnvelopeTurnGeometry.assessLive(q,f.vehicle)
    assert(math.abs(error-liveError)<1e-8)
    assert(math.abs(angle-liveAngle)<1e-8)
    assert(math.abs(contact-liveContact)<1e-8)
end
''')

    def test_pw_both_directions_with_tighter_tractor_and_offset_axle(self):
        self.lua.execute('''
for _,side in ipairs({-1,1}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25*side,side,50.4)
    p.vehicleRadius=5
    p.axleOffsetX=0.8*side
    driveEnvelopeLiveFixture(p)
end
''')

    def test_live_goal_preserves_predicted_curvature_with_offset_steering_node(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4)
local f=makeEnvelopeLiveFixture(p)
-- A tractor capable of a 5 m turn still receives the combination's 9 m limit.
f.vehicle.maxTurningRadius=5
for _,heading in ipairs({0,0.7,-1.4}) do
    f:setPose({x=12,z=30,t=heading,phi=heading})
    local steering=EnvelopeTurnPlanner.point(12,30,heading,0.4,1.7)
    steering.t=heading
    f.vehicle.getAISteeringNode=function() return steering end
    for _,goal in ipairs({{x=5,z=2},{x=-5,z=2},{x=1,z=20},{x=0,z=20}}) do
        local world=EnvelopeTurnPlanner.point(12,30,heading,goal.x,goal.z)
        local gx,gz,k=EnvelopeTurnGeometry.driveGoal(p,f.vehicle,world.x,world.z)
        local x,_,z=worldToLocal(steering,gx,0,gz)
        -- The curvature GIANTS derives from driveToPoint's steering-local goal.
        local received=2*x/(x*x+z*z)
        assert(math.abs(received-k)<1e-10)
        assert(math.abs(received)<=1/p.radius+1e-10)
    end
end
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

    def test_actual_cp_radius_resolution_and_xml_override_reach_planner(self):
        config = ET.parse(Path(__file__).resolve().parents[2]/'config/VehicleConfigurations.xml')
        pw = next(v for v in config.iter('Vehicle') if v.get('name') == 'pw10012.xml')
        self.lua.globals().pwRadius = float(pw.get('turnRadius'))
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
CpUtil.debugVehicleIf=function() end
f.object.getName=function() return 'PW 100-12' end
f.vehicle.maxTurningRadius=6
f.vehicle.getAIMinTurningRadius=function() return 7 end
g_vehicleConfigurations.get=function(_,object,key)
    if key=='turnRadius' and object==f.object then return pwRadius end
end
AIUtil.getTurningRadius=productionTurningRadius
local q=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(q.radius==math.max(7,pwRadius))
-- The XML value is an input, never a PW-specific constant. Exercise changes
-- in either direction, including a 5 m override below the tractor minimum.
for _,configuredRadius in ipairs({5,8,11}) do
    pwRadius=configuredRadius
    q=assert(EnvelopeTurnGeometry.capture(f.turn))
    assert(q.radius==math.max(7,configuredRadius))
end
-- A larger GIANTS tractor minimum must override the smaller implement radius.
f.vehicle.getAIMinTurningRadius=function() return 12 end
q=assert(EnvelopeTurnGeometry.capture(f.turn))
assert(q.radius==12)
''')

    def test_crossed_boundary_cannot_trigger_late_lowering_or_handoff(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
local f=makeEnvelopeLiveFixture(p)
f.turn.geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
-- Already aligned, but the front edge has travelled into the unworked row.
f:setPose({x=p.goal.x,z=-5.1,t=math.pi,phi=math.pi})
assert(not f.turn:endTurn(16))
assert(f.vehicle.stopped and f.object.lowerCount==0 and f.strategy.resumed==0)
-- Likewise, brake creep during hydraulic travel must not be accepted as entry.
f=makeEnvelopeLiveFixture(p)
f.turn.geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
f:setPose({x=p.goal.x,z=-4,t=math.pi,phi=math.pi})
g_currentMission.time=0
assert(not f.turn:endTurn(16) and f.object.lowerCount==1)
f:setPose({x=p.goal.x,z=-5.1,t=math.pi,phi=math.pi})
g_currentMission.time=500
assert(not f.turn:endTurn(16))
assert(f.vehicle.stopped and f.strategy.resumed==0)
''')

    def test_planner_failure_stops_once_without_repeating_frame_errors(self):
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
local calls=0
f.turn.states.ENVELOPE_PLANNING={name='PLANNING'}
function getTimeSec() return os.clock() end
f.turn.state=f.turn.states.ENVELOPE_PLANNING
f.turn.planner={update=function() calls=calls+1; error('injected engine failure') end}
f.turn:getDriveData(16)
f.turn:getDriveData(16)
assert(calls==1 and f.vehicle.stopped and not f.turn.planner)
assert(f.turn.state==f.turn.states.ENVELOPE_STOPPED)
''')

    def test_simulation_limits_samples_per_update(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
local calls=0
p.newTracker=function() return {
    sample=function(_,s) calls=calls+1; return 1,s.x,s.z+10 end,
    delete=function() end
} end
local simulation=EnvelopeTurnPlanner.newSimulation(p,{{x=0,z=0},{x=0,z=100}},2,0.15,false,false)
assert(simulation:update(3)==nil and calls==3)
assert(simulation:update(5)==nil and calls==8)
''')

    def test_constructor_preparation_and_incremental_lifecycle(self):
        self.lua.execute('''
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4))
-- Exercise the real inherited constructor, not a manually populated turn table.
AIUtil.getSteeringParameters=function() return true,13 end
AIUtil.hasChainedAttachments=function() return false end
local ppc=PurePursuitController(f.vehicle)
local proximity={registerBlockingObjectListener=function() end}
local turn=EnvelopeCourseTurn(f.vehicle,f.strategy,ppc,proximity,f.context,nil,5.6)
assert(turn.state==turn.states.INITIALIZING)
g_currentMission.time=0
turn:startTurn()
assert(turn.state==turn.states.ENVELOPE_PREPARING)
f.vehicle.speed=2
turn:prepare()
assert(not turn.planner) -- do not measure a moving rig
f.vehicle.speed=0
turn:prepare()
assert(turn.state==turn.states.ENVELOPE_PLANNING and turn.planner)
function getTimeSec() return os.clock() end
local updates=0
repeat turn:updatePlanner(); updates=updates+1
until turn.state~=turn.states.ENVELOPE_PLANNING or updates>10000
assert(turn.state==turn.states.TURNING and turn.result.ok)
assert(updates>1) -- numerical search really yielded between updates
assert(not turn.planner and not turn.geometry.activeTracker)
turn:release()
ppc:delete()
''')

if __name__ == '__main__':
    unittest.main()
