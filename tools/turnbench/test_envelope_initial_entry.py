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

    def test_reposition_preserves_cp_reverse_permission_and_rechecks_entry(self):
        self.lua.execute('''
for _,reverse in ipairs({false,true}) do
    local f=initialFixture();local t=f.starter;local s=f.strategy
    s.getAllowReversePathfinding=function() return reverse end
    local requested
    PathfinderContext=function(vehicle)
        assert(vehicle==f.vehicle)
        return {allowReverse=function(self,v) self.reverse=v;return self end,
            mustBeAccurate=function(self,v) self.accurate=v;return self end,
            ignoreFruit=function(self,v) self.ignore=v;return self end}
    end
    PathfinderController=function(vehicle,radius)
        assert(vehicle==f.vehicle and radius==9)
        return {registerListeners=function(self,o,fn) self.owner=o;self.done=fn end,
            findPathToNode=function(self,context,node,x,z,retries)
                assert(context.reverse==reverse and context.accurate and not context.ignore)
                assert(node==t.turnContext.workStartNode and x==0 and z<11 and retries==0)
                requested=self;return true
            end}
    end
    t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
    local g=t.guard;g.geometry={radius=9,length=9,front=-11}
    g:stopWithReason('test local correction unavailable')
    assert(requested==t.entryPathfinder and not t.guard and t.repositions==1 and not f.vehicle.stopped)
    local route=Course(f.vehicle,{{x=0,z=-30,rev=true},{x=0,z=-35,rev=true},{x=0,z=-10}},true)
    requested.done(t,requested,true,route)
    assert(not t.entryPathfinder and t.turnCourse==route and f.object.lowerCount==0)
    t:onLastWaypoint();assert(s.resumed==0)
    t:release();requested.done(t,requested,false,nil);assert(not f.vehicle.stopped)
end
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
local other=initialFixture();local p={};other.starter.entryPathfinder=p
other.starter:onRepositionFinished(p,false,nil)
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

    def test_initial_reposition_attempts_are_bounded_and_never_retry_after_lowering(self):
        self.lua.execute('''
for _,lowered in ipairs({false,true}) do
    local f=initialFixture();local t=f.starter
    t.state=t.states.APPROACHING_ROW;t:getDriveData(16)
    local g=t.guard
    t.repositions=lowered and 0 or 2;g.lowerRequested=lowered
    t.reposition=function() error('unbounded or post-lowering retry') end
    g:stopWithReason('test exhausted local entry')
    assert(f.vehicle.stopped and f.object.lowerCount==0)
end
''')


if __name__ == '__main__':
    unittest.main()
