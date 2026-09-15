"""Live approach drift must be repaired before the lowering gate, not tolerated."""
import unittest
import test_ingame_envelope


class TrackingTests(unittest.TestCase):
    def setUp(self):
        test_ingame_envelope.InGameEnvelopeTests.setUp(self)

    def test_small_drift_is_corrected_before_the_strict_lowering_gate(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.6,3.8,17.7,14.3,1,62)
local f=makeEnvelopeLiveFixture(p);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t));t.geometry.goal.t=0
local live={x=.13,z=-8,t=0,phi=0}
t.result={tailStart=2,path={{x=0,z=-9},{x=0,z=-8},{x=0,z=5}},
    frames={{ix=2,x=0,z=-8,t=0,phi=0}}}
t.ppc.getCurrentWaypointIx=function() return 2 end
local checks=0;t.startPlanning=function(_,remaining) checks=checks+1;assert(#remaining>=2) end
assert(not t:checkApproachTracking(-8,live))
assert(checks==1 and t.approachCorrected and f.object.lowerCount==0)
-- No repeated correction or relaxed admission.
assert(t:checkApproachTracking(-7,live) and checks==1)
assert(EnvelopeTurnPlanner.edgeTolerance==.1)
''')

    def test_drift_check_interpolates_between_prediction_samples(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.1,1.6,3.8,17.7,14.3,1,62)
local f=makeEnvelopeLiveFixture(p);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t));t.geometry.goal.t=0
t.result={tailStart=2,frames={{ix=2,x=0,z=-8.1,t=-.01,phi=-.01},
    {ix=3,x=0,z=-7.9,t=.01,phi=.01}}}
t.ppc.getCurrentWaypointIx=function() return 2 end
t.startPlanning=function() error('sampling interval is not live drift') end
assert(t:checkApproachTracking(-8,{x=0,z=-8,t=0,phi=0}))
assert(not t.approachCorrected)
''')

    def test_v018_working_approach_replay_with_independent_trailer_response(self):
        self.lua.execute('''
for _,side in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.11,1.604,3.76,17.742,14.3,1,62.6)
    p.start={x=-159.051*side,z=-128.070,t=math.rad(19.635)*side,phi=math.rad(-24.845)*side}
    p.goal={x=-156.694*side,z=-118.820,t=0}
    p.hitchX=.012*side;p.axleOffsetX=.03*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389;p.physicsLength=10.7
    p.work={{x=-3.273*side,z=-2.156,towed=true},{x=2.279*side,z=-2.469,towed=true},
        {x=-3.273*side,z=-16.138,towed=true,rear=true},{x=2.279*side,z=-16.138,towed=true,rear=true}}
    p.workCentreX=(-3.273+2.279)/2*side+p.hitchX
    local f=makeEnvelopeLiveFixture(p);local t=f.turn
    t.entrySlope=p.slope;t.headlandSeed=62.6
    t.ppc=PurePursuitController(f.vehicle);t.ppc.shortLookaheadDistance=2.695
    p.planFixture=function()
        t.geometry=assert(EnvelopeTurnGeometry.capture(t))
        t.planner=EnvelopeTurnPlanner.newApproachSearch(t.geometry)
        for i=1,3000 do
            t:updatePlanner()
            if not t.planner then return assert(t.result) end
            assert(not f.vehicle.stopped)
        end
        error('logged entry search did not finish')
    end
    driveEnvelopeLiveFixture(p,f)
    assert(f.strategy.resumed==1 and f.object.lowerCount==1 and not f.vehicle.stopped)
end
''')

    def test_v016_approach_drift_replans_locally_and_completes_both_sides(self):
        self.lua.execute('''
local E,G=EnvelopeTurnPlanner,EnvelopeTurnGeometry
for _,side in ipairs({1,-1}) do
    -- 15 September 21:27:40: real pose before the failed v0.16 entry.
    -- Field is synthetic; the full live polygon is not recorded in the log.
    local p=envelopeFixture(5.6,11.09,1.633,3.778,17.74,14.3,1,66.4)
    p.start={x=-151.83*side,z=-135.40,t=math.rad(-17.35)*side,phi=math.rad(50.43)*side}
    p.goal={x=-157.083*side,z=-118.820,t=0}
    p.hitchX=.042*side;p.axleOffsetX=.03*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389
    p.work={{x=-3.268*side,z=-2.145,towed=true},{x=2.283*side,z=-2.460,towed=true},
        {x=-3.268*side,z=-16.107,towed=true,rear=true},{x=2.283*side,z=-16.107,towed=true,rear=true}}
    p.workCentreX=(-3.268+2.283)/2*side+p.hitchX
    local f=makeEnvelopeLiveFixture(p);local t=f.turn
    t.entrySlope=p.slope;t.headlandSeed=66.4
    t.ppc=PurePursuitController(f.vehicle);t.ppc.shortLookaheadDistance=2.695
    local geometry=assert(G.capture(t));t.geometry=geometry
    local original={};for k,v in pairs(geometry) do original[k]=v end
    original.start={x=-157.191*side,z=-128.254,t=math.rad(-3.3)*side,phi=math.rad(21.025)*side}
    original.newTracker=function(path,screening) return G.tracker(original,path,screening) end
    local path,tail=E.makePath(original,24.84,4.84,9.9,4,6*side)
    local predicted=E.simulate(original,path,tail,.075,true,true)
    assert(predicted.ok)
    t.result=predicted
    local ix,distance=tail,math.huge
    for i=tail,#path do
        local d=(path[i].x-p.start.x)^2+(path[i].z-p.start.z)^2
        if d<distance then ix,distance=i,d end
    end
    t.ppc:setCourse(Course(f.vehicle,path,true));t.ppc:initialize(ix)
    local logs={};t.log=function(_,format,...) logs[#logs+1]=string.format(format,...) end
    assert(t:endTurn(50)==false)
    assert(t.approachCorrected and t.planner and f.object.lowerCount==0)
    p.planFixture=function()
        for i=1,3000 do
            t:updatePlanner()
            if not t.planner then
                assert(t.result~=predicted and t.result.repairedApproach)
                assert(t.result.entryError<.1)
                return t.result
            end
            assert(not f.vehicle.stopped)
        end
        error('local tracking repair did not complete')
    end
    driveEnvelopeLiveFixture(p,f)
    assert(f.strategy.resumed==1 and f.object.lowerCount==1 and not f.vehicle.stopped)
    local corrections=0
    for _,s in ipairs(logs) do if s:find('approach differs from prediction') then corrections=corrections+1 end end
    assert(corrections==1)
end
''')

    def test_tracking_check_never_replans_after_lowering_or_repeatedly(self):
        self.lua.execute('''
local p=envelopeFixture(6,9,2,11,12,0,1,54)
local f=makeEnvelopeLiveFixture(p);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t))
t.startPlanning=function() error('unexpected repeat or post-lowering repair') end
t.lowerRequested=true
assert(t:checkApproachTracking(-15,p.start))
t.lowerRequested=false;t.approachCorrected=true
assert(t:checkApproachTracking(-15,p.start))
''')

    def test_v017_unfinished_bulb_does_not_trigger_tail_repair(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.09,1.633,3.778,17.74,14.3,1,61)
