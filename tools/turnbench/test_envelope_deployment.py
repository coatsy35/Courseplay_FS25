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

    def test_v035_recorded_working_arrival_enters_at_varied_speeds_and_response(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        for lag in (.2,.5,.7039764115324976,1):
            for speed in (8,20,25):
                with self.subTest(lag=lag,speed=speed):
                    self.setUp()
                    self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
                    self.lua.execute(f'''
local p,f=deploymentFixture(1);configureV035WorkingArrival(p,f,savedField)
p.steeringTimeConstant={lag};p.turnSpeed={speed}
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.lowerCount==1)
assert(f.object.sideCommands==0,'already deployed arrival rotated again')
assert(EnvelopeTurnPlanner.entryTolerance(p)==.25)
''')

    def run_v036_staging_stress(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        points[16]={'x':-265.25,'z':38.25}
        points[0]={'x':-498.75,'z':-235.75}
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local p,f=deploymentFixture(1);configureV036Exit(p,f,savedField)
p.steeringTimeConstant=.6083763711210152
attachFieldworkHandover(p,f)
local result=driveEnvelopeLiveFixture(p,f)
v036Lead=result.deploymentLead
assert(f.workedDistance>=8 and f.object.sideCommands==1)
assert(v036Lead>16.96,'skipped the available intermediate staging positions')
''')
        lead_delta=self.lua.globals().v036Lead-12.96
        for dx,dz,heading,tool in ((0,0,0,0),(-.15,0,0,0),(.15,0,0,0),(0,-.5,0,0),
                                   (0,.5,0,0),(0,0,-1,0),(0,0,1,0),(0,0,0,-2),(0,0,0,2)):
            for lag in (.2,.5,.704,1):
                with self.subTest(dx=dx,dz=dz,heading=heading,tool=tool,lag=lag):
                    # Keep the loaded modules: the ZIP audit supplies packaged Lua.
                    self.lua.globals().arrivalOptions=self.lua.table_from(dict(
                        delta=lead_delta,dx=dx,dz=dz,heading=heading,tool=tool,lag=lag))
                    self.lua.execute('''
local o=arrivalOptions
local p,f=deploymentFixture(1);configureV036WorkingArrival(p,f,savedField,o.delta)
v036StressFixture=f
p.start.x=p.start.x+o.dx;p.start.z=p.start.z+o.dz
p.start.t=p.start.t+math.rad(o.heading);p.start.phi=p.start.phi+math.rad(o.tool)
p.steeringTimeConstant=o.lag;f:setPose(p.start)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.lowerCount==1)
assert(f.object.sideCommands==0)
''')

    def test_v036_missing_side_retains_room_for_measured_arrival_variations(self):
        self.run_v036_staging_stress()

    def test_v036_late_recorded_pose_is_rejected_without_extra_staging_room(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        points[16]={'x':-265.25,'z':38.25}
        points[0]={'x':-498.75,'z':-235.75}
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local p,f=deploymentFixture(1);configureV036WorkingArrival(p,f,savedField,0)
local ok=pcall(p.planFixture)
assert(not ok and f.vehicle.stopped and f.object.lowerCount==0)
''')

    def run_v037_calibration_stress(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        points[0]={'x':-498.75,'z':-235.75};points[16]={'x':-265.25,'z':38.25}
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        for angle in (-7.5,-8.427,-9.5):
            self.lua.globals().calibrationAngle=angle
            self.lua.execute('''
local p,f=deploymentFixture(1);configureV037Exit(p,f,savedField,calibrationAngle)
p.steeringTimeConstant=.196
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8)
v037Offset=f.initialDeploymentOffset
assert(v037Offset<-.5,'failed to account for working-side deployment')
''')
            for speed in (8,20,25):
                for lag in (.2,.5,1):
                    for step in (1/60,1/30,.1):
                        with self.subTest(calibration=angle,speed=speed,lag=lag,step=step):
                            self.lua.globals().arrivalOptions=self.lua.table_from(dict(speed=speed,lag=lag,step=step))
                            self.lua.execute("""
local o=arrivalOptions
local p,f=deploymentFixture(1);configureV037WorkingArrival(p,f,savedField,v037Offset)
v037StressFixture=f;p.steeringTimeConstant=o.lag;p.turnSpeed=o.speed;p.timeStep=o.step
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.lowerCount==1)
""")

    def test_v037_calibrated_arrival_and_recorded_geometry_variations(self):
        self.run_v037_calibration_stress()

    def test_v037_original_unshifted_arrival_remains_rejected(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local p,f=deploymentFixture(1);configureV037WorkingArrival(p,f,savedField,0)
local ok=pcall(p.planFixture)
assert(not ok and f.vehicle.stopped and f.object.lowerCount==0)
''')

    def test_v034_return_arc_keeps_tracking_room_at_varied_cp_speeds(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        for turn_speed,field_speed,lag in ((8,20,.365861),(20,27,.365861),(20,27,1),(25,30,1),(25,20,.5)):
            with self.subTest(turn_speed=turn_speed,field_speed=field_speed,lag=lag):
                self.setUp()
                self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
                self.lua.execute(f'''
local p,f=deploymentFixture(1);configureV034Exit(p,f,savedField)
p.turnSpeed={turn_speed};p.fieldSpeed={field_speed};p.steeringTimeConstant={lag}
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.strategy.resumed==1 and f.object.sideCommands==1)
assert(math.abs(f.peakRequestedSpeed-math.max(p.fieldSpeed,p.turnSpeed))<.001)
''')

    def test_v034_previous_route_fails_delayed_steering_clearance(self):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.execute('''
local E=EnvelopeTurnPlanner
local p,f=deploymentFixture(1);configureV034Exit(p,f,savedField)
local capture=EnvelopeTurnGeometry.capture
-- With no speed input the numerical model is the old ideal pursuit check.
-- Real runtime capture always supplies both CP speeds.
EnvelopeTurnGeometry.capture=function(...)
    local model,reason=capture(...)
    if model then model.fieldSpeed=0;model.approachSpeed=0 end
    return model,reason
end
local old=p.planFixture()
EnvelopeTurnGeometry.capture=capture
assert(old.directConnection and math.abs(old.routeLength-128.5)<.1)
local model=f.turn.geometry
model.fieldSpeed=27;model.approachSpeed=20
model.goal=E.point(model.goal.x,model.goal.z,model.goal.t,0,-old.deploymentLead)
model.goal.t=p.goal.t;model.deploymentLead=nil;model.deploymentTarget=true
local replay=E.newSimulation(model,old.path,old.tailStart,.075,true,true)
local result
for i=1,10000 do result=replay:update(10);if result then break end end
assert(result and not result.ok and result.reason=='field boundary' and result.steeringClearanceFailure,
    'old return arc was not rejected by the delayed steering sweep')
f.turn:release()
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
-- More staging distances are screened now; elapsed stopped time measures
-- responsiveness without tying the test to the old two-distance catalogue.
assert(f.initialPlanningDuration<=10000,'recorded exit spent too long planning')
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

    def run_cold_start_sequence(self, turn_speed=20, field_speed=27, steering=.159405, initial_angle=0, deployment_angle=9.5, early_angle=None):
        points=json.loads(Path(__file__).with_name('fixtures').joinpath('t7-v030-detected-field.json').read_text())
        self.lua.globals().savedField=self.lua.table_from([self.lua.table_from(p) for p in points])
        self.lua.globals().sequenceOptions=self.lua.table_from(dict(turnSpeed=turn_speed,fieldSpeed=field_speed,
            steering=steering,initialAngle=initial_angle,deploymentAngle=deployment_angle,earlyAngle=early_angle))
        self.lua.execute("""
local p,f=deploymentFixture(1)
local t=f.turn;local fresh={};for k,v in pairs(t) do fresh[k]=v end
coldSequenceFixture=f
-- Initially working on the right after stock startup. No pre-populated cache.
configureV031Exit(p,f,savedField)
local initial={x=-235.316,z=-45,t=0,phi=math.rad(sequenceOptions.initialAngle)}
p.work={{x=-3.260,z=-2.150,towed=true},{x=2.288,z=-2.468,towed=true},
    {x=-3.260,z=-16.128,towed=true,rear=true},{x=2.288,z=-16.128,towed=true,rear=true}}
p.length=11.100;p.hitchX=.031;p.hitchZ=-1.651;p.axleOffsetX=.020
f.object.animation=0;f:setPose(initial)
assert(not f.strategy.envelopeWorkingModels)
-- Run production finishRow, with only the GIANTS raise completion mocked.
local polygon=f.vehicle.cpGetFieldPolygon
f.vehicle.cpGetFieldPolygon=function() return nil end
t.preparationDone=true
t.workEndHandler={raiseImplementsAsNeeded=function() end,allRaised=function() return true end}
t.getRaiseImplementNode=function() return f.context.workEndNode end
t.debug=function() end
local event=f.strategy.raiseControllerEvent
AIDriveStrategyCourse.onFinishRowEvent=3
f.strategy.raiseControllerEvent=function(s,kind,...)
    if kind==3 then f.controller:onFinishRow(...) else event(s,kind,...) end
end
if sequenceOptions.earlyAngle then
    t.workEndHandler.allRaised=function() return false end
    f:setPose({x=initial.x,z=initial.z-15,t=0,phi=math.rad(sequenceOptions.earlyAngle)})
    t:finishRow(50)
    assert(not t.outgoingWorkingModel,'cached the unsettled early finish-row pose')
    assert(f.object.animation==0,'centred before row finish')
    t.workEndHandler.allRaised=function() return true end
    f:setPose(initial)
end
t:finishRow(50)
assert(t.outgoingWorkingModel and t.outgoingWorkingSide=='right')
assert(math.abs(t.outgoingWorkingModel.angle-math.rad(sequenceOptions.initialAngle))<1e-6)
assert(f.object.animation==.5,'stock finish-row event did not centre')
f.vehicle.cpGetFieldPolygon=polygon
-- First full turn deploys left. Preserve the model observed before centring.
configureV031Exit(p,f,savedField)
p.turnSpeed=sequenceOptions.turnSpeed;p.fieldSpeed=sequenceOptions.fieldSpeed;p.steeringTimeConstant=sequenceOptions.steering
f.object.playing=false;f.object.animation=.5
local first=p.stateFixture
p.stateFixture=function(current,state)
    local completes=current.object.playing and g_currentMission.time>=current.object.animationEnd
    local before=state.phi
    first(current,state)
    if completes then state.phi=EnvelopeTurnPlanner.wrap(before+math.rad(10)) end
end
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.object.sideCommands==1)
assert(f.strategy.envelopeWorkingModels.right and f.strategy.envelopeWorkingModels.left)
local learnt=f.strategy.envelopeWorkingModels.right
assert(learnt.deploymentAngle<0)
-- A new turn object on the same vehicle/equipment retains only strategy cache.
for k in pairs(t) do t[k]=nil end;for k,v in pairs(fresh) do t[k]=v end
t.ppc=PurePursuitController(f.vehicle);t.ppc.shortLookaheadDistance=2.695
t.workStartHandler=WorkStartHandler(f.vehicle,f.strategy,f.context)
t.workStartHandler.shouldLowerThisImplement=function() return t.lowerRequested or false,t.lastContact or -100 end
f.strategy.resumed=0;f.object.lowerCount=0;f.object.sideCommands=0
f.object.animation=.5;f.object.playing=false;f.vehicle.speed=0;f.vehicle.lastSpeed=0
configureV033Exit(p,f,savedField)
p.turnSpeed=sequenceOptions.turnSpeed;p.fieldSpeed=sequenceOptions.fieldSpeed;p.steeringTimeConstant=sequenceOptions.steering
local second=p.stateFixture
p.stateFixture=function(current,state)
    local completes=current.object.playing and g_currentMission.time>=current.object.animationEnd
    local before=state.phi
    second(current,state)
    if completes then state.phi=EnvelopeTurnPlanner.wrap(before-math.rad(sequenceOptions.deploymentAngle)) end
end
assert(f.strategy.envelopeWorkingModels.right==learnt)
attachFieldworkHandover(p,f);driveEnvelopeLiveFixture(p,f)
assert(f.workedDistance>=8 and f.object.sideCommands==1)
local preview=false
for _,line in ipairs(f.logs) do if line:find('previewing measured working side right') then preview=true end end
assert(preview,'second turn did not use the side learnt on the initial row')
""")

    def test_saved_work_resumption_observes_geometry_at_centring_not_early_finish_row(self):
        self.run_cold_start_sequence(early_angle=8.3)

    def test_cold_start_learns_both_sides_and_replays_v033_exit(self):
        self.run_cold_start_sequence()

    def test_cold_start_sequence_at_default_cp_speeds(self):
        self.run_cold_start_sequence(turn_speed=8,field_speed=20)

    def test_cold_start_sequence_with_slower_steering(self):
        self.run_cold_start_sequence(steering=.5)

    def test_cold_start_sequence_with_calibration_and_deployment_variation(self):
        self.run_cold_start_sequence(initial_angle=1,deployment_angle=10.5)

    def test_cold_start_sequence_at_higher_cp_speeds(self):
        self.run_cold_start_sequence(turn_speed=25,field_speed=30)

    def test_cold_start_sequence_with_opposite_calibration_error(self):
        self.run_cold_start_sequence(initial_angle=-1,deployment_angle=8.5)

    def test_cold_start_sequence_with_one_second_steering_response(self):
        self.run_cold_start_sequence(steering=1)

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
