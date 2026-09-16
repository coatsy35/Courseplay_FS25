"""Replay measured v0.19 geometry through deployment and fieldwork handover.

Recorded dimensions/offset change, with synthetic field and planar physics.
These tests do not claim to reproduce GIANTS collisions or terrain motion.
"""
import unittest
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
        assert(f.turn.approachCorrected and math.abs(f.turn.measuredResponseLength-response)<.15)
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

    def test_turnover_requires_final_straight_before_drawing_the_tool_into_line(self):
        self.lua.execute('''
local p,f=deploymentFixture(1);local t=f.turn
t.geometry=assert(EnvelopeTurnGeometry.capture(t))
local goal=t.geometry.goal
t.result={path={{x=goal.x,z=goal.z-25},{x=goal.x,z=goal.z}}}
t.ppc.getCurrentWaypointIx=function() return 1 end
for _,pose in ipairs({{x=goal.x,z=goal.z-20,t=math.rad(20),phi=0},
        {x=goal.x+2,z=goal.z-20,t=0,phi=0}}) do
    f:setPose(pose)
    assert(t:checkWorkingPosition()) -- continue raised, do not rotate
    assert(f.object.sideCommands==0 and not t.rotationStarted and f.object.lowerCount==0)
end
f:setPose({x=goal.x,z=goal.z-20,t=0,phi=math.rad(20)})
t.result.path[1].x=goal.x+5
assert(t:checkWorkingPosition() and f.object.sideCommands==0,'turned over on remaining arc')
t.result.path[1].x=goal.x
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
assert(EnvelopeTurnPlanner.edgeTolerance==.1 and math.abs(EnvelopeTurnPlanner.repairEdgeTolerance-.075)<1e-12)
''')


if __name__=='__main__': unittest.main()
