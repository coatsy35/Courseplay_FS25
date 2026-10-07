"""Native connector ownership and fallback dispatch, with real Course/StartRowOnly."""
from pathlib import Path
import re
import subprocess
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
BASE = '8b707fa907c236b9b1b98a5608267975c3c764d3'
FIELDWORK = 'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua'


class NativeConnectorTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT=ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute((SOURCE/'tools/straight-entry/preparation-fixture.lua').read_text())
        self.lua.execute('NativeFieldwork={}; NativeFieldwork.__index=NativeFieldwork')
        text=(ROOT/FIELDWORK).read_text(encoding='utf-8')
        for name in ('onPathfindingDoneToConnectingPathEnd', 'onPathfindingFailedToConnectingPathEnd',
                     'startCourseToWorkStart', 'getDriveData'):
            method=text.split('function AIDriveStrategyFieldWorkCourse:'+name,1)[1].split('\nend',1)[0]
            self.lua.execute('function NativeFieldwork:'+name+method+'\nend')
        self.lua.execute('''
            f=preparationFixture(20,false,false)
            v=f.vehicle; v.spec_combine={}; v.size={width=3.5}
            AIUtil.getSteeringParameters=function() return 9,0 end
            AIUtil.getTurningRadius=function() return 9 end
            context=setmetatable(f.turn.turnContext,RowStartOrFinishContext)
            context.turnStartWpIx=context.turnEndWpIx; context.workWidth=15.2
            context.workStartNode={x=0,z=0,t=0}; context.vehicleAtTurnEndNode={x=0,z=0,t=0}
            context.frontMarkerDistance=4; context.backMarkerDistance=-6
            u=setmetatable(f.strategy,NativeFieldwork)
            u.vehicle=v; u.ppc=f.turn.ppc; u.turnContext=context
            u.states={WAITING_FOR_PATHFINDER={},DRIVING_TO_WORK_START_WAYPOINT={},WORKING={}}
            u.state=u.states.WAITING_FOR_PATHFINDER
            u.debug=function() end
            u.raiseImplements=function(self) self.raised=true end
            u.ppc.setShortLookaheadDistance=function(self) self.short=true end
            installed=0
            u.startCourse=function(self,course,ix) installed=installed+1; self.course=course; assert(ix==1) end
            v.stopCurrentAIJob=function() error('native connector must not stop the worker here') end
            overlapBox=function() error('no added full-route clearance veto is allowed') end
            route=Course(v,{{x=0,z=-43},{x=0,z=-42},{x=0,z=-41}},true)
            fallback=Course(v,{{x=0,z=-43},{x=2,z=-42},{x=0,z=-41}},true)
            u.workStarterCourse=fallback
            function assertStarted()
                assert(installed==1 and u.state==u.states.DRIVING_TO_WORK_START_WAYPOINT)
                assert(u.raised and u.ppc.short and u.course==u.workStarter:getCourse())
            end
        ''')

    def test_native_strategy_is_byte_equivalent_to_pinned_base(self):
        expected=subprocess.check_output(['git','show',f'{BASE}:{FIELDWORK}'],cwd=SOURCE).decode()
        self.assertEqual((ROOT/FIELDWORK).read_text(encoding='utf-8'),expected.replace('\r\n','\n'))

    def test_removed_gate_cannot_load_or_override_native_connectors(self):
        self.assertFalse((ROOT/'scripts/ai/CpHarvesterRouteClearance.lua').exists())
        self.assertNotIn('CpHarvesterRouteClearance',(ROOT/'modDesc.xml').read_text(encoding='utf-8'))
        methods=('startConnectingPath','onPathfindingDoneToConnectingPathEnd',
                 'onPathfindingFailedToConnectingPathEnd','startCourseToWorkStart')
        paths=[ROOT/'scripts/ai/strategies/AIDriveStrategyCombineCourse.lua']
        paths.extend((ROOT/'scripts/ai').glob('CpUnloaderQueue*.lua'))
        for path in paths:
            text=path.read_text(encoding='utf-8')
            for method in methods:
                self.assertIsNone(re.search(r'function\s+[\w.]+[:.]'+method+r'\s*\(',text),str(path))

    def test_successful_native_path_starts_without_additional_veto(self):
        self.lua.execute('''
            local count=route:getNumberOfWaypoints()
            u:onPathfindingDoneToConnectingPathEnd(nil,true,route,false)
            assertStarted(); assert(u.course==route and route:getNumberOfWaypoints()>count)
            assert(fallback:getNumberOfWaypoints()==3)
        ''')

    def test_exhausted_search_uses_native_fallback_instead_of_stopping_worker(self):
        self.lua.execute('''
            u:onPathfindingDoneToConnectingPathEnd(nil,false,nil,false)
            assertStarted(); assert(u.course==fallback)
        ''')

    def test_invalid_goal_retains_native_fallback(self):
        self.lua.execute('''
            u:onPathfindingDoneToConnectingPathEnd(nil,false,nil,true)
            assertStarted(); assert(u.course==fallback)
        ''')

    def test_last_retry_callback_retains_native_fallback(self):
        self.lua.execute('''
            u:onPathfindingFailedToConnectingPathEnd(nil,{},true,1)
            assertStarted(); assert(u.course==fallback)
        ''')

    def test_first_failure_preserves_native_retry_policy(self):
        self.lua.execute('''
            local changed,retried=false,false
            local context={collisionMask=function(_,mask) assert(mask==0); changed=true end}
            local controller={retry=function(_,c) assert(c==context); retried=true end}
            u:onPathfindingFailedToConnectingPathEnd(controller,context,false,1)
            assert(changed and retried and installed==0)
        ''')

    def test_native_search_can_penalise_crop_without_making_it_impassable(self):
        self.lua.execute('NativeConstraints={}; NativeConstraints.__index=NativeConstraints')
        text=(ROOT/'scripts/pathfinder/PathfinderConstraints.lua').read_text(encoding='utf-8')
        for name in ('resetCounts','getNodePenalty','calculatePreferredPathPenalty'):
            method=text.split('function PathfinderConstraints:'+name,1)[1].split('\nend',1)[0]
            self.lua.execute('function NativeConstraints:'+name+method+'\nend')
        self.lua.execute('''
            local c=setmetatable({maxFruitPercent=50,offFieldPenalty=7.5,penaltyFactor=1},NativeConstraints)
            c:resetCounts()
            CpFieldUtil={isOnField=function() return true end}
            PathfinderUtil.isWorldPositionOwned=function() return true end
            local fruit=false
            PathfinderUtil.hasFruit=function() return fruit,fruit and 100 or 0 end
            assert(c:getNodePenalty({x=0,y=0})==0)
            fruit=true
            local cost=c:getNodePenalty({x=0,y=0})
            assert(cost>0 and cost<math.huge and c.fruitPenaltyNodeCount==1)
        ''')

    def test_native_connector_keeps_traffic_and_convoy_stops_then_resumes(self):
        self.lua.execute('''
            u:onPathfindingDoneToConnectingPathEnd(nil,false,nil,false)
            u.updateFieldworkOffset=function() end
            u.updateLowFrequencyImplementControllers=function() end
            Markers={refreshMarkerNodes=function() end}
            u.ppc.isReversing=function() return false end
            u.ppc.getGoalPointPosition=function() return 0,0,10 end
            u.settings={fieldSpeed={getValue=function() return 15 end}}
            u.workStarter.getDriveData=function() return nil,nil,nil,15 end
            u.setMaxSpeed=function(self,speed) self.maxSpeed=math.min(self.maxSpeed,speed) end
            u.setAITarget=function() end; u.limitSpeed=function() end
            local trafficStop,convoyStop,proximityCalls,convoyCalls=true,false,0,0
            u.checkProximitySensors=function(self,forwards)
                assert(forwards); proximityCalls=proximityCalls+1
                if trafficStop then self:setMaxSpeed(0) end
            end
            u.checkDistanceToOtherFieldWorkers=function(self)
                convoyCalls=convoyCalls+1
                if convoyStop then self:setMaxSpeed(0) end
            end
            for i=1,3 do
                u.maxSpeed=math.huge
                local _,_,_,speed=u:getDriveData(16,0,0,0)
                assert(speed==(i==3 and 15 or 0))
                trafficStop=false; convoyStop=i==1
            end
            assert(proximityCalls==3 and convoyCalls==3)
        ''')


if __name__=='__main__': unittest.main()
