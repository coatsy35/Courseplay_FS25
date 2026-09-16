"""Replay measured v0.19 geometry through deployment and fieldwork handover.

Recorded dimensions/offset change, with synthetic field and planar physics.
These tests do not claim to reproduce GIANTS collisions or terrain motion.
"""
import unittest
import json
from pathlib import Path
import test_ingame_envelope


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        test_ingame_envelope.InGameEnvelopeTests.setUp(self)
        test_ingame_envelope.InGameEnvelopeTests.load_stock_plough_fixture(self)
        self.lua.execute(Path(__file__).with_name('deployment-fixture.lua').read_text())
        # Execute production handover AND subsequent fieldwork states. Only
        # unrelated game services (sensors, speed limiter, scene) are mocked.
        root=Path(__file__).resolve().parents[2]
        for class_name,names in (
            ('AIDriveStrategyFieldWorkCourse',('resumeFieldworkAfterTurn','startWaitingForLower','getDriveData')),
            ('AIDriveStrategyPlowCourse',('resumeFieldworkAfterTurn',)),
        ):
            source=(root/f'scripts/ai/strategies/{class_name}.lua').read_text()
            for name in names:
                start=source.index(f'function {class_name}:{name}(')
                end=source.index('\nend',start)+len('\nend')
                self.lua.execute(f'{class_name}={class_name} or {{}}\n'+source[start:end])

    def test_v023_bent_arrival_replans_before_deployment_and_enters(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-first-pike-outer-headland.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local p,f=deploymentFixture(1)
configureV023Entry(p,f)
f.vehicle.cpGetFieldPolygon=function() return savedField end
attachFieldworkHandover(p,f)
driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.object.sideCommands==1)
local rejected=false
for _,message in ipairs(f.logs) do
    if message:find('working%-position approach needs local correction') then rejected=true end