local f=makeEnvelopeLiveFixture(p);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t))
t.geometry.goal.t=0
local live={x=-165.15,z=-142.598,t=math.rad(-40.279),phi=math.rad(-84.758)}
t.result={tailStart=125,frames={{ix=125,x=-160,z=-140,t=0,phi=0}}}
t.ppc.getCurrentWaypointIx=function() return 122 end
t.startPlanning=function() error('unfinished bulb must not be replaced') end
assert(t:checkApproachTracking(-22.15,live))
assert(not t.approachCorrected and not t.approachCorrectionPending)
-- Even when the tractor faces the row, an earlier, neighbouring piece of
-- the bulb must not be compared against future tail samples.
live.t=0
t.ppc.getCurrentWaypointIx=function() return 125 end
t.result.frames[2]={ix=124,x=live.x,z=live.z,t=live.t,phi=live.phi}
assert(t:checkApproachTracking(-22.15,live))
assert(not t.approachCorrected)
''')

    def test_full_recovery_learns_faster_trailer_response_without_changing_geometry(self):
        self.lua.execute('''
for _,side in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.09,1.633,3.778,17.74,14.3,1,66.4)
    p.start={x=-157.191*side,z=-128.254,t=math.rad(-3.3)*side,phi=math.rad(21.025)*side}
    p.goal={x=-157.083*side,z=-118.820,t=0}
    p.hitchX=.042*side;p.axleOffsetX=.03*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389
    -- Independent physics: the measured geometry stays 11.09 m, whereas the
    -- realised yaw response matches the shorter lever inferred from the log.
    p.physicsLength=10.4
    p.work={{x=-3.268*side,z=-2.145,towed=true},{x=2.283*side,z=-2.460,towed=true},
        {x=-3.268*side,z=-16.107,towed=true,rear=true},{x=2.283*side,z=-16.107,towed=true,rear=true}}
    p.workCentreX=(-3.268+2.283)/2*side+p.hitchX
    local f=makeEnvelopeLiveFixture(p)
    f.turn.entrySlope=p.slope;f.turn.headlandSeed=66.4
    f.turn.ppc=PurePursuitController(f.vehicle);f.turn.ppc.shortLookaheadDistance=2.695
    local model=EnvelopeTurnGeometry.capture(f.turn)
    assert(math.abs(model.length-11.09)<.001)
    driveEnvelopeLiveFixture(p,f)
    assert(f.turn.approachCorrected and f.strategy.resumed==1)
    assert(math.abs(f.turn.measuredResponseLength-10.4)<.15)
    assert(f.object.lowerCount==1 and not f.vehicle.stopped)
    assert(math.abs(EnvelopeTurnGeometry.capture(f.turn).length-11.09)<.001)
