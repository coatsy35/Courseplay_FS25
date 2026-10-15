"""3038: departing rigs clear failed row turns, then resume native marker travel.

Production queue search, articulated geometry, turn wait and native departure
methods run with planar GIANTS queries. This is not a driving-physics replay.
"""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
import test_harvester_bypass as bypass
runtime.ROOT = ROOT
bypass.ROOT = ROOT


class DepartureTurnTests(unittest.TestCase):
    def setUp(self):
        bypass.HarvesterBypassTests.setUp(self)
        bypass.HarvesterBypassTests.travel_fixture(self, trailer_x=7)
        self.lua.execute('''
            H=HeadlandLoopGeometry
            full=true; data=u.queueData; data.operation=nil; data.nativeDeparture=true
            u.state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            u.course=Course(tv,{{x=7,z=40},{x=60,z=40}},true); originalExit=u.course
            u.invertedStartPositionMarkerNode={x=90,z=60,t=math.pi/2}
            u.invertedGoalPositionOffset=4.5
            u.isBeingHeld=function() return false end
            u.getFieldSpeed=function() return 15 end
            u.getMaxFruitPercent=function() return 10 end
            u.getAllowReversePathfinding=function() return true end
            u.settings.reverseSpeed=settings.reverseSpeed
            u.startCourse=function(self,course,ix) assert(ix==1); self.course=course end
            u.setNewState=function(self,state) self.state=state end
            u.ppc={getRelevantWaypointIx=function() return 1 end,
                getReverserNode=function() return trailer.steeringAxleNode end}
            Q.refresh=function() end -- fleet discovery is independent of the incident
            g_currentMission.vehicleSystem={vehicles={hv,tv}}
            CpFieldUtil={getFieldNumUnderVehicle=function() return 11 end}
            PathfinderUtil.getMaxIterationsForFieldPolygon=function() return 12345 end
            PathfinderContext=setmetatable({defaultOffFieldPenalty=7},{__call=function()
                local context={}
                for _,key in ipairs({'maxFruitPercent','offFieldPenalty','useFieldNum','allowReverse','maxIterations'}) do
                    context[key]=function(self,value) self[key..'Value']=value; return self end
                end
                return context
            end})
            nativeStarts=0; handovers=0
            u.onTrailerFull=function() handovers=handovers+1 end
            u.pathfinderController={registerListeners=function(self,owner,done,failed,obstacle)
                self.owner=owner; self.done=done; self.failed=failed; self.obstacle=obstacle
            end,findPathToNode=function(self,context,node,x,z,retries)
                nativeStarts=nativeStarts+1; self.context=context; self.pathfinder={native=true}
                assert(node==u.invertedStartPositionMarkerNode and x==4.5 and z==-27 and retries==3)
            end}
            function failBypass()
                assert(select(4,c:getDriveData())==0)
                c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil)
                assert(c.queueTrailerWait and not Q.owns(u))
            end
            function beginClearance()
                failBypass()
                g_currentMission.time=g_currentMission.time+10001
                assert(select(4,c:getDriveData())==0)
                assert(Q.owns(u) and data.operation=='yield','stalled native departure never received checked clearance')
                assert(data.nativeDeparture and data.operation=='yield' and not data.assignment)
                assert(nativeStarts==0 and handovers==0)
            end
            function place(x,z,t)
                tv.rootNode.x=x; tv.rootNode.z=z; tv.rootNode.t=t
                local a,b=H.math.position(tv.rootNode,0,-9.8)
                trailer.rootNode.x=a; trailer.rootNode.z=b; trailer.rootNode.t=t
            end
        ''')

    def test_persistent_conflict_starts_once_and_retains_cutoff_and_callback_ownership(self):
        self.lua.execute('''
            failBypass()
            local state=u.state
            g_currentMission.time=g_currentMission.time+9999
            c:getDriveData(); assert(u.state==state and not Q.owns(u))
            -- Finish the second unsuccessful bypass before the trigger expires.
            c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil)
            g_currentMission.time=g_currentMission.time+2
            c:getDriveData(); assert(Q.departureClearanceActive(u))
            local generation=data.generation; local request=data.yieldRequests[hv]
            Q.tick(u); local search=data.search; local path=data.path
            for i=1,30 do
                g_currentMission.time=g_currentMission.time+100
                c:getDriveData()
                u:onBlockingVehicle(hv,false); u:onBlockingVehicle(hv,true)
                u:requestToBackupForReversingCombine(hv)
                assert(Q.departureClearanceActive(u) and data.generation==generation+1)
                assert(data.search==search and data.path==path and data.yieldRequests[hv]==request)
                assert(not u:isAllowedToBeCalled() and not u:call(hv,{}))
            end
            assert(calls==2 and c.queueTrailerWait and nativeStarts==0)
        ''')

    def test_actual_movement_and_heading_progress_reset_stall_watch(self):
        for motion in ('place(tv.rootNode.x+.6,40,0)', 'place(7,40,tv.rootNode.t+math.rad(6))'):
            self.setUp()
            self.lua.execute('failBypass()')
            for _ in range(4):
                self.lua.execute('g_currentMission.time=g_currentMission.time+9000; '+motion+'''
                    c:getDriveData()
                    assert(not Q.owns(u) and nativeStarts==0)
                    if c.queueBypass then c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil) end
                ''')

    def test_live_departure_search_backup_and_other_modes_are_not_seized(self):
        for change in (
            'tv.stopped=false',
            'u.state=u.states.MOVING_BACK_WITH_TRAILER_FULL',
            'u.state=u.states.BACKING_UP_FOR_REVERSING_COMBINE',
            'u.state=u.states.WAITING_FOR_PATHFINDER; u.pathfinderController.pathfinder={}',
            'u.invertedStartPositionMarkerNode=nil',
            'u.augerWagon=true',
            'u.isBeingHeld=function() return true end',
        ):
            self.setUp()
            self.lua.execute('failBypass(); '+change+'''
                local state=u.state
                for i=1,4 do
                    g_currentMission.time=g_currentMission.time+10001
                    c:getDriveData()
                    assert(not Q.owns(u) and u.state==state and nativeStarts==0)
                    if c.queueBypass then c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil) end
                end
            ''')

    def test_checked_articulated_escape_resumes_fresh_native_route_and_handover(self):
        self.lua.execute('''
            beginClearance()
            local wait=c.queueTrailerWait
            Q.tick(u)
            -- Run the production search to completion, then integrate every
            -- articulated sample through the same live safety checks as driving.
            local path=data.path
            if not path then
                local done,reason
                for i=1,100000 do
                    done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                    if done then break end
                end
                assert(done and path,reason); Q.startRoute(data,path)
            end
            assert(path and #path>2 and u.course~=originalExit)
            local poses=W.poses(data.world.model)
            local generation=data.searchGeneration
            for i=2,#path do
                if not Q.owns(u) then break end
                poses=H.advance(data.world.model,poses,path[i])
                assert(W.clear(data.world,poses),'escape crossed crop or obstacle')
                place(path[i].x,path[i].z,path[i].t)
                trailer.rootNode.x=poses[2].x; trailer.rootNode.z=poses[2].z; trailer.rootNode.t=poses[2].t
                local ci=1
                for j,k in ipairs(data.courseToPath) do if k<=i then ci=j else break end end
                u.ppc.getRelevantWaypointIx=function() return ci end
                g_currentMission.time=g_currentMission.time+50
                Q.speed(u); assert(data.path and u.speed>0)
                Q.yieldTarget(u,true)
                -- Search and movement must not start a second combine detour.
                c:getDriveData(); assert(calls==1)
            end
            if Q.owns(u) then
                assert(Q.onLast(u) and data.parkedGoal)
                Q.yieldTarget(u,true)
            end
            g_currentMission.time=g_currentMission.time+2001
            Q.tick(u)
            assert(nativeStarts==1 and not Q.owns(u) and data.nativeDeparture)
            assert(not data.departureClearance and not data.yieldRequests and not data.search)
            assert(data.generation>generation and u.state==u.states.WAITING_FOR_PATHFINDER)
            local controller=u.pathfinderController; local ctx=controller.context
            assert(ctx.maxFruitPercentValue==10 and ctx.offFieldPenaltyValue==7 and ctx.useFieldNumValue==11)
            assert(ctx.allowReverseValue and ctx.maxIterationsValue==12345)
            assert(controller.failed==u.onPathfindingFailedToStationaryTarget)
            assert(controller.obstacle==u.onPathfindingObstacleAtStart)
            local route=Course(tv,{{x=60,z=60},{x=80,z=60},{x=90,z=60}},true)
            controller.pathfinder=nil; controller.done(u,controller,true,route,false)
            assert(u.state==u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL and u.course==route)
            Q.startRoute(data,path); assert(u.course==route) -- superseded queue result
            Q.tick(u); assert(nativeStarts==1 and handovers==0 and not Q.owns(u))
            u:onLastWaypointPassed(); assert(handovers==1)
            assert(context.turnEndWpIx==953 and not stopped)
        ''')

    def test_whole_trailer_and_two_second_dwell_required_even_below_cutoff(self):
        self.lua.execute('''
            beginClearance(); full=false -- departure intent survives a partial/manual load
            local wait=c.queueTrailerWait
            tv.rootNode.x=80
            for i=1,3 do
                g_currentMission.time=g_currentMission.time+1000
                Q.yieldTarget(u,true); c:getDriveData()
                assert(Q.departureClearanceActive(u) and c.queueTrailerWait==wait)
            end
            trailer.rootNode.x=80
            Q.yieldTarget(u,true); c:getDriveData()
            g_currentMission.time=g_currentMission.time+1999
            Q.yieldTarget(u,true); c:getDriveData(); assert(nativeStarts==0)
            g_currentMission.time=g_currentMission.time+2
            Q.yieldTarget(u,true); c:getDriveData()
            assert(nativeStarts==1 and data.nativeDeparture and not Q.owns(u))
            assert(not c.queueTrailerWait and context.turnEndWpIx==953)
        ''')

    def test_invalid_start_keeps_protections_and_replans_native_with_cooldown(self):
        for obstruction in ('collision=1', 'densityCount=30'):
            self.setUp()
            self.lua.execute('failBypass(); '+obstruction+'''
                g_currentMission.time=g_currentMission.time+10001; c:getDriveData()
                assert(nativeStarts==1 and not Q.owns(u) and not data.path)
                assert(u.state==u.states.WAITING_FOR_PATHFINDER and data.nativeDeparture)
                for i=1,100 do c:getDriveData(); Q.tick(u) end
                assert(nativeStarts==1)
            ''')

    def test_failed_escape_and_real_stall_replan_once_without_native_move_away(self):
        for fail in (False, True):
            self.setUp()
            self.lua.execute('beginClearance()')
            self.lua.execute('''
                Q.nativeMoveAway=function() error('unchecked move-away replaced checked departure') end
                data.yieldProgress=W.pose(tv.rootNode); data.yieldProgressTime=g_currentMission.time
            ''')
            if fail:
                self.lua.execute("Q.failed(data,'no safe route')")
            self.lua.execute(f'''
                g_currentMission.time=g_currentMission.time+{15001 if fail else 60001}
                assert(Q.updateYieldRecovery(u))
                assert(nativeStarts==1 and not Q.owns(u) and data.nativeDeparture)
                Q.tick(u); assert(nativeStarts==1)
            ''')

    def test_live_obstruction_cancels_escape_without_driving_through_it(self):
        self.lua.execute('''
            beginClearance(); Q.tick(u)
            local done,path,reason
            for i=1,100000 do
                done,path,reason=CpUnloaderQueueSearch.step(data.search,1)
                if done then break end
            end
            assert(done and path,reason); Q.startRoute(data,path)
            collision=1; Q.speed(u)
            assert(u.speed==0 and not data.path and Q.departureClearanceActive(u))
            assert(data.reason:find('vehicle or obstacle',1,true))
            assert(nativeStarts==0 and handovers==0)
        ''')

    def test_two_waiting_combines_do_not_reset_each_others_stall_watch(self):
        self.lua.execute('''
            failBypass()
            local otherVehicle=setmetatable({rootNode={x=60,z=0,t=0}}, {__index=hv})
            local other=setmetatable({vehicle=otherVehicle,queueBypass=nil}, {__index=c})
            otherVehicle.getCpDriveStrategy=function() return other end
            local wait=c.queueTrailerWait
            other.queueTrailerWait={turn=c.aiTurn,driver=u,area=wait.area,retryAt=g_currentMission.time+20000}
            AIDriveStrategyCombineCourse.isActiveCpCombine=function(v) return v==hv or v==otherVehicle end
            for i=1,9 do
                g_currentMission.time=g_currentMission.time+1000
                c:getDriveData(); other:getDriveData()
                if c.queueBypass then c.aiTurn:getDriveData(33); c.callback(c.callbackOwner,nil) end
                assert(not Q.owns(u))
            end
            g_currentMission.time=g_currentMission.time+1001
            c:getDriveData(); other:getDriveData()
            assert(Q.departureClearanceActive(u))
            assert(data.yieldRequests[hv] and data.yieldRequests[otherVehicle])
        ''')

    def test_second_turn_joins_existing_escape_and_cannot_release_first_early(self):
        self.lua.execute('''
            beginClearance(); Q.tick(u)
            local generation=data.generation; local search=data.search
            local otherVehicle=setmetatable({rootNode={x=60,z=0,t=0}}, {__index=hv})
            local other=setmetatable({vehicle=otherVehicle,queueTrailerWait=nil,queueBypass=nil}, {__index=c})
            otherVehicle.getCpDriveStrategy=function() return other end
            AIDriveStrategyCombineCourse.isActiveCpCombine=function(v) return v==hv or v==otherVehicle end
            local occupied=true
            local area=function() return occupied end
            other.queueTrailerWait={turn=other.aiTurn,driver=u,area=area,retryAt=0}
            other:getDriveData()
            assert(data.yieldRequests[otherVehicle] and data.yieldRequests[hv])
            assert(data.search==search and data.generation==generation)
            tv.rootNode.x=80; trailer.rootNode.x=80
            Q.yieldTarget(u,true)
            g_currentMission.time=g_currentMission.time+2001
            Q.yieldTarget(u,true)
            assert(not data.yieldRequests[hv] and data.yieldRequests[otherVehicle])
            assert(Q.departureClearanceActive(u) and nativeStarts==0)
            occupied=false; Q.yieldTarget(u,true)
            g_currentMission.time=g_currentMission.time+2001; Q.yieldTarget(u,true)
            assert(nativeStarts==1 and data.nativeDeparture and not Q.owns(u))
        ''')

    def test_changed_turn_drops_frozen_area_and_checks_current_harvester(self):
        self.lua.execute('''
            beginClearance()
            local request=data.yieldRequests[hv]
            c.turnContext={}; c.aiTurn=nil; c.state=c.states.WORKING
            Q.yieldTarget(u,true)
            assert(not request.turnClearance and not request.turn)
            assert(nativeStarts==0)
            tv.rootNode.x=80; trailer.rootNode.x=80
            Q.yieldTarget(u,true)
            g_currentMission.time=g_currentMission.time+2001; Q.yieldTarget(u,true)
            assert(nativeStarts==1 and data.nativeDeparture and not Q.owns(u))
        ''')

    def test_deleted_turn_releases_only_to_native_departure(self):
        self.lua.execute('''
            beginClearance()
            local generation=data.generation
            hv.active=false
            Q.tick(u)
            assert(nativeStarts==1 and not Q.owns(u) and data.generation>generation)
            assert(not data.yieldRequests and data.nativeDeparture)
            Q.remove(u)
            assert(not Q.members[u] and not u.queueData and not Q.departureClearanceActive(u))
        ''')


if __name__ == '__main__':
    unittest.main()