end
assert(rejected,'did not reject the late stock approach before deployment')
''')

    def test_width_tolerance_does_not_admit_curved_or_displaced_work(self):
        self.lua.execute("""
local E=EnvelopeTurnPlanner
for _,width in ipairs({1,4,6,12,30}) do
    local p=envelopeFixture(width,11,2,4,17,0,1,60)
    p.goal={x=0,z=0,t=0}
    local allowance=E.entryTolerance(p)
    assert(allowance>=.1 and allowance<=.25)
    assert(E.assess(p,{x=allowance*.9,z=-5,t=0,phi=0}))
    assert(not E.assess(p,{x=allowance+.01,z=-5,t=0,phi=0}))
    assert(not E.assess(p,{x=0,z=-5,t=math.rad(20),phi=math.rad(20)}))
end
""")

    def test_preparation_uses_the_same_raised_deployment_goal(self):
        self.lua.execute("""
local p,f=deploymentFixture(1)
f.strategy.envelopeTurnModel=EnvelopeTurnGeometry.turnModel(assert(EnvelopeTurnGeometry.capture(f.turn)))
local captured
EnvelopeTurnPlanner.newSearch=function(model)
    captured=model
    return {update=function() return {ok=false} end}
end
f.turn:updatePreparation()
assert(captured and captured.deploymentLead==EnvelopeTurnPlanner.deploymentLead(captured,false))
assert(f.turn.preparationDone and not f.turn.result and f.object.lowerCount==0)
-- Stale preparation must never remove the newly measured staging allowance.
f.turn.preparedDeploymentLead=-100
f.turn:startPlanning();f.turn.planner:update(1)
local measured=f.turn.geometry
local _,minimum=EnvelopeTurnPlanner.deploymentLead(measured,false)
assert(measured.deploymentLead==minimum and f.object.lowerCount==0)
""")

    def test_candidate_preparation_continues_during_folding(self):
        self.lua.execute("""
local p,f=deploymentFixture(1)
f.turn.prepareStarted=0
f.controller.isRotationActive=function() return true end
local updates=0
f.turn.updatePreparation=function() updates=updates+1 end
f.turn:prepare()
assert(updates==1 and not f.turn.planner)
assert(f.object.sideCommands==0 and f.object.lowerCount==0)
""")

    def test_v025_second_row_exit_completes_within_bounded_wait(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-first-pike-outer-headland.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV025SecondExit(p,f,savedField)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
assert(f.initialAttempts<=64)
""")

    def test_turn_and_field_speed_follow_cp_settings(self):
        self.lua.execute("""
local p,f=deploymentFixture(1);local t=f.turn
p.fieldSpeed=24;p.turnSpeed=12
t.turnCourse={getCurrentWaypointIx=function() return 5 end,
    getDistanceFromFirstWaypoint=function() return 30 end,
    getDistanceToLastWaypoint=function() return 60 end}
assert(t:getForwardSpeed()==24)
t.result={repairedApproach=true}
assert(t:getForwardSpeed()==12)
p.turnSpeed=16
assert(t:getForwardSpeed()==16)
""")

    def test_v026_later_exit_reaches_fieldwork(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-first-pike-outer-headland.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV026Exit(p,f,savedField)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
""")

    def test_v027_exit_reaches_fieldwork(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-first-pike-outer-headland.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV027Exit(p,f,savedField)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
""")

    def test_v030_detected_field_and_measured_footprint_reach_fieldwork(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV030Exit(p,f,savedField)
-- A soil-data hole must not veto a route within the detected field/islands.
-- This is a synthetic ground classification, not a replay of the density map.
CpFieldUtil.isOnField=function() return false end
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
assert(f.initialAttempts<100,'recorded geometry exhausted the broad catalogue')
""")

    def test_v031_exit_at_saved_cp_speeds(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV031Exit(p,f,savedField)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
assert(f.initialAttempts<100)
""")

    def test_v031_saved_speeds_with_slower_steering(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV031Exit(p,f,savedField)
p.steeringTimeConstant=.5
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
""")

    def test_v032_later_exit_previews_working_position_before_turn(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute("""
local p,f=deploymentFixture(1);configureV032Exit(p,f,savedField)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
assert(math.abs(f.context.workStartNode.x+280.128)<.001,'changed the working row')
local preview=false
for _,line in ipairs(f.logs) do if line:find('measured working%-side preview') then preview=true end end
assert(preview,'working geometry was not considered before turning')
local side=f.context:shouldPlowBeOnTheLeft() and 'left' or 'right'
local model=f.strategy.envelopeWorkingModels[side]
f.turn:startPlanning();f.turn.planner:update(1)
assert(f.strategy.envelopeWorkingModels[side]==model,'later steering changed the cached deployment transform')
f.turn:release()
""")

    def test_deployment_model_rejects_changed_equipment(self):
        self.lua.execute("""
local p,f=deploymentFixture(1)
local geometry=assert(EnvelopeTurnGeometry.capture(f.turn))
local model=EnvelopeTurnGeometry.turnModel(geometry)
model.deploymentAngle=.2
assert(EnvelopeTurnGeometry.deploymentModel(geometry,model))
local working=EnvelopeTurnGeometry.deploymentModel(geometry,model)
local search=EnvelopeTurnPlanner.newDeploymentSearch(geometry,working)
local deleted=false;working.activeTracker={delete=function() deleted=true end}
f.turn.planner=search;f.turn:release();assert(deleted,'preview tracker leaked on cancellation')
model.objects[1]={}
assert(not EnvelopeTurnGeometry.deploymentModel(geometry,model))
""")

    def test_braking_distance_follows_curve_and_waypoint_lead(self):
        self.lua.execute("""
local E=EnvelopeTurnPlanner
local path={{x=0,z=0},{x=3,z=4},{x=3,z=14}}
local stop={x=3,z=12,ix=3}
assert(math.abs(E.distanceToStop(path,2,{x=0,z=0},stop,0)-13)<.001)
assert(math.abs(E.distanceToStop(path,3,{x=3,z=10},stop,0)-2)<.001)
assert(E.distanceToStop(path,4,{x=3,z=13},stop,0)==0)
local p=envelopeFixture(5.6,11,2,4,17,25,1,60)
p.approachSpeed=8;local lead=E.deploymentLead(p)
p.approachSpeed=20;assert(E.deploymentLead(p)==lead)
""")

    def test_long_narrow_angled_field_entries(self):
        self.lua.execute("""
for _,angle in ipairs({-60,-25,25,60}) do
    local p,f=narrowAngledDeploymentFixture(angle)
    attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
    assert(f.workedDistance>=8 and f.strategy.resumed==1)
end
""")

    def test_stock_k_turn_entry_reaches_fieldwork(self):
        self.lua.execute("""
local p=envelopeFixture(4,0,0,3,4,25,1,50)
p.start={x=p.goal.x,z=p.goal.z+25,t=math.pi,phi=math.pi}
local f=makeEnvelopeLiveFixture(p)
AIUtil.getSteeringParameters=function() return nil,0 end
AIUtil.hasChainedAttachments=function() return false end
local ppc=PurePursuitController(f.vehicle)
local proximity={registerBlockingObjectListener=function() end,unregisterBlockingObjectListener=function() end}
local turn=EnvelopeKTurn(f.vehicle,f.strategy,ppc,proximity,f.context,nil,4)
turn.endingTurnCourse=Course(f.vehicle,{{x=p.start.x,z=p.start.z},{x=p.goal.x,z=p.goal.z-30}},true)
ppc:setCourse(turn.endingTurnCourse);ppc:initialize(1)
f.vehicle.speed=8
assert(not turn:endTurn(0) and not turn.entryGuard,'captured a moving K-turn arrival')
f.vehicle.speed=0;turn:endTurn(0)
local guard=assert(turn.entryGuard)
f.turn=guard
-- Scene services normally supplied by GIANTS, as in the other live fixtures.
guard.getLowerImplementNode=function() return f.context.workStartNode end
guard.workStartHandler.shouldLowerThisImplement=function() return guard.lowerRequested or false,guard.lastContact or -100 end
p.planFixture=function()
    guard:prepare()
    repeat guard:updatePlanner() until not guard.planner
    return assert(guard.result)
end
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1)
""")

    def test_recorded_initial_loop_deploys_and_enters_on_both_sides(self):
        self.lua.execute('''