end
''')

    def test_v017_initial_pose_with_centred_plough_completes_recovery(self):
        test_ingame_envelope.InGameEnvelopeTests.load_stock_plough_fixture(self)
        self.lua.execute('''
for _,side in ipairs({1,-1}) do
    -- Latest T7.300 start pose and measured working geometry. Centred marker
    -- movement and the field are synthetic; this exercises the real stock
    -- rotation controller and the envelope lifecycle, not GIANTS collisions.
    local p=envelopeFixture(5.6,11.09,1.636,3.781,17.744,14.3,1,61)
    p.start={x=-158.461*side,z=-130.834,t=math.rad(1.631)*side,phi=math.rad(20.333)*side}
    p.goal={x=-157.051*side,z=-118.820,t=0}
    p.hitchX=.034*side;p.axleOffsetX=.03*side;p.slope=p.slope*side
    p.lookahead=2.695;p.vehicleRadius=5.389
    p.work={{x=-3.268*side,z=-2.145,towed=true},{x=2.283*side,z=-2.460,towed=true},
        {x=-3.268*side,z=-16.108,towed=true,rear=true},{x=2.283*side,z=-16.108,towed=true,rear=true}}
    p.workCentreX=(-3.268+2.283)/2*side+p.hitchX
    for _,m in ipairs(p.work) do m.x=m.x*.1 end
    local f=makeEnvelopeLiveFixture(p);addStockPloughFixture(f)
    f.turn.needsWorkingGeometry=true;f.turn.entrySlope=p.slope;f.turn.headlandSeed=61
    f.turn.ppc=PurePursuitController(f.vehicle);f.turn.ppc.shortLookaheadDistance=2.695
    p.tickFixture=function(current)
        if current.object.playing and g_currentMission.time>=current.object.animationEnd then
            current.object.animation=current.object.targetAnimation
            current.object.playing=false
            for _,m in ipairs(p.work) do m.x=m.x/.1 end
        end
    end
    driveEnvelopeLiveFixture(p,f)
    assert(f.object.sideCommands==1 and f.object.lowerCount==1)
    assert(f.strategy.resumed==1 and not f.vehicle.stopped)
end
''')


if __name__=='__main__': unittest.main()
