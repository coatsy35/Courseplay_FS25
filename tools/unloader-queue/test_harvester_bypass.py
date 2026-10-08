"""Parked-trailer recovery through production turn lifecycle and queue hooks."""
from pathlib import Path
import sys
import unittest
from lupa.lua52 import LuaRuntime

SOURCE=Path(__file__).resolve().parents[2]
ROOT=Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0,str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT=ROOT


class HarvesterBypassTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().ROOT=ROOT.as_posix()
        self.lua.execute((SOURCE/'tools/straight-entry/engine-boundary.lua').read_text())
        self.lua.execute('AIDriveStrategyCourse={}; AIDriveStrategyFieldWorkCourse={}')
        for name in ('AIDriveStrategyUnloadCombine','AIDriveStrategyCombineCourse'):
            self.lua.execute((ROOT/f'scripts/ai/strategies/{name}.lua').read_text())
        source=(ROOT/'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua').read_text()
        start=source.index('function AIDriveStrategyFieldWorkCourse:startRecoveryTurn(')
        end=source.index('\nend',start)+4
        self.lua.execute(source[start:end])
        runtime.load_queue(self.lua)
        self.lua.execute('''
            Q=CpUnloaderQueue; g_currentMission.time=10000
            local setting=function(v) return {getValue=function() return v end} end
            settings={turnSpeed=setting(10),reverseSpeed=setting(8),fieldSpeed=setting(15)}
            hv={spec_combine={},size={width=3.5},active=true,stopped=true,
                getCpSettings=function() return settings end,getChildVehicles=function() return {} end,
                getIsCpActive=function(self) return self.active end,
                getAIDirectionNode=function() return {x=0,z=0,t=0} end,
                stopCurrentAIJob=function() stopped=true end}
            tv={stopped=true,getIsCpActive=function() return true end}
            AIUtil.isStopped=function(v) return v.stopped end
            AIUtil.getSteeringParameters=function() return nil,0 end
            AIUtil.hasChainedAttachments=function() return false end
            AIUtil.getDirectionNodeToReverserNodeOffset=function() return 0 end
            AIMessageCpErrorNoPathFound={new=function() return {} end}
            u=setmetatable({vehicle=tv,states=AIDriveStrategyUnloadCombine.myStates},AIDriveStrategyUnloadCombine)
            u.settings={fullThreshold=setting(85)}; full=false; manual=false
            u.getAllTrailersFull=function() return full end
            u.isDriveUnloadNowRequested=function() return manual end
            u.setMaxSpeed=function(self,speed) self.speed=speed end; u.debug=function() end
            tv.getCpDriveStrategy=function() return u end
            c=setmetatable({vehicle=hv,states={TURNING={},WORKING={}}},AIDriveStrategyCombineCourse)
            c.state=c.states.TURNING; c.turningRadius=9; c.workWidth=15.2
            c.debug=function() end; c.settings=settings
            c.raiseImplements=function() raised=true end
            c.raiseControllerEvent=function() end
            c.raiseControllerEventWithLambda=function(_,event,fn) fn(true) end
            c.getLoweringDurationMs=function() return 1000 end
            c.getFrontAndBackMarkers=function() return 4,-6 end
            c.getAllowReversePathfinding=function() return true end
            c.getWorkWidth=function() return 15.2 end
            c.isTurnOnFieldActive=function() return true end
            c.setPathfindingDoneCallback=function(self,owner,callback) self.callbackOwner=owner; self.callback=callback end
            c.startRecoveryTurn=AIDriveStrategyFieldWorkCourse.startRecoveryTurn
            c.ppc={restorePreviouslyRegisteredListeners=function() restored=true end,
                registerListeners=function() end,setCourse=function(_,course) installed=course end,
                initialize=function(_,ix) assert(ix==1) end}
            c.proximityController={unregisterBlockingObjectListener=function() end,
                registerBlockingObjectListener=function(self,owner,fn) self.owner=owner; self.callback=fn end}
            target={x=20,z=30,t=0}
            context={turnEndWpIx=953,setStraightEntryDistance=function() end,
                getTurnEndNodeAndOffsets=function() return target,-4 end,
                getBoundaryId=function() return 'F' end,
                appendPathfinderEndingTurnCourse=function() return 0 end}
            c.turnContext=context; c.course=Course(hv,{{x=0,z=0},{x=0,z=10}},false)
            original=c.course
            old=setmetatable({vehicle=hv,driveStrategy=c,turnContext=context,ppc=c.ppc,
                proximityController=c.proximityController,states={TURNING={}},turningRadius=9},CourseTurn)
            old.state=old.states.TURNING; c.aiTurn=old
            calls=0
            productionGenerate=Q.generateHarvesterBypass
            Q.generateHarvesterBypass=function(self)
                self.queueBypassConstraints={isValidNode=function() return true end}
                return CourseTurn.generatePathfinderTurn(self,false)
            end
            nativeTurnSearch=PathfinderUtil.findPathForTurn
            PathfinderUtil.findPathForTurn=function(...)
                args={...}; calls=calls+1; return {isActive=function() return false end},{done=false}
            end
            Q.take(u,'prepare')
        ''')

    def test_vehicle_block_callback_starts_native_recovery_to_unchanged_target(self):
        self.lua.execute('''
            c:onBlockingVehicle(tv,false)
            assert(c.aiTurn~=old and c.aiTurn.turnContext==context and c.course==original)
            assert(raised and restored and c.aiTurn.state==c.aiTurn.states.PREPARING_RECOVERY)
            assert(Q.holdForHarvesterBypass(u) and u.speed==0)
            c.aiTurn:getDriveData(33)
            assert(calls==1 and args[1]==hv and args[3]==target and args[4]==-4)
            assert(args[5]==9 and args[6] and args[8]==15.2 and args[9]==-6 and args[10])
            assert(c.callbackOwner==c.aiTurn and c.callback==c.aiTurn.onPathfindingDone)
            assert(c.proximityController.callback==c.aiTurn.onBlocked)
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(installed==c.aiTurn.turnCourse and c.aiTurn.state==c.aiTurn.states.TURNING)
            assert(c.course==original and context.turnEndWpIx==953 and not stopped)
        ''')

    def test_inactive_old_pathfinder_does_not_disable_bypass(self):
        self.lua.execute('c.pathfinder={isActive=function() return false end}; assert(Q.tryHarvesterBypass(c,tv,false))')

    def test_real_native_planner_routes_header_around_parked_rig(self):
        self.lua.execute('''
            CpUtil.getDefaultCollisionFlags=function() return 334339 end
            CollisionFlag={TERRAIN_DELTA=0}
            require('HybridAStar'); require('PathfinderContext')
        ''')
        fixture=(SOURCE/'tools/unloader-queue/connector-search-fixture.lua').read_text()
        self.lua.execute(fixture.split('v.getRootVehicle=',1)[0])
        self.lua.execute('''
            local origin={x=0,z=0,t=0}
            hv.getAIDirectionNode=function() return origin end
            hv.getRootVehicle=function(self) return self end
            hv.getCpSettings=function() return settings end
            settings.penaltyFactor={getValue=function() return 1 end}
            settings.useJps={getValue=function() return true end}
            CpFieldUtil.getFieldNumUnderVehicle=function() return 11 end
            target.x=0; target.z=80; target.t=0
            local G=CpUnloaderQueueGeometry
            obstacles={G.rectangle({x=0,z=40,heading=0},{width=3.5,length=18},0)}
            local validation=PathfinderConstraints(PathfinderContext(hv))
            assert(not validation:isValidNode(State3D(0,-40,CpMathUtil.angleFromGame(0)),false,true),'fixture must detect trailer collision')
            Q.generateHarvesterBypass=productionGenerate
            PathfinderUtil.findPathForTurn=nativeTurnSearch
            assert(Q.tryHarvesterBypass(c,tv,false))
            c.aiTurn:getDriveData(33)
            for i=1,2000 do
                if installed or stopped then break end
                if c.pathfinder and c.pathfinder:isActive() then
                    local result=c.pathfinder:resume()
                    if result.done then c.callback(c.callbackOwner,result.path) end
                end
            end
            assert(installed and not stopped,'native planner must find a route around the rig')
            local outside=false
            for i=1,installed:getNumberOfWaypoints() do
                local x,_,z=installed:getWaypointPosition(i)
                local box=G.rectangle({x=x,z=z,heading=installed:getWaypointYRotation(i)},
                    {width=16.6,length=13},0)
                assert(not G.overlap(box,obstacles[1]),string.format('header intersects at %d x%.2f z%.2f yaw%.2f reverse%s',i,x,z,installed:getWaypointYRotation(i),tostring(installed:isReverseAt(i))))
                if math.abs(x)>11 then outside=true end
            end
            assert(outside and probeCount>10 and c.course==original and context.turnEndWpIx==953)
        ''')

    def test_live_pathfinder_keeps_ownership(self):
        self.lua.execute('c.pathfinder={isActive=function() return true end}; assert(not Q.tryHarvesterBypass(c,tv,false)); assert(c.aiTurn==old)')

    def test_failed_search_never_uses_calculated_turn_or_skips_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.generateCalculatedTurn=function() error('unsafe fallback') end
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            recovery:getDriveData(33); c.callback(c.callbackOwner,nil)
            assert(stopped and not installed and not u.queueData.bypass and not c.queueBypass)
        ''')

    def test_recovery_block_listener_does_not_skip_row(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery.resumeFieldworkAfterTurn=function() error('skipped blocked corner') end
            c.proximityController.callback(recovery); assert(not stopped)
            recovery.state=recovery.states.TURNING
            c.proximityController.callback(recovery); assert(stopped and not c.queueBypass)
        ''')

    def test_final_adjusted_course_is_rejected_if_it_intersects_an_obstacle(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); local recovery=c.aiTurn
            recovery:getDriveData(33)
            local checks=0
            recovery.queueBypassConstraints.isValidNode=function(_,node)
                checks=checks+1; return node.x<5
            end
            c.callback(c.callbackOwner,{{x=0,y=0,t=0},{x=10,y=-10,t=0},{x=20,y=-30,t=0}})
            assert(stopped and checks>1 and not c.queueBypass and context.turnEndWpIx==953)
        ''')

    def test_moving_full_assigned_and_native_departing_trailers_do_not_get_held(self):
        for condition in ('tv.stopped=false','hv.stopped=false','full=true','manual=true',
                          'u.combineToUnload=hv','u.queueData.nativeDeparture=true'):
            with self.subTest(condition=condition):
                self.setUp()
                self.lua.execute(condition+'; assert(not Q.tryHarvesterBypass(c,tv,false)); assert(c.aiTurn==old)')

    def test_special_callback_turn_reverse_block_and_working_row_are_excluded(self):
        self.lua.execute('''
            assert(not Q.tryHarvesterBypass(c,tv,true))
            old.callbackFunction=function() end; assert(not Q.tryHarvesterBypass(c,tv,false))
            old.callbackFunction=nil; c.state=c.states.WORKING; assert(not Q.tryHarvesterBypass(c,tv,false))
        ''')

    def test_other_harvester_yield_request_is_not_overridden(self):
        self.lua.execute('u.queueData.yieldRequests={[{}]={}}; assert(not Q.tryHarvesterBypass(c,tv,false))')

    def test_success_stop_and_fullness_release_both_hold_references(self):
        for change in ('c.state=c.states.WORKING','hv.active=false','full=true','manual=true'):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); '+change+
                                 '; assert(not Q.holdForHarvesterBypass(u)); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_cancel_invalidates_both_hold_references(self):
        self.lua.execute('assert(Q.tryHarvesterBypass(c,tv,false)); Q.cancel(u); assert(not c.queueBypass and not u.queueData.bypass)')

    def test_timed_out_recovery_stops_before_releasing_parked_trailer(self):
        self.lua.execute('''
            assert(Q.tryHarvesterBypass(c,tv,false)); g_currentMission.time=130001
            assert(not Q.holdForHarvesterBypass(u)); assert(stopped and not c.queueBypass)
        ''')

    def test_failed_recovery_creation_does_not_change_queue_state(self):
        self.lua.execute('''
            old.startRecoveryTurn=function() end; local state=u.state
            assert(not Q.tryHarvesterBypass(c,tv,false)); assert(u.state==state and not u.queueData.bypass)
        ''')


if __name__=='__main__': unittest.main()