for _,side in ipairs({1,-1}) do
    local p,f=deploymentFixture(side)
    attachFieldworkHandover(p,f)
    driveEnvelopeLiveFixture(p,f)
    assert(f.strategy.resumed==1 and not f.vehicle.stopped)
    assert(f.object.sideCommands==1 and f.object.lowerCount==1)
    assert(f.strategy.state==f.strategy.states.WORKING and f.workedDistance>=8)
    assert(f.handoverSteps<=3 and f.fieldworkLowerCalls==1 and f.offsetResets==1)
    assert(f.initialAttempts<=16,'regression: stopped search became slow again')
    assert(f.turn.result.attempts<=8,'regression: local entry search became slow again')
end
''')

    def test_deployment_on_square_and_angled_boundaries_with_response_variation(self):
        self.lua.execute('''
for _,angle in ipairs({-41.5,0,25,41.5}) do
    local p,f=deploymentFixture(1)
    p.slope=math.tan(math.rad(angle));f.turn.entrySlope=p.slope
    p.physicsLength=10.8 -- independent yaw response; measured lever remains unchanged
    attachFieldworkHandover(p,f)
    driveEnvelopeLiveFixture(p,f)
    assert(f.workedDistance>=8 and f.object.sideCommands==1)
end
''')

    def test_v020_failed_response_cases_reach_fieldwork_on_both_sides(self):
        self.lua.execute('''
