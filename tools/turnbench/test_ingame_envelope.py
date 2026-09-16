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
g_currentMission.time=0
function getName() return 'test node' end
require('PurePursuitController')
require('EnvelopeTurnPlanner')
require('EnvelopeTurnGeometry')
require('EnvelopeCourseTurn')
require('EnvelopeStartRowOnly')
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
    p.dubins=EnvelopeTurnGeometry.analyticPath
    p.newTracker=function(path,screening) return EnvelopeTurnGeometry.tracker(p,path,screening) end
    return p
end
''')
        self.lua.execute(Path(__file__).with_name('ingame-envelope-fixture.lua').read_text())

    def test_planar_screening_matches_production_ppc(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local paths={
    {{x=0,z=0},{x=0,z=5},{x=4,z=9},{x=8,z=9},{x=8,z=20}},
    {{x=0,z=0},{x=0,z=0},{x=0,z=1},{x=1,z=1},{x=1,z=10}}}
for _,side in ipairs({-1,1}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,side,50.4)
    paths[#paths+1]=E.makePath(p,24,4,10.575,4,side*3)
end
for _,path in ipairs(paths) do
    for _,offset in ipairs({0,1,8}) do
        local p={start={x=path[1].x,z=path[1].z,t=0},lookahead=2.695,radius=9,trackingRadius=5.389}
        local reference=EnvelopeTurnGeometry.tracker(p,path)
        local screen=E.newPlanarTracker(p,path)
        local states={{x=path[1].x+12,z=path[1].z-12,t=0}}
        for i=1,#path-1 do
            local a,b=path[i],path[i+1]
            local steps=math.max(1,math.ceil(math.sqrt((b.x-a.x)^2+(b.z-a.z)^2)*10))
            for j=0,steps-1 do
                local u=j/steps
                states[#states+1]={x=a.x+(b.x-a.x)*u+offset*math.sin(i+u),
                    z=a.z+(b.z-a.z)*u,t=0}
            end
        end
        for _,s in ipairs(states) do
            local a,x,z=reference:sample(s)
            local b,u,v=screen:sample(s)
            assert(a==b and math.abs(x-u)<1e-7 and math.abs(z-v)<1e-7,
                string.format('PPC mismatch wp %s/%s, goal %.9f/%.9f',a,b,x-u,z-v))
        end
        reference:delete();screen:delete()
        assert(not p.activeTracker)
    end
end
''')

    def test_v14_first_turn_screening_keeps_verified_path_with_fewer_nodes(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local p=envelopeFixture(5.6,11.29,1.656,3.4,17.031,11.8,1,69.1)
p.start={x=-158.595,z=-115.816,t=math.rad(-9.850),phi=math.rad(.250)}
p.goal={x=-168.135,z=-121.280,t=0}
p.hitchX=.024;p.hitchZ=-1.656;p.lookahead=2.695;p.trackingRadius=5.389;p.workedSide=1
p.work={{x=-.099,z=-2.678,towed=true},{x=.048,z=-1.739,towed=true},
    {x=-.099,z=-15.375,towed=true,rear=true},{x=.048,z=-15.375,towed=true,rear=true}}
p.workCentreX=(p.work[1].x+p.work[2].x)/2+p.hitchX;p.footprint={}
for _,m in ipairs(p.work) do p.footprint[#p.footprint+1]=m end
for _,x in ipairs({-1.9,1.9}) do for _,z in ipairs({-2,4}) do p.footprint[#p.footprint+1]={x=x,z=z} end end
-- Synthetic field for the portable regression; map-outline replay is separate.
p.contains=function(x,z) return x>=-215 and x<=-110 and z>=-200 and z<=-70 end
local createNode=CpUtil.createNode
local nodes=0
CpUtil.createNode=function(...) nodes=nodes+1;return createNode(...) end
local fast=E.plan(p)
local fastNodes=nodes;nodes=0
p.newTracker=function(path) return EnvelopeTurnGeometry.tracker(p,path) end
local reference=E.plan(p)
CpUtil.createNode=createNode
assert(fast.ok and reference.ok and fast.attempts==reference.attempts)
assert(math.abs(fast.entryError-reference.entryError)<1e-8)
assert(#fast.path==#reference.path and fastNodes<nodes/10)
for i,q in ipairs(fast.path) do
    assert(math.abs(q.x-reference.path[i].x)<1e-8 and math.abs(q.z-reference.path[i].z)<1e-8)
end
assert(fastNodes>0 and not p.activeTracker) -- final validation still uses PPC
''')

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

    def test_turn_hint_rebuilds_and_checks_actual_geometry(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4)
local first=E.plan(p)
assert(first.ok)
p.turnHint=E.turnHint(p,first)
local reused=E.plan(p)
assert(reused.ok and reused.usedTurnHint and reused.attempts==1)
-- A changed boundary must invalidate even a previously successful shape.
p.contains=function() return false end
assert(not E.plan(p).ok)
''')

    def test_worked_side_bulb_and_mirror_reduce_unworked_excursion(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
for _,mirror in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4)
    if mirror==-1 then
        p.goal.x=-p.goal.x;p.slope=-p.slope
        p.contains=function(x,z) return z-p.slope*x<=50.4*math.sqrt(1+p.slope*p.slope)-0.5 end
    end
    local shortest=E.plan(p)
    assert(shortest.ok)
    p.workedSide=-mirror
    local preferred=E.plan(p)
    assert(preferred.ok and preferred.preferWorked)
    local function extents(r)
        local low,high=0,0
        for i=1,r.tailStart do
            local x=r.path[i].x*mirror
            low,high=math.min(low,x),math.max(high,x)
        end
        return low,high
    end
    local oldLow,oldHigh=extents(shortest)
    local newLow,newHigh=extents(preferred)
    assert(newLow<oldLow-3 and newHigh<oldHigh-3)
    assert(preferred.entryError<=E.planningEdgeTolerance)
    for _,s in ipairs(preferred.frames) do assert(E.checkFootprint(p,s)) end
    p.turnHint=E.turnHint(p,preferred)
    local reused=E.plan(p)
    assert(reused.ok and reused.usedTurnHint and reused.preferWorked and reused.attempts==1)
    -- Losing row-side information must invalidate a side-specific hint safely.
    p.workedSide=nil
    assert(not E.plan(p).usedTurnHint)
end
''')

    def test_worked_side_comes_from_unambiguous_cp_row_attributes(self):
        self.lua.execute('''
local G=EnvelopeTurnGeometry
local f=makeEnvelopeLiveFixture(envelopeFixture(6,9,2,11,12,25,1,54))
local attributes={leftSideWorked=true,rightSideWorked=false}
f.turn.fieldWorkCourse={getWaypoint=function(_,ix)
    assert(ix==f.context.turnStartWpIx)
    return {attributes=attributes}
end}
assert(G.capture(f.turn).workedSide==-1)
attributes.leftSideWorked=false;attributes.rightSideWorked=true
assert(G.capture(f.turn).workedSide==1)
attributes.leftSideWorked=true
assert(G.capture(f.turn).workedSide==nil)
attributes.leftSideWorked=nil
assert(G.capture(f.turn).workedSide==nil)
''')

    def test_worked_side_preference_falls_back_when_boundary_blocks_it(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4)
p.workedSide=-1
local contains=p.contains
p.contains=function(x,z) return x>=-7 and contains(x,z) end
local r=E.plan(p)
assert(r.ok and not r.preferWorked,r.reason)
for _,s in ipairs(r.frames) do assert(E.checkFootprint(p,s)) end
''')

    def test_worked_side_with_drills_skipped_rows_and_mounted_tool(self):
        for width, length, rows in [(6, 9, 1), (12, 9, 7), (6, 0, 1)]:
            with self.subTest(width=width, length=length, rows=rows):
                p = self.lua.globals().envelopeFixture(width, length, 2, 11, 12, 25, rows, 72)
                p['workedSide'] = -1
                r = self.lua.globals().EnvelopeTurnPlanner.plan(p)
                self.assertTrue(r['ok'], (r['reason'], r['attempts']))
                self.assertLessEqual(r['entryError'], .05)

    def test_prepare_on_straight_does_not_control_vehicle(self):
        self.lua.execute('''
local p=envelopeFixture(6,9,2,11,12,25,1,54)
local f=makeEnvelopeLiveFixture(p)
f:setPose({x=0,z=-25,t=0,phi=0})
f.vehicle.speed=8
f.context.getDistanceToFieldEdge=function()
    return p.headland*math.sqrt(1+p.slope*p.slope)-f.vehicle.rootNode.z
end
f.turn.workEndHandler=WorkEndHandler(f.vehicle,f.strategy)
local updates=0
repeat
    f.turn:finishRow(16)
    updates=updates+1
    assert(not f.vehicle.stopped and f.object.lowerCount==0 and f.strategy.raised==0)
    assert(not f.turn.result and not f.turn.geometry and not f.turn.planner)
until f.turn.preparationDone or updates>5000
assert(f.turn.preparedTurnHint and updates>1)
assert(not f.turn.preparationGeometry and not f.turn.preparationPlanner)
-- Rebuild at the actual stopping position, rather than installing the path
-- predicted while the tractor was still finishing the row.
f:setPose(p.start)
local actual=assert(EnvelopeTurnGeometry.capture(f.turn))
actual.turnHint=f.turn.preparedTurnHint
local ready=EnvelopeTurnPlanner.plan(actual)
assert(ready.ok and ready.usedTurnHint)
-- A separate pending preparation releases its private tracker on cancellation.
f.turn.preparationDone=false
f.turn:updatePreparation()
local q=f.turn.preparationGeometry
assert(q and f.turn.preparationPlanner) -- planar screening has no scene nodes
f.turn:release()
assert(not q.activeTracker and not f.turn.preparationPlanner)
''')

    def test_speculative_raised_model_matches_equipment_and_mirrors(self):
        self.lua.execute('''
local E,G=EnvelopeTurnPlanner,EnvelopeTurnGeometry
local f=makeEnvelopeLiveFixture(envelopeFixture(5.6,11.1,1.9,4.6,18.3,25,1,50.4))
local p=assert(G.capture(f.turn))
p.start.phi=p.start.t+0.15
local model=G.turnModel(p)
local q=assert(G.capture(f.turn))
q.goal.x=-q.goal.x
assert(G.applyTurnModel(q,model))
assert(math.abs(E.wrap(q.start.phi-q.start.t)+0.15)<1e-9)
assert(q.work[1].x==-model.work[1].x and q.work[1]~=model.work[1])
q.work[1].x=99
assert(model.work[1].x~=99)
q=assert(G.capture(f.turn));q.width=q.width+1
assert(not G.applyTurnModel(q,model))
q=assert(G.capture(f.turn));q.objects[1].object={}
assert(not G.applyTurnModel(q,model))
''')

    def test_radius_between_joint_and_sloping_boundary_limits(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
-- Centred geometry from the sixth v0.11 turn. The synthetic sloping boundary
-- follows the map edge beside that turn; it is not a GIANTS density replay.
local p=envelopeFixture(5.6,11.31,1.674,3.47,17.144,18.3,1,45.9)
p.start={x=-252.118,z=-167.873,t=math.rad(179.936),phi=math.rad(170.705)}
p.goal={x=-257.716,z=-151.420,t=0}
p.hitchX=-0.033;p.hitchZ=-1.674;p.lookahead=2.695;p.trackingRadius=5.389
p.work={{x=0.223,z=-2.587,towed=true},{x=-0.091,z=-1.794,towed=true},
    {x=0.223,z=-15.470,towed=true,rear=true},{x=-0.091,z=-15.470,towed=true,rear=true}}
p.workCentreX=(0.223-0.091)/2+p.hitchX;p.footprint={}
for _,m in ipairs(p.work) do p.footprint[#p.footprint+1]=m end
for _,x in ipairs({-1.9,1.9}) do for _,z in ipairs({-2,4}) do p.footprint[#p.footprint+1]={x=x,z=z} end end
p.contains=function(x,z) return z>0.236*(x+250.191)-196.5984+0.7 end
local r=E.plan(p)
assert(r.ok,r.reason)
assert(r.radius>p.radius*1.1 and r.radius<p.radius*1.25)
assert(r.maxArticulation<=p.maxArticulation)
for _,s in ipairs(r.frames) do assert(E.checkFootprint(p,s)) end
p.turnHint=E.turnHint(p,r)
local nextTurn=E.plan(p)
assert(nextTurn.ok and nextTurn.attempts==1 and nextTurn.usedTurnHint)
''')

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
    -- The reserved tracking margin needs more trials than v0.8's first
    -- threshold-grazing candidate, but must remain a bounded local correction.
    assert(result.attempts<32 and result.maxEntryError<=E.repairEdgeTolerance)
    assert(math.abs(result.bias)>0.1 and result.distance<40)
    for i=2,#result.path do
        local a,b=result.path[i-1],result.path[i]
        local _,forward=E.localPoint(b,{x=a.x,z=a.z,t=p.goal.t})
        assert(forward>0) -- steering lead remains an approach, never a second loop
    end
end
''')

    def test_live_v09_snapshot_reserves_margin_through_entry(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
-- 23:35:03, 14 September: deployed geometry at the selected internal pivot.
-- Log replay validates geometry/search only, not GIANTS physics or this field.
for _,mirror in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.12,1.686,3.86,17.84,-41.5,-1,45.1)
    p.start={x=-229.737*mirror,z=-33.332,t=math.rad(158.397)*mirror,phi=math.rad(-176.017)*mirror}
    p.goal={x=-229.703*mirror,z=-50.040,t=-math.pi*mirror}
    p.hitchX=-0.021*mirror;p.hitchZ=-1.686;p.lookahead=2.695;p.trackingRadius=5.389
    p.slope=p.slope*mirror
    p.work={{x=3.277*mirror,z=-2.171,towed=true},{x=-2.276*mirror,z=-2.473,towed=true},
        {x=3.277*mirror,z=-16.154,towed=true,rear=true},{x=-2.276*mirror,z=-16.154,towed=true,rear=true}}
    p.workCentreX=(3.277-2.276)/2*mirror+p.hitchX;p.footprint=p.work
    p.contains=function() return true end
    local search=E.newApproachSearch(p)
    local result
    repeat result=search:update(256) until result
    assert(result.ok and result.repairedApproach,result.reason)
    assert(result.attempts<32)
    local checked=0
    for _,s in ipairs(result.frames) do
        local _,error,_,contact=E.assess(p,s)
        if contact>=E.loweringGateContact then
            assert(error<=E.repairEdgeTolerance)
            checked=checked+1
        end
    end
    assert(checked>10)
end
''')

    def test_three_live_v10_turns_and_revalidated_shape_hint(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
-- The two completed turns and third failure from 14 September, 23:46-23:51.
-- Recorded geometry, not a reconstruction of the physical field or tyres.
local rows={
    {start={x=-229.719,z=-33.374,t=158.642,phi=-176.134},goal={x=-229.703,z=-50.040,t=-180},
        hx=-0.021,hz=-1.686,length=11.12,front=-3.86,slope=-41.5,left=3.276,right=-2.276,lz=-2.170,rz=-2.474,bz=-16.154},
    {start={x=-234.584,z=-160.779,t=20.491,phi=6.450},goal={x=-235.315,z=-144.370,t=0},
        hx=0.023,hz=-1.644,length=11.09,front=-3.79,slope=17.3,left=-3.262,right=2.287,lz=-2.144,rz=-2.464,bz=-16.114},
    {start={x=-240.616,z=-24.312,t=163.938,phi=-177.927},goal={x=-240.912,z=-40.060,t=-180},
        hx=-0.021,hz=-1.689,length=11.12,front=-3.86,slope=-41.7,left=3.277,right=-2.275,lz=-2.169,rz=-2.473,bz=-16.153}}
local function run(p)
    local search=E.newApproachSearch(p);local r
    repeat r=search:update(256) until r
    return r
end
for _,mirror in ipairs({1,-1}) do
    for _,row in ipairs(rows) do
        local p=envelopeFixture(5.6,row.length,-row.hz,-row.front,18,row.slope,-1,45)
        p.start={x=row.start.x*mirror,z=row.start.z,t=math.rad(row.start.t)*mirror,phi=math.rad(row.start.phi)*mirror}
        p.goal={x=row.goal.x*mirror,z=row.goal.z,t=math.rad(row.goal.t)*mirror}
        p.hitchX=row.hx*mirror;p.hitchZ=row.hz;p.front=row.front;p.slope=p.slope*mirror
        p.lookahead=2.695;p.trackingRadius=5.389
        p.work={{x=row.left*mirror,z=row.lz,towed=true},{x=row.right*mirror,z=row.rz,towed=true},
            {x=row.left*mirror,z=row.bz,towed=true,rear=true},{x=row.right*mirror,z=row.bz,towed=true,rear=true}}
        p.workCentreX=(row.left+row.right)/2*mirror+p.hitchX;p.footprint=p.work
        p.contains=function() return true end
        local r=run(p)
        assert(r.ok and r.attempts<=32,r.reason)
        assert(r.maxEntryError<=E.repairEdgeTolerance)
        -- The retained worst error includes every fine admission sample.
        for _,s in ipairs(r.frames) do
            local aligned,error,_,contact=E.assess(p,s)
            if contact>=E.loweringGateContact then assert(aligned and error<=r.maxEntryError+1e-9) end
        end
        p.approachHint={factorA=r.factorA,factorB=r.factorB,straightRatio=r.straight/p.width,
            biasRatio=r.bias/(p.width*E.approachSide(p))}
        local cached=run(p)
        assert(cached.ok and cached.maxEntryError<=r.maxEntryError+1e-9)
        if r.maxEntryError<=E.planningEdgeTolerance then
            assert(cached.usedHint and cached.attempts==1)
        else
            assert(cached.attempts>1 and cached.hintMarginError)
        end
        -- A cached shape never bypasses a changed boundary.
        p.contains=function() return false end
        assert(not run(p).ok)
        p.contains=function() return true end
        p.approachHint.straightRatio=10
        assert(run(p).ok) -- invalid hints are ignored, not treated as geometry
    end
end
''')

    def test_v12_marginal_cached_entry_is_refined_before_execution(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local function run(p)
    local search=E.newApproachSearch(p);local r
    repeat r=search:update(256) until r
    return r
end
for _,mirror in ipairs({1,-1}) do
    -- Working-position snapshot from the 35th turn of the v0.12 field run.
    -- The box is a synthetic boundary, not the recorded GIANTS density map.
    local p=envelopeFixture(5.6,11.12,1.696,3.87,17.85,10.3,-1,46.5)
    p.start={x=-419.042*mirror,z=80.236,t=math.rad(163.002)*mirror,phi=math.rad(171.469)*mirror}
    p.goal={x=-420.120*mirror,z=64.430,t=-math.pi*mirror}
    p.hitchX=-0.043*mirror;p.hitchZ=-1.696;p.slope=p.slope*mirror;p.lookahead=2.695;p.trackingRadius=5.389
    p.work={{x=3.259*mirror,z=-2.178,towed=true},{x=-2.284*mirror,z=-2.472,towed=true},
        {x=3.259*mirror,z=-16.154,towed=true,rear=true},{x=-2.284*mirror,z=-16.154,towed=true,rear=true}}
    p.workCentreX=(p.work[1].x+p.work[2].x)/2+p.hitchX;p.footprint={}
    for _,m in ipairs(p.work) do p.footprint[#p.footprint+1]=m end
    for _,x in ipairs({-1.9,1.9}) do for _,z in ipairs({-2,4}) do p.footprint[#p.footprint+1]={x=x,z=z} end end
    p.contains=function(x,z) return x*mirror>=-445 and x*mirror<=-395 and z>=40 and z<=115 end
    p.approachHint={factorA=0.1,factorB=0.1,straightRatio=4/p.width,
        biasRatio=0.645*mirror/(p.width*E.approachSide(p))}
    local refined=run(p)
    assert(refined.ok and not refined.usedHint,refined.reason)
    assert(refined.hintMarginError>0.06 and refined.hintMarginError<E.repairEdgeTolerance)
    assert(refined.maxEntryError<0.02 and refined.attempts<=8)
    assert(refined.straight==4 and E.edgeTolerance==0.1)
    for _,s in ipairs(refined.frames) do assert(E.checkFootprint(p,s)) end
    -- This good shape can still take the fast path next time, with full checks.
    p.approachHint={factorA=refined.factorA,factorB=refined.factorB,straightRatio=refined.straight/p.width,
        biasRatio=refined.bias/(p.width*E.approachSide(p))}
    local reused=run(p)
    assert(reused.ok and reused.usedHint and reused.attempts==1)
    p.contains=function() return false end
    assert(not run(p).ok)
end
''')

    def test_v13_rotated_trailer_uses_wider_forward_lead(self):
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local function run(p)
    local search=E.newApproachSearch(p);local r
    repeat r=search:update(256) until r
    return r
end
for _,mirror in ipairs({1,-1}) do
    -- 15 September 09:41:07: rotation left a 53-degree hitch angle.
    -- This regression uses a synthetic field; the map-outline replay is separate.
    local p=envelopeFixture(5.6,11.08,1.627,3.77,17.728,11.9,1,65.1)
    p.start={x=-163.515*mirror,z=-136.276,t=math.rad(-21.256)*mirror,phi=math.rad(31.509)*mirror}
    p.goal={x=-168.114*mirror,z=-121.280,t=0}
    p.hitchX=.104*mirror;p.hitchZ=-1.627;p.slope=p.slope*mirror
    p.lookahead=2.695;p.trackingRadius=5.389;p.vehicleRadius=5.389
    p.work={{x=-3.270*mirror,z=-2.145,towed=true},{x=2.282*mirror,z=-2.458,towed=true},
        {x=-3.270*mirror,z=-16.101,towed=true,rear=true},{x=2.282*mirror,z=-16.101,towed=true,rear=true}}
    p.workCentreX=(p.work[1].x+p.work[2].x)/2+p.hitchX;p.footprint={}
    for _,m in ipairs(p.work) do p.footprint[#p.footprint+1]=m end
    for _,x in ipairs({-1.9,1.9}) do for _,z in ipairs({-2,4}) do p.footprint[#p.footprint+1]={x=x,z=z} end end
    p.contains=function(x,z) return x*mirror>=-190 and x*mirror<=-145 and z>=-170 and z<=-90 end
    local r=run(p)
    assert(r.ok,r.reason)
    assert(r.attempts<=24 and r.straight==4 and math.abs(r.bias)>2)
    assert(r.maxEntryError<=E.planningEdgeTolerance and r.maxArticulation<p.maxArticulation)
    for _,s in ipairs(r.frames) do assert(E.checkFootprint(p,s)) end
    for i=2,#r.path do assert(r.path[i].z>r.path[i-1].z) end
    p.approachHint={factorA=r.factorA,factorB=r.factorB,straightRatio=r.straight/p.width,
        biasRatio=r.bias/(p.width*E.approachSide(p))}
    assert(run(p).attempts==1)
    p.contains=function() return false end
    assert(not run(p).ok)
    -- Exercise the actual entry state machine and finite acceleration/hydraulics,
    -- with the tighter tractor lock rather than the planned combination radius.
    p.configureFixture=function(f)
        addEnvelopeInternalPivotFixture(f,p,1.321)
        local exit=E.point(p.goal.x,p.goal.z,0,10,10*p.slope)
        f.context.workEndNode={x=exit.x,z=exit.z,t=0}
    end
    p.planFixture=run
    driveEnvelopeLiveFixture(p)
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

    def test_internal_pivot_keeps_marker_geometry_constant_through_articulation(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,2.3,4.6,18.3,0,1,50.4)
local f=makeEnvelopeLiveFixture(p)
local pivot,input=addEnvelopeInternalPivotFixture(f,p,1.3)
for _,heading in ipairs({-0.4,0,0.4}) do
    f:setPose({x=0,z=20.7,t=heading,phi=-heading})
    local q=assert(EnvelopeTurnGeometry.capture(f.turn))
    assert(q.pivotSource=='internal drawbar joint')
    assert(math.abs(q.hitchZ+2.3)<1e-8 and math.abs(q.inputHitchZ+1.3)<1e-8)
    assert(math.abs(q.length-11.1)<1e-8 and math.abs(q.maxArticulation-math.rad(80))<1e-8)
    for i,m in ipairs(q.work) do
        assert(math.abs(m.x-p.work[i].x)<1e-8 and math.abs(m.z-p.work[i].z)<1e-8)
    end
end
-- A declared pivot alone is insufficient: a yawing input or disconnected
-- component must not be silently flattened into this one-joint model.
f.object.input.upperRotLimitScale[2]=1
assert(EnvelopeTurnGeometry.trailerPivotNode(f.object,f.object.input)==input)
f.object.input.upperRotLimitScale[2]=0
f.object.input.rootNode={}
assert(EnvelopeTurnGeometry.trailerPivotNode(f.object,f.object.input)==input)
''')

    def test_generic_internal_pivot_runtime_entry(self):
        self.lua.execute('''
for _,width in ipairs({5.6,6,12}) do
    local p=envelopeFixture(width,9,2.3,4.6,14,25,width==5.6 and 1 or 7,72)
    p.configureFixture=function(f) addEnvelopeInternalPivotFixture(f,p,1.3) end
    driveEnvelopeLiveFixture(p)
end
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

    def test_lowering_transient_waits_but_settled_displacement_fails(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.9,4.6,18.3,0,1,50.4)
for _,persistent in ipairs({false,true}) do
    local f=makeEnvelopeLiveFixture(p)
    f.turn.geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
    f:setPose({x=p.goal.x,z=-4,t=math.pi,phi=math.pi})
    g_currentMission.time=0
    assert(not f.turn:endTurn(16) and f.object.lowerCount==1)
    -- Lowering can displace markers while the tractor itself stays stationary.
    for _,node in ipairs({f.object.left,f.object.right,f.object.back}) do node.x=node.x+0.15 end
    g_currentMission.time=500
    assert(not f.turn:endTurn(16) and not f.vehicle.stopped)
    assert(not f.turn.entryReleased and f.strategy.resumed==0)
    if not persistent then
        for _,node in ipairs({f.object.left,f.object.right,f.object.back}) do node.x=node.x-0.15 end
    end
    g_currentMission.time=2600
    local canDrive=f.turn:endTurn(16)
    assert(canDrive==not persistent and f.vehicle.stopped==persistent)
    assert(f.strategy.resumed==0 and f.object.lowerCount==1)
end
''')

    def test_runtime_holds_through_lowering_marker_transient(self):
        self.lua.execute('''
for _,length in ipairs({0,11.1}) do
    local p=envelopeFixture(6,length,1.9,4.6,18.3,0,1,72)
    local checked=false
    p.postPoseFixture=function(f)
        if f.turn.lowerRequested then
            local age=g_currentMission.time-f.turn.loweringStarted
            if age>100 and age<1800 then
                for _,node in ipairs({f.object.left,f.object.right,f.object.back}) do node.x=node.x+0.15 end
                assert(not f.turn.entryReleased and f.vehicle.speed<0.21)
                checked=true
            end
        end
    end
    driveEnvelopeLiveFixture(p)
    assert(checked)
end
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
