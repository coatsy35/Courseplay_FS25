"""Entry preparation and the immediate next turn after a short working row."""
import unittest
from pathlib import Path
import test_envelope_initial_entry
import test_envelope_deployment

ROOT=Path(__file__).resolve().parents[2]


def method(lua,cls,name):
    source=(ROOT/f'scripts/ai/strategies/{cls}.lua').read_text()
    start=source.index(f'function {cls}:{name}(')
    end=source.index('\nend',start)+4
    lua.execute(f'{cls}={cls} or {{}}\n'+source[start:end])


class TurnCycleTests(unittest.TestCase):
    def test_initial_plough_preparation_is_deferred_to_envelope_controller(self):
        test_envelope_initial_entry.InitialEntryTests.setUp(self)
        for name in ('createRowStarter','startAlignmentTurn'):
            method(self.lua,'AIDriveStrategyFieldWorkCourse',name)
        self.lua.execute('''
local f=initialFixture();local s=f.strategy;local prepared=0
s.prepareForFieldWork=function() prepared=prepared+1 end
s.haveRotatablePlow=function() return true end
s.getTurnEndSideOffset=function() return 0 end
s.createRowStarter=AIDriveStrategyFieldWorkCourse.createRowStarter
AIDriveStrategyFieldWorkCourse.startAlignmentTurn(s,s.fieldWorkCourse,1,f.starter:getCourse(),1)
assert(prepared==0 and s.workStarter.deferPreparation)
assert(s.workStarter:prepareInitialPosition() and s.workStarter.initialNeedsWorkingGeometry)
''')

    def test_short_row_handover_uses_normal_plough_offset_without_changing_state(self):
        test_envelope_initial_entry.InitialEntryTests.setUp(self)
        method(self.lua,'AIDriveStrategyFieldWorkCourse','resumeFieldworkAfterTurn')
        method(self.lua,'AIDriveStrategyPlowCourse','getTurnEndSideOffset')
        self.lua.execute('''
local f=initialFixture();local s=f.strategy;local checked=0
s.isWorking=function() return false end
s.haveRotatablePlow=function() return true end
s.updatePlowOffset=function() s.aiOffsetX=-.458 end
s.debug=function() end;s.startWaitingForLower=function() end;s.lowerImplements=function() end
s.startCourse=function() end
s.fieldWorkCourse.getNextFwdWaypointIxFromVehiclePosition=function() return 2,true end
local get=AIDriveStrategyPlowCourse.getTurnEndSideOffset
assert(get(s,false)==0)
s.startTurn=function(_,ix)
    assert(ix==2 and s.envelopePendingRowTurn)
    assert(math.abs(get(s,false)+.916)<1e-9)
    assert(get(s,true)==0,'headland corner must retain normal side')
    checked=checked+1
end
AIDriveStrategyFieldWorkCourse.resumeFieldworkAfterTurn(s,1)
assert(checked==1 and not s.envelopePendingRowTurn and not s:isWorking())
''')

    def test_deferred_unfolding_waits_for_confirmed_straight_and_permission(self):
        test_envelope_deployment.DeploymentTests.setUp(self)
        self.lua.execute('''
local p,f=deploymentFixture(1);local t=f.turn;local prepared=0;local allowed=false
t.geometry=assert(EnvelopeTurnGeometry.capture(t));local goal=t.geometry.goal
t.result={path={{x=goal.x,z=goal.z-25},{x=goal.x,z=goal.z}}}
t.ppc.getCurrentWaypointIx=function() return 1 end;t.deferPreparation=true
f.strategy.prepareForFieldWork=function() prepared=prepared+1 end
f.controller.getIsPlowRotationAllowed=function() return allowed end
f:setPose({x=goal.x,z=goal.z-20,t=math.rad(20),phi=0})
t:checkWorkingPosition();assert(prepared==0)
f:setPose({x=goal.x,z=goal.z-20,t=0,phi=0})
assert(not t:checkWorkingPosition() and prepared==1 and f.object.sideCommands==0)
for i=1,10 do assert(not t:checkWorkingPosition() and prepared==1 and f.object.sideCommands==0) end
allowed=true;t:checkWorkingPosition()
assert(prepared==1 and f.object.sideCommands==1 and f.object.lowerCount==0)
''')

    def test_footprint_transform_matches_marker_transform(self):
        test_envelope_initial_entry.InitialEntryTests.setUp(self)
        self.lua.execute('''
local E=EnvelopeTurnPlanner;local p=envelopeFixture(6,11,2,4,15,25,1,54)
for t=-3,3,.2 do
    local s={x=11,z=-15,t=t,phi=t+.4};local ix=0
    p.contains=function(x,z)
        ix=ix+1;local q=E.marker(p,s,p.footprint[ix])
        assert(math.abs(q.x-x)<1e-10 and math.abs(q.z-z)<1e-10);return true
    end
    assert(E.checkFootprint(p,s) and ix==#p.footprint)
end
''')


if __name__=='__main__': unittest.main()