for _,side in ipairs({1,-1}) do
    for _,response in ipairs({10.4,11.6}) do
        local p,f=deploymentFixture(side)
        p.physicsLength=response
        attachFieldworkHandover(p,f)
        driveEnvelopeLiveFixture(p,f)
        assert(f.strategy.resumed==1 and f.workedDistance>=8)
        assert(f.object.sideCommands==1 and f.object.lowerCount==1)
        if f.turn.measuredResponseLength then assert(math.abs(f.turn.measuredResponseLength-response)<.15) end
        assert(f.initialAttempts<=16 and f.turn.result.attempts<=32)
        assert(math.abs(p.length-11.11)<.001)
    end
end
''')

    def test_mounted_and_trailed_drills_keep_the_normal_handover(self):
        self.lua.execute('''
for _,dimensions in ipairs({{4,0},{6,8},{12,11}}) do
    local width,length=dimensions[1],dimensions[2]
    local p=envelopeFixture(width,length,2,length>0 and 10 or 3,length>0 and 12 or 4,25,1,80)
    g_currentMission.time=0
    local f=makeEnvelopeLiveFixture(p)
    f.turn.ppc=PurePursuitController(f.vehicle)
    f.turn.ppc.shortLookaheadDistance=3
    attachFieldworkHandover(p,f)
    driveEnvelopeLiveFixture(p,f)
    assert(f.workedDistance>=8 and f.strategy.resumed==1)
end
''')

    def test_turnover_requires_both_tractor_and_tool_on_final_straight(self):
        self.lua.execute('''
local p,f=deploymentFixture(1);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t))
local goal=t.geometry.goal
t.result={path={{x=goal.x,z=goal.z-25},{x=goal.x,z=goal.z}}}
t.ppc.getCurrentWaypointIx=function() return 1 end
for _,pose in ipairs({{x=goal.x,z=goal.z-20,t=math.rad(20),phi=0},
        {x=goal.x+2,z=goal.z-20,t=0,phi=0},
        {x=goal.x,z=goal.z-20,t=0,phi=math.rad(78)}}) do
    f:setPose(pose)
    assert(t:checkWorkingPosition()) -- continue raised, do not rotate
    assert(f.object.sideCommands==0 and not t.rotationStarted and f.object.lowerCount==0)
end
f:setPose({x=goal.x,z=goal.z-20,t=0,phi=math.rad(20)})
t.result.path[1].x=goal.x+5
assert(t:checkWorkingPosition() and f.object.sideCommands==0,'turned over on remaining arc')
t.result.path[1].x=goal.x
assert(t:checkWorkingPosition() and f.object.sideCommands==0,'deployed with angled tool')
f:setPose({x=goal.x,z=goal.z-20,t=0,phi=0})
t:checkWorkingPosition()
assert(f.object.sideCommands==1 and t.deploymentReady,'failed to deploy on straight for raised alignment')
assert(f.object.lowerCount==0,'deployment must not lower an unaligned implement')
''')

    def test_old_late_pose_is_not_accepted_by_relaxing_the_entry_gate(self):
        self.lua.execute('''
local p=envelopeFixture(5.6,11.11,1.645,3.8,17.781,14.3,1,50.1)
p.start={x=-160.201,z=-131.010,t=math.rad(5.205),phi=math.rad(-26.644)}
p.goal={x=-156.761,z=-118.820,t=0};p.hitchX=.018;p.axleOffsetX=.02
p.lookahead=2.695;p.trackingRadius=5.389
p.work={{x=-3.264,z=-2.155,towed=true},{x=2.287,z=-2.469,towed=true},
    {x=-3.264,z=-16.136,towed=true,rear=true},{x=2.287,z=-16.136,towed=true,rear=true}}
p.workCentreX=(-3.264+2.287)/2+p.hitchX
local search=EnvelopeTurnPlanner.newApproachSearch(p);local result
repeat result=search:update(256) until result
assert(not result.ok and result.attempts<=96)
assert(EnvelopeTurnPlanner.entryTolerance(p)<=.25)
''')


if __name__=='__main__': unittest.main()
