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
                     'startCourseToWorkStart', 'getDriveData', 'startConnectingPath',
                     'updateHarvesterConnectorEntry', 'onHarvesterConnectorEntryDone',
                     'checkHarvesterConnectorEntry', 'advanceHarvesterConnectorValidation'):
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
        actual=(ROOT/FIELDWORK).read_text(encoding='utf-8')
        actual=re.sub(r' *-- BEGIN authorised harvester connector entry\n.*? *-- END authorised harvester connector entry\n', '', actual, flags=re.S)
        self.assertEqual(actual,expected.replace('\r\n','\n'))

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

    def entry_fixture(self):
        self.lua.execute("""
            CpUtil.getDefaultCollisionFlags=function() return 334339 end
            CollisionFlag={TERRAIN_DELTA=0}
            require('HybridAStar'); require('PathfinderContext')
            PathfinderUtil.hasFruit=function() return false,0 end
            u.settings=v:getCpSettings()
            u.settings.avoidFruit={getValue=function() return true end}
            g_time=100
            local points={}
            for z=-40,120,2 do table.insert(points,{x=0,z=z}) end
            saved=Course(v,points,true)
            u.connectorEntry={course=saved,context=PathfinderContext(v),node={},zOffset=0,
                nextAttempt=g_time,index=1,candidates={15,25,35}}
            pc={active=false,calls=0,reset=function() end,isActive=function(self) return self.active end,
                registerListeners=function(self,owner,callback) self.owner=owner; self.callback=callback end,
                findPathToWaypoint=function(self,ctx,c,ix,x,z,retries)
                    self.calls=self.calls+1; self.kind='local'; self.ctx=ctx; self.ix=ix; self.active=true
                    assert(c==saved and x==0 and z==0 and retries==0)
                end,
                findPathToNode=function(self,ctx,node,x,z,retries)
                    self.calls=self.calls+1; self.kind='full'; self.active=true; assert(retries==0)
                end}
            u.pathfinderController=pc
            function finishSearch(ok,course)
                pc.active=false
                pc.callback(pc.owner,pc,ok,course)
            end
            function drainValidation()
                local n=0
                while u.connectorEntry and u.connectorEntry.validation do
                    u:updateHarvesterConnectorEntry(); n=n+1; assert(n<500)
                end
                return n
            end
        """)

    def test_local_join_precedes_full_search_and_keeps_collision_defaults(self):
        self.entry_fixture()
        self.lua.execute("""
            u:updateHarvesterConnectorEntry()
            assert(pc.calls==1 and pc.kind=='local' and pc.ix==15)
            assert(pc.ctx._allowReverse==false and pc.ctx._mustBeAccurate)
            assert(pc.ctx._maxIterations==3000 and pc.ctx._collisionMask~=0)
            u:updateHarvesterConnectorEntry(); assert(pc.calls==1 and installed==0)
        """)

    def test_failed_entries_then_full_failure_hold_without_raw_fallback(self):
        self.entry_fixture()
        self.lua.execute("""
            for i=1,4 do
                u:updateHarvesterConnectorEntry(); assert(pc.calls==i)
                assert(pc.kind==(i==4 and 'full' or 'local'))
                finishSearch(false,nil)
                u:updateHarvesterConnectorEntry(); assert(pc.calls==i and installed==0)
                g_time=g_time+1000
            end
            u:updateHarvesterConnectorEntry()
            assert(u.connectorEntry.nextAttempt==g_time+5000 and installed==0)
            g_time=g_time+4999; u:updateHarvesterConnectorEntry(); assert(pc.calls==4)
            g_time=g_time+1; u:updateHarvesterConnectorEntry(); assert(pc.calls==5 and pc.kind=='local')
        """)

    def test_validated_entry_preserves_suffix_and_native_straight_entry(self):
        self.entry_fixture()
        self.lua.execute("""
            checks=0
            PathfinderConstraints=function() return {isValidNode=function() checks=checks+1; return true end} end
            u:updateHarvesterConnectorEntry()
            local goal=PathfinderUtil.getWaypointAsState3D(saved:getWaypoint(pc.ix),0,0)
            local path=PathfinderUtil.findAnalyticPathFromStartToGoal(DubinsSolver(),State3D(14.7,40,math.pi/2),goal,9)
            finishSearch(true,Course.createFromAnalyticPath(v,path,true))
            assert(installed==0 and u.connectorEntry.validation)
            local before=checks; u:updateHarvesterConnectorEntry(); assert(checks-before<=20)
            assert(drainValidation()>1)
            assertStarted(); assert(not u.connectorEntry)
            assert(saved:getNumberOfWaypoints()==81)
            local found=false
            for _,wp in ipairs(u.course:getAllWaypoints()) do if wp.x==0 and wp.z==120 then found=true end end
            assert(found and checks>40)
        """)

    def test_header_collision_rejects_local_entry_without_starting_or_immediate_callback_retry(self):
        self.entry_fixture()
        self.lua.execute("""
            PathfinderConstraints=function() return {isValidNode=function() return false end} end
            u:updateHarvesterConnectorEntry()
            local goal=PathfinderUtil.getWaypointAsState3D(saved:getWaypoint(pc.ix),0,0)
            local path=PathfinderUtil.findAnalyticPathFromStartToGoal(DubinsSolver(),State3D(14.7,40,math.pi/2),goal,9)
            finishSearch(true,Course.createFromAnalyticPath(v,path,true))
            assert(pc.calls==1)
            drainValidation()
            assert(installed==0 and not u.connectorEntry.validation and pc.calls==1)
            g_time=g_time+1000; u:updateHarvesterConnectorEntry(); assert(pc.calls==2)
        """)

    def test_full_search_success_retains_native_startrowonly(self):
        self.entry_fixture()
        self.lua.execute("""
            u.connectorEntry.index=4
            u:updateHarvesterConnectorEntry(); assert(pc.kind=='full')
            finishSearch(true,route)
            assertStarted(); assert(not u.connectorEntry)
        """)

    def test_recorded_opposite_heading_search_uses_native_header_collision_checks(self):
        self.entry_fixture()
        self.lua.execute((SOURCE/'tools/unloader-queue/connector-search-fixture.lua').read_text())
        self.lua.execute("""
            local G=CpUnloaderQueueGeometry
            -- Stationary verge tractor/trailer: positions are representative,
            -- not a complete replay of GIANTS physics or the map's scenery.
            obstacles={G.rectangle({x=-451,z=-329.2,heading=0},{width=3,length=6},0),
                G.rectangle({x=-451,z=-337,heading=0},{width=3,length=9},0)}
            local frames=driveEntrySearch()
            assertStarted(); assert(probeCount>20 and frames<120)
            assert(saved:getNumberOfWaypoints()==12)
        """)

    def test_short_connector_schedules_a_real_join_instead_of_empty_retries(self):
        self.entry_fixture()
        self.lua.execute("""
            local original=RowStartOrFinishContext
            RowStartOrFinishContext=function() return {getTurnEndNodeAndOffsets=function() return {},0 end} end
            u.getFrontAndBackMarkers=function() return 4,-6 end
            u.getWorkWidth=function() return 15.2 end
            u.getTurnEndSideOffset=function() return 0 end
            u.getTurnEndForwardOffset=function() return 0 end
            u.getAllowReversePathfinding=function() return true end
            local points={{x=0,z=0},{x=0,z=2},{x=0,z=4},{x=0,z=6}}
            u.fieldWorkCourse=Course(v,points,true)
            u.fieldWorkCourse.isOnConnectingPath=function(_,ix) return ix<4 end
            local started=0
            u.updateHarvesterConnectorEntry=function(self)
                started=started+1
                assert(#self.connectorEntry.candidates==1 and self.connectorEntry.candidates[1]==2)
            end
            u:startConnectingPath(0)
            assert(started==1 and u.state==u.states.WAITING_FOR_PATHFINDER)
            RowStartOrFinishContext=original
        """)

    def test_validator_uses_short_angle_across_zero(self):
        self.entry_fixture()
        self.lua.execute("""
            local c=Course(v,{{x=0,z=0},{x=1,z=0},{x=2,z=0}},true)
            c:getWaypoint(1).angle=89
            c:getWaypoint(2).angle=91
            local count=0
            local entry={joinContext=PathfinderContext(v),validation={course=c,validationEnd=2,ix=1,sample=0,
                constraints={isValidNode=function(_,node)
                    count=count+1
                    assert(math.abs(math.atan2(math.sin(node.t),math.cos(node.t)))<math.rad(2))
                    return true
                end}}}
            local done,path=u:advanceHarvesterConnectorValidation(entry)
            assert(done and path==c and count<=5)
        """)

    def test_header_only_obstacle_is_rejected_by_real_native_detector_at_entry_start(self):
        self.entry_fixture()
        self.lua.execute((SOURCE/'tools/unloader-queue/connector-search-fixture.lua').read_text())
        self.lua.execute("""
            local node=v:getAIDirectionNode()
            local ox,_,oz=localToWorld(node,7,0,0)
            obstacles={CpUnloaderQueueGeometry.rectangle({x=ox,z=oz,heading=0},{width=1,length=1},0)}
            local entry=u.connectorEntry
            entry.joinIx=10; entry.joinContext=PathfinderContext(v)
            local start=PathfinderUtil.getVehiclePositionAsState3D(v)
            local goal=PathfinderUtil.getWaypointAsState3D(saved:getWaypoint(10),0,0)
            local path=PathfinderUtil.findAnalyticPathFromStartToGoal(DubinsSolver(),start,goal,4.7)
            entry.validation=u:checkHarvesterConnectorEntry(Course.createFromAnalyticPath(v,path,true),entry)
            assert(entry.validation)
            local done,result=u:advanceHarvesterConnectorValidation(entry)
            assert(done and not result and installed==0 and probeCount>0)
        """)

    def test_seam_is_checked_with_the_final_bending_suffix_heading(self):
        self.entry_fixture()
        self.lua.execute("""
            local seen={}
            PathfinderConstraints=function() return {isValidNode=function(_,n)
                seen[#seen+1]={x=n.x,y=n.y,t=n.t}; return true end} end
            saved:getWaypoint(17).x=2
            saved:enrichWaypointData()
            u:updateHarvesterConnectorEntry()
            local entry=u.connectorEntry
            local goal=PathfinderUtil.getWaypointAsState3D(saved:getWaypoint(pc.ix),0,0)
            local path=PathfinderUtil.findAnalyticPathFromStartToGoal(DubinsSolver(),State3D(14.7,40,math.pi/2),goal,9)
            finishSearch(true,Course.createFromAnalyticPath(v,path,true))
            local validation=entry.validation
            assert(validation)
            local expected=PathfinderUtil.getWaypointAsState3D(validation.course:getWaypoint(validation.validationEnd),0,0)
            drainValidation()
            local last=seen[#seen]
            assert(math.abs(math.atan2(math.sin(last.t-expected.t),math.cos(last.t-expected.t)))<.0001)
            assert(math.abs(last.x-expected.x)<.0001 and math.abs(last.y-expected.y)<.0001)
        """)

    def test_local_entry_does_not_cut_crop_and_preserves_avoid_fruit_setting(self):
        self.entry_fixture()
        self.lua.execute("""
            PathfinderUtil.hasFruit=function() return true,100 end
            local c=Course(v,{{x=0,z=0},{x=0,z=2}},true)
            local ctx=PathfinderContext(v):ignoreFruit(false)
            local checks=0
            local function entry() return {joinContext=ctx,validation={course=c,validationEnd=2,ix=1,sample=0,
                constraints={isValidNode=function() checks=checks+1; return true end}}} end
            local done,result=u:advanceHarvesterConnectorValidation(entry())
            assert(done and not result and checks==0)
            ctx:ignoreFruit(true)
            done,result=u:advanceHarvesterConnectorValidation(entry())
            assert(done and result==c and checks>0)
        """)


if __name__=='__main__': unittest.main()
