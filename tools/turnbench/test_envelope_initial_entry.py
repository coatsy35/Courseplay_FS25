"""Initial-entry lifecycle and CP row-order regressions; GIANTS physics are mocked."""
import unittest
from pathlib import Path
import test_ingame_envelope


class InitialEntryTests(unittest.TestCase):
    def setUp(self):
        test_ingame_envelope.InGameEnvelopeTests.setUp(self)
        self.lua.execute('''
function initialFixture(parameters)
    g_currentMission.time=0
    local p=parameters or envelopeFixture(6,9,2,11,12,0,1,54)
    p.start={x=0,z=-20,t=0,phi=0};p.goal={x=0,z=0,t=0}
    local f=makeEnvelopeLiveFixture(p)
    AIUtil.getSteeringParameters=function() return p.length and f.object,p.length or 0 end
    AIUtil.hasChainedAttachments=function() return false end
    local s=f.strategy
    s.vehicle=f.vehicle;s.settings=f.vehicle:getCpSettings();s.workWidth=p.width
    s.settings.avoidFruit={getValue=function() return true end}
    s.turnNodes={};s.states={TURNING={},DRIVING_TO_WORK_START_WAYPOINT={}}
    s.state=s.states.DRIVING_TO_WORK_START_WAYPOINT
    s.getFrontAndBackMarkers=function() return p.front,p.work[3].z+p.hitchZ end
    s.getWorkWidth=function() return p.width end
    s.getTurnEndForwardOffset=function() return 0 end
    s.updateFieldworkOffset=function(_,course) course:setOffset(0,0) end
    s.proximityController={registerBlockingObjectListener=function() end,unregisterBlockingObjectListener=function() end}
    local function attr(start,finish)
        local a=CourseGenerator.WaypointAttributes();a.rowStart=start;a.rowEnd=finish;a.atBoundaryId='F';return a
    end
    s.fieldWorkCourse=Course(f.vehicle,{{x=0,z=0,attributes=attr(true,false)},
        {x=0,z=3.09,attributes=attr(false,true)},
        {x=6,z=10,attributes=attr(true,false)},
        {x=6,z=-1,attributes=attr(false,true)},
        {x=12,z=-2,attributes=attr(true,false)},{x=12,z=20,attributes=attr(false,true)}},false)
    local fm,bm=s:getFrontAndBackMarkers()
    f.context=RowStartOrFinishContext(f.vehicle,s.fieldWorkCourse,1,1,s.turnNodes,p.width,fm,bm,0,0)
    f.ppc=PurePursuitController(f.vehicle)
    s.ppc=f.ppc
    s.startCourse=function(_,course,ix) f.ppc:setCourse(course);f.ppc:initialize(ix) end
    f.starter=EnvelopeStartRowOnly(f.vehicle,s,f.ppc,f.context,
        Course(f.vehicle,{{x=0,z=-20},{x=0,z=-10},{x=0,z=0}},true))
    s.workStarter=f.starter
    s:startCourse(f.starter:getCourse(),1)
    return f,p
end
''')

    def load_strategy_method(self, name):
        source = (Path(__file__).resolve().parents[2] /
                  'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua').read_text()
        start = source.index('function AIDriveStrategyFieldWorkCourse:' + name + '(')
        end = source.index('\nend', start) + len('\nend')
        self.lua.execute('AIDriveStrategyFieldWorkCourse=AIDriveStrategyFieldWorkCourse or {}\n' + source[start:end])

    def test_short_row_handoff_preserves_first_turn_and_stock_fallback(self):
        self.load_strategy_method('resumeFieldworkAfterTurn')
        self.lua.execute('''
local f=initialFixture();local s=f.strategy;local c=s.fieldWorkCourse
assert(c:isTurnStartAtIx(2))
assert(EnvelopeTurnGeometry.pendingRowTurn(c,1,2)==2)
assert(EnvelopeTurnGeometry.pendingRowTurn(c,1,5)==2)
assert(EnvelopeTurnGeometry.pendingRowTurn(c,3,4)==4)
assert(EnvelopeTurnGeometry.pendingRowTurn(c,1,1)==nil)
local starts,turns={},{}
s.startWaitingForLower=function() end;s.lowerImplements=function() end
s.startCourse=function(_,course,ix) assert(course==c);starts[#starts+1]=ix end
s.startTurn=function(_,ix) turns[#turns+1]=ix end
c.getNextFwdWaypointIxFromVehiclePosition=function() return 2,true end
AIDriveStrategyFieldWorkCourse.resumeFieldworkAfterTurn(s,1)
assert(starts[1]==2 and turns[1]==2)
-- Disabled envelope keeps the stock hand-off, without introducing a turn.
s.settings.envelopeAlignedTurns.getValue=function() return false end
AIDriveStrategyFieldWorkCourse.resumeFieldworkAfterTurn(s,1)
assert(starts[2]==2 and #turns==1)
''')

    def test_initial_slope_uses_matching_boundary_end_and_not_pattern_order(self):
        self.lua.execute('''
local f=initialFixture();local c=f.strategy.fieldWorkCourse;local G=EnvelopeTurnGeometry
assert(math.abs(G.initialEntrySlope(c,1)+1/6)<1e-8)
assert(G.initialEntrySlope(c,2)==0)
-- An island edge must not become the field's working-entry line.
c:getWaypoint(4).attributes.atBoundaryId='island'
assert(math.abs(G.initialEntrySlope(c,1)+1/6)<1e-8)
''')

    def test_initial_entry_never_lowers_on_stock_route_or_last_waypoint(self):
        self.lua.execute('''
local f=initialFixture();local t=f.starter
t.state=t.states.APPROACHING_ROW
local checks=0;t.startEntryCheck=function() checks=checks+1 end
f.ppc.isReversing=function() return true end
t:getDriveData(16);assert(checks==0 and f.object.lowerCount==0)
f.ppc.isReversing=function() return false end
t:getDriveData(16);assert(checks==1 and f.object.lowerCount==0)
t:onLastWaypoint();assert(f.strategy.resumed==0 and t.reachedEnd)
t:release();t:getDriveData(16);assert(checks==1 and f.object.lowerCount==0)
''')

    def test_initial_guard_targets_original_row_and_waits_for_rotation(self):
        self.lua.execute('''
local f=initialFixture();local t=f.starter
local rotating=true
f.strategy.controllers={{isRotatablePlow=function() return true end,
    isRotationActive=function() return rotating end,isRotatedToSide=function() return not rotating end}}
t.state=t.states.APPROACHING_ROW
t:getDriveData(16);assert(not t.guard and f.object.lowerCount==0)
rotating=false;t:getDriveData(16)
local g=assert(t.guard);assert(f.strategy.aiTurn==g and f.strategy.state==f.strategy.states.TURNING)
g:getDriveData(16);g:updatePlanner()
assert(g.geometry and g.geometry.goal.x==0 and g.geometry.goal.z==0)
assert(f.object.lowerCount==0 and g.turnContext.turnEndWpIx==1)
t:release();assert(not g.planner)
''')

    def test_recovery_is_checked_before_driving_and_does_not_replace_original_row(self):
        self.lua.execute('''
local f=initialFixture();local t=f.starter;local s=f.strategy
t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
local g=t.guard;g.geometry={radius=9,length=9,front=-11}
local checks=0
g.startPlanning=function(self,path)
    assert(not path and s.aiTurn==g and s.state==s.states.TURNING)
    assert(self.turnContext.turnEndWpIx==1)
    checks=checks+1
end
PathfinderController=function() error('unchecked tractor-only recovery') end
g:stopWithReason('local correction unavailable')
assert(checks==0 and g.state==g.states.ENVELOPE_PREPARING)
g:prepare()
assert(checks==1 and t.recoveryAttempted and not f.vehicle.stopped and f.object.lowerCount==0)
g:stopWithReason('complete recovery cannot fit')
assert(checks==1 and f.vehicle.stopped and f.object.lowerCount==0)
''')

    def test_initial_approach_uses_stable_offset_and_turn_speed_only_for_envelope(self):
        self.load_strategy_method('calculateTightTurnOffset')
        self.lua.execute('''
local f=initialFixture();local s=f.strategy
s.tightTurnOffset=4.6
AIUtil.calculateTightTurnOffset=function() return 4.6 end
AIDriveStrategyFieldWorkCourse.calculateTightTurnOffset(s)
assert(s.tightTurnOffset==0)
s.settings.turnSpeed.getValue=function() return 20 end
assert(f.starter:getForwardSpeed()==8)
s.workStarter={}
AIDriveStrategyFieldWorkCourse.calculateTightTurnOffset(s)
assert(s.tightTurnOffset==4.6)
s.state=s.states.WORKING
AIDriveStrategyFieldWorkCourse.calculateTightTurnOffset(s)
assert(s.tightTurnOffset==4.6)
''')

    def test_initial_entry_failure_and_rotation_timeout_stop_without_lowering(self):
        self.lua.execute('''
local f=initialFixture();local t=f.starter
f.strategy.controllers={{isRotatablePlow=function() return true end,
    isRotationActive=function() return true end}}
t.state=t.states.APPROACHING_ROW
g_currentMission.time=100;t:getDriveData(16)
g_currentMission.time=30101;t:getDriveData(16)
assert(f.vehicle.stopped and f.object.lowerCount==0 and t.cancelled)
local other=initialFixture()
other.starter:fail('test initial failure')
assert(other.vehicle.stopped and other.object.lowerCount==0)
''')

    def test_initial_entry_drives_and_lowers_on_original_row_for_mounted_drills_and_plough(self):
        self.lua.execute('''
for _,dimensions in ipairs({{6,0,0,3,4},{6,9,2,11,12},{12,9,2,11,12},{5.6,11.1,1.9,4.6,18.3}}) do
    local p=envelopeFixture(dimensions[1],dimensions[2],dimensions[3],dimensions[4],dimensions[5],0,1,54)
    local f=initialFixture(p);local t=f.starter
    p.start.x=.3;p.start.t=math.rad(4);p.start.phi=math.rad(4)
    f:setPose(p.start)
    t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
    f.turn=assert(t.guard)
    -- Simulate the shipped entry guard and pursuit controller with finite
    -- acceleration and hydraulic delay. Every successful run must lower once
    -- and hand back only when the work edge reaches the original course row.
    p.planFixture=function(geometry)
        local g=f.turn
        g:prepare()
        for i=1,2000 do
            g:updatePlanner()
            if g.result then return g.result end
            assert(not f.vehicle.stopped and g.planner,'initial entry did not validate')
        end
        error('initial entry search did not finish')
    end
    driveEnvelopeLiveFixture(p,f)
    assert(f.strategy.resumed==1 and f.object.lowerCount==1 and not f.vehicle.stopped)
end
''')

    def test_v015_logged_start_recovers_and_lowers_on_original_row(self):
        self.lua.execute('''
-- 15 September 20:27:10: translated to row origin, mirrored to cover both
-- sides. Real measured pivot/markers/headings; synthetic field and planar
-- physics, since the live log does not include the complete field polygon.
for _,side in ipairs({1,-1}) do
    local p=envelopeFixture(5.6,11.09,1.637,3.783,17.748,14.3,1,78.8)
    p.hitchX=.044*side;p.axleOffsetX=.02*side;p.lookahead=2.695;p.vehicleRadius=5.389
    p.work={{x=-3.267*side,z=-2.146,towed=true},{x=2.284*side,z=-2.461,towed=true},
        {x=-3.267*side,z=-16.111,towed=true,rear=true},{x=2.284*side,z=-16.111,towed=true,rear=true}}
    p.workCentreX=(-3.267+2.284)/2*side+p.hitchX
    local f=initialFixture(p);local t=f.starter
    p.start={x=-.103*side,z=-6.643,t=math.rad(-11.354)*side,phi=math.rad(12.996)*side}
    f:setPose(p.start)
    t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
    local g=assert(t.guard);f.turn=g
    g.entrySlope=math.tan(math.rad(14.3))*side
    g.headlandSeed=78.8
    g.ppc.shortLookaheadDistance=2.695
    PathfinderController=function() error('must not drive an unchecked recovery loop') end
    p.planFixture=function()
        g:prepare()
        for i=1,10000 do
            if g.state==g.states.ENVELOPE_PREPARING then g:prepare() else g:updatePlanner() end
            if g.result then
                assert(t.recoveryAttempted,'fixture must require the full recovery')
                assert(not g.result.retainedApproach and not g.result.repairedApproach)
                assert(g.result.entryError<.1 and g.turnContext.turnEndWpIx==1)
                return g.result
            end
            assert(not f.vehicle.stopped and (g.planner or g.state==g.states.ENVELOPE_PREPARING),'initial recovery failed')
        end
        error('initial recovery did not finish')
    end
    driveEnvelopeLiveFixture(p,f)
    assert(f.strategy.resumed==1 and f.object.lowerCount==1 and not f.vehicle.stopped)
end
''')

    def test_initial_guard_keeps_headlands_and_unsupported_equipment_on_cp(self):
        self.load_strategy_method('createRowStarter')
        self.lua.execute('''
local f=initialFixture();local s=f.strategy
local function route() return Course(f.vehicle,{{x=0,z=-20},{x=0,z=0}},true) end
local selected=AIDriveStrategyFieldWorkCourse.createRowStarter(s,f.context,route())
assert(selected.name=='EnvelopeStartRowOnly' and s.raised==1)
s.fieldWorkCourse.isOnHeadland=function() return true end
assert(AIDriveStrategyFieldWorkCourse.createRowStarter(s,f.context,route()).name=='StartRowOnly')
s.fieldWorkCourse.isOnHeadland=function() return false end
f.vehicle.spec_articulatedAxis={componentJoint={}}
assert(AIDriveStrategyFieldWorkCourse.createRowStarter(s,f.context,route()).name=='StartRowOnly')
assert(s.raised==1)
''')

    def test_initial_recovery_never_retries_after_execution_or_lowering(self):
        self.lua.execute('''
for _,lowered in ipairs({false,true}) do
    local f=initialFixture();local t=f.starter
    t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
    local g=t.guard
    g.result=lowered and nil or {};g.lowerRequested=lowered
    g.geometry={}
    g.startPlanning=function() error('post-execution or post-lowering retry') end
    g:stopWithReason('test exhausted local entry')
    assert(f.vehicle.stopped and f.object.lowerCount==0)
end
''')

    def test_initial_recovery_centres_stock_plough_before_measuring_or_driving(self):
        test_ingame_envelope.InGameEnvelopeTests.load_stock_plough_fixture(self)
        self.lua.execute('''
local f=initialFixture();local t=f.starter
local c=addStockPloughFixture(f)
f.object.animation=0 -- already on its working side at initial entry
AIDriveStrategyCourse.onFinishRowEvent='finishRow'
local events=0
local old=f.strategy.raiseControllerEvent
f.strategy.raiseControllerEvent=function(self,event,...)
    if event==AIDriveStrategyCourse.onFinishRowEvent then
        events=events+1;c:onFinishRow(...)
    else old(self,event,...) end
end
t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
local g=assert(t.guard);g.geometry={}
g:stopWithReason('initial local approach infeasible')
assert(events==1 and f.object.playing and f.object.animation==.5)
local planned=0
g.startPlanning=function() planned=planned+1 end
g:getDriveData(16)
assert(planned==0 and f.object.lowerCount==0 and f.object.sideCommands==0)
f.object.playing=false
g:getDriveData(16)
assert(planned==1 and g.needsWorkingGeometry and events==1)
assert(f.object.lowerCount==0 and f.object.sideCommands==0)
''')

    def test_initial_route_does_not_rotate_plough_before_final_forward_approach(self):
        self.lua.execute('''
local f=initialFixture();local t=f.starter
local rotations=0
t.workStartHandler.lowerImplementsAsNeeded=function() rotations=rotations+1 end
t.state=t.states.DRIVING_TO_ROW;t:getDriveData(16)
assert(rotations==0)
t.state=t.states.APPROACHING_ROW
f.ppc.isReversing=function() return true end
t:getDriveData(16);assert(rotations==0)
f.ppc.isReversing=function() return false end
t.startEntryCheck=function() end
t:getDriveData(16);assert(rotations==1)
''')


if __name__ == '__main__':
    unittest.main()
