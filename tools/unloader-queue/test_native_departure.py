"""Native departure lifecycle with queue enabled; engine/pathfinder boundaries are mocked."""
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT = ROOT
runtime.native.ROOT = ROOT


class NativeDepartureTests(unittest.TestCase):
    def setUp(self):
        runtime.OwnershipTests.setUp(self)
        self.lua.execute('''
            Q=CpUnloaderQueue
            u.combineToUnload=nil
            u.settings={fullThreshold={getValue=function() return 85 end}}
            u.getAllTrailersFull=function() return false end
            u.isDriveUnloadNowRequested=function() return false end
            Q.refresh=function() end; Q.schedule=function() end
            Q.target=function() error('native departure returned to queue') end
            u.setNewState=function(self,state) self.state=state end
            u.getMaxFruitPercent=function() return 10 end
            u.getAllowReversePathfinding=function() return true end
            u.vehicle.cpGetFieldPolygon=function() return {} end
            CpFieldUtil={getFieldNumUnderVehicle=function() return 11 end}
            PathfinderUtil={getMaxIterationsForFieldPolygon=function() return 12345 end}
            AIUtil={getLength=function() return 18 end}
            PathfinderContext=setmetatable({defaultOffFieldPenalty=7},{__call=function()
                context={}
                for _,key in ipairs({'maxFruitPercent','offFieldPenalty','useFieldNum','allowReverse','maxIterations'}) do
                    context[key]=function(self,value) self[key..'Value']=value; return self end
                end
                return context
            end})
            starts=0
            u.pathfinderController={registerListeners=function(self,owner,done,failed,obstacle)
                self.owner=owner; self.done=done; self.failed=failed; self.obstacle=obstacle
            end,findPathToNode=function(self,ctx,node,x,z,accuracy)
                starts=starts+1; self.pathfinder={native=true}
                assert(ctx==context and node==42 and x==4.5 and z==-27 and accuracy==3)
            end}
            u.startPathfindingToInvertedGoalPositionMarker=nil -- run production method
            u.invertedStartPositionMarkerNode=42; u.invertedGoalPositionOffset=4.5
            Course={createFromTwoWorldPositions=function() return {alignment=true} end}
            localToWorld=function() return 40,0,50 end
            route={getNumberOfWaypoints=function() return 2 end,
                getWaypointPosition=function() return 30,0,40 end,
                append=function(self,segment) assert(segment.alignment); self.aligned=true end}
            u.startCourse=function(self,course,index) assert(index==1); self.course=course end
            function finishSearch(success)
                local controller=u.pathfinderController; controller.pathfinder=nil
                controller.done(u,controller,success,success and route or nil,false)
            end
        ''')

    def test_native_marker_route_alignment_completion_and_handover(self):
        self.lua.execute('''
            Q.take(u,'prepare'); u.queueData.search={}; local generation=u.queueData.generation
            u:startUnloadingTrailers()
            assert(not Q.owns(u) and u.queueData.nativeDeparture)
            assert(u.queueData.generation>generation and not u.queueData.search)
            assert(u.state==u.states.WAITING_FOR_PATHFINDER and starts==1)
            Q.tick(u); assert(starts==1 and u.pathfinderController.pathfinder.native)
            finishSearch(true)
            assert(u.state==u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL)
            assert(u.course==route and route.aligned)
            Q.tick(u); Q.speed(u); assert(u.course==route and not Q.owns(u))
            assert(not result():find('handover'))
            u:onLastWaypointPassed(); assert(result():find('handover'))
        ''')

    def test_native_search_keeps_crop_field_reverse_and_iteration_parameters(self):
        self.lua.execute('''
            u:startUnloadingTrailers()
            assert(context.maxFruitPercentValue==10 and context.offFieldPenaltyValue==7)
            assert(context.useFieldNumValue==11 and context.allowReverseValue)
            assert(context.maxIterationsValue==12345)
            assert(u.pathfinderController.failed==u.onPathfindingFailedToStationaryTarget)
            assert(u.pathfinderController.obstacle==u.onPathfindingObstacleAtStart)
        ''')

    def test_failed_marker_search_uses_native_full_event(self):
        self.lua.execute('u:startUnloadingTrailers(); finishSearch(false); assert(not Q.owns(u))')
        self.assertIn('handover', self.lua.eval('result()'))

    def test_missing_marker_uses_native_full_event(self):
        self.lua.execute('u.invertedStartPositionMarkerNode=nil; u:startUnloadingTrailers(); assert(starts==0)')
        self.assertIn('handover', self.lua.eval('result()'))

    def test_update_does_not_continue_after_synchronous_native_handover(self):
        self.lua.execute('''
            local current=u; local handovers=0
            u.vehicle.getCpDriveStrategy=function() return current end
            u.vehicle.stopCurrentAIJob=function() handovers=handovers+1; Q.remove(u); current=nil end
            u.invertedStartPositionMarkerNode=nil; u.getAllTrailersFull=function() return true end
            AIDriveStrategyCourse.update=function() error('updated deleted CP strategy') end
            u:update(33)
            assert(handovers==1 and current==nil and u.queueData==nil)
        ''')

    def test_departure_cannot_be_reassigned_even_below_cutoff(self):
        self.lua.execute('''
            u:startUnloadingTrailers()
            assert(not u:isAllowedToBeCalled() and not u:call(c,{}))
            finishSearch(true)
            assert(not u:isAllowedToBeCalled() and not u:call(c,{}))
        ''')

    def test_yield_request_cannot_cancel_native_departure_search_or_course(self):
        self.lua.execute('''
            u:startUnloadingTrailers()
            local runner=u.pathfinderController.pathfinder
            assert(not Q.priority(u,{}))
            assert(u.pathfinderController.pathfinder==runner and not Q.owns(u))
            finishSearch(true); assert(not Q.priority(u,{})); assert(u.course==route)
        ''')

    def test_native_full_reverse_clearance_is_not_replaced_by_queue_yield(self):
        self.lua.execute('''
            u.state=u.states.MOVING_BACK_WITH_TRAILER_FULL
            assert(not Q.priority(u,{}))
            Q.tick(u); assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
        ''')

    def pocket_fixture(self):
        # Use native pocket states/methods: native CP retains the pocket substate
        # after resuming work. Only vehicle/course/implement engine boundaries are mocked.
        source=(ROOT/'scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua').read_text()
        start=source.index('function AIDriveStrategyFieldWorkCourse:changeToFieldWork()')
        self.lua.execute(source[start:source.index('\nend',start)+4])
        self.lua.execute('''
            W=CpUnloaderQueueWorld
            HeadlandLoopGeometry.math={delta=function(a,b) return (a-b+math.pi)%(2*math.pi)-math.pi end}
            W.pose=function(node) return {x=node.x,z=node.z,t=node.t} end
            W.rigidModel=function() return {front=8,back=-5} end
            function setRow(points)
                local total=0
                for i,p in ipairs(points) do
                    p.s=total
                    local q=points[i+1]
                    p.d=q and math.sqrt((q.x-p.x)^2+(q.z-p.z)^2) or 0
                    total=total+p.d
                end
                row={points=points,offsetX=5,offsetZ=0,
                    getNumberOfWaypoints=function(self) return #self.points end,
                    getWaypointPosition=function(self,i)
                        local p=self.points[i]; return p.x+self.offsetX,0,p.z+self.offsetZ
                    end,
                    getWaypointYRotation=function(self,i)
                        i=math.min(i,#self.points-1)
                        local p,q=self.points[i],self.points[i+1]
                        return math.atan2(q.x-p.x,q.z-p.z)
                    end,
                    getDistanceFromFirstWaypoint=function(self,i) return self.points[i].s end,
                    getDistanceToNextWaypoint=function(self,i) return self.points[i].d end,
                    getOffset=function(self) return self.offsetX,self.offsetZ end,
                    setOffset=function(self,x,z) self.offsetX=x; self.offsetZ=z end}
            end
            setRow({{x=0,z=0},{x=0,z=600}})
            combine=setmetatable({states={WORKING={},WAITING_FOR_LOWER_DELAYED={},TURNING={}},
                course=row,fieldWorkCourse=row,aiOffsetX=5,
                settings={toolOffsetX={getValue=function() return 0 end}},
                getClosestFieldworkWaypointIx=function() return relevantIx or 1 end,
                changeToFieldWork=AIDriveStrategyFieldWorkCourse.changeToFieldWork,
                debug=function() end,setMaxSpeed=function() end,lowerImplements=function() end,
                isUnloadFinished=function() return true end},AIDriveStrategyCombineCourse)
            for key,value in pairs(AIDriveStrategyCombineCourse.myStates) do combine.states[key]=value end
            combine.state=combine.states.UNLOADING_ON_FIELD
            combine.unloadState=combine.states.WAITING_FOR_UNLOAD_IN_POCKET
            cv={active=true,rootNode={x=5,z=-8,t=0},getCpDriveStrategy=function() return combine end}
            cv.getIsCpActive=function() return cv.active end
            cv.getAIDirectionNode=function() return cv.rootNode end
            u.vehicle.getAIDirectionNode=function() return {x=10,z=-20,t=0} end
            function resumeWork()
                -- Execute native unload -> waiting -> fieldwork/lowering transitions.
                combine:driveUnloadOnField()
                g_currentMission.time=g_currentMission.time+5001
                combine:driveUnloadOnField()
                assert(combine.state==combine.states.WAITING_FOR_LOWER_DELAYED)
                combine.state=combine.states.WORKING -- engine reports implements ready
                assert(combine:isAboutToReturnFromPocket(),'native stale flag must remain present')
                combine:updateFieldworkOffset(row)
            end
            function exitPocket(z)
                if combine.state==combine.states.UNLOADING_ON_FIELD then resumeWork() end
                combine.state=combine.states.WORKING
                cv.rootNode.x=0; cv.rootNode.z=z; cv.rootNode.t=0
            end
        ''')

    def arm_pocket_departure(self, pocket=True):
        self.pocket_fixture()
        if not pocket:
            self.lua.execute('combine.unloadState=combine.states.WAITING_FOR_UNLOAD_ON_FIELD')
        self.lua.execute('''
            u.state=u.states.MOVING_BACK_WITH_TRAILER_FULL
            u.state.properties={vehicle=cv}
            u:startUnloadingTrailers()
        ''')

    def test_pocket_wait_requires_physical_exit_then_full_length_not_elapsed_time(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            assert(u.queueData.pocketDeparturePause and starts==1)
            assert(not Q.holdPocketDeparture(u,true,0))
            finishSearch(true)
            g_currentMission.time=90000
            assert(Q.holdPocketDeparture(u,true,15))
            g_currentMission.time=100000; assert(Q.holdPocketDeparture(u,true,15),'timer released occupied pocket')
            resumeWork()
            assert(Q.holdPocketDeparture(u,true,15),'WORKING alone is not a physical exit')
            exitPocket(0); assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=12.9; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=13; assert(not Q.holdPocketDeparture(u,true,15))
            assert(not u.queueData.pocketDeparturePause)
            u:onLastWaypointPassed(); assert(result():find('handover'))
        ''')

    def test_reverse_and_search_do_not_erase_or_delay_observed_combine_clearance(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            u.state=u.states.MOVING_BACK_BEFORE_PATHFINDING
            assert(not Q.holdPocketDeparture(u,false,5) and u.queueData.pocketDeparturePause)
            exitPocket(0); assert(not Q.holdPocketDeparture(u,false,5))
            cv.rootNode.z=13
            assert(not Q.holdPocketDeparture(u,false,5) and not u.queueData.pocketDeparturePause)
            u.state=u.states.WAITING_FOR_PATHFINDER; finishSearch(true)
            assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_combine_reversing_or_turning_resets_forward_clearance_measurement(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); exitPocket(0); assert(Q.holdPocketDeparture(u,true,15))
            combine.state=combine.states.TURNING
            assert(Q.holdPocketDeparture(u,true,15))
            exitPocket(12); assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=24.9; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=25; assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_capture_precedes_native_full_reverse_even_if_combine_resumes_before_reverse_ends(self):
        self.pocket_fixture()
        self.lua.execute('''
            u.combineToUnload=cv; u.getAllTrailersFull=function() return true end
            Q.watchStoppedMovingUnload=function() return false end
            Q.releaseFinishedCombine=function() return false end
            combine.isTurning=function() return false end; combine.isAboutToTurn=function() return false end
            u.releaseCombine=function(self) self.combineJustUnloaded=self.combineToUnload; self.combineToUnload=nil end
            u.startMovingBackFromCombine=function(self,state,vehicle)
                assert(vehicle==cv); self.state=state; state.properties={vehicle=vehicle}
            end
            AIDriveStrategyUnloadCombine.unloadMovingCombine=function(self) self:changeToUnloadWhenTrailerFull() end
        ''')
        hooks=(ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
        wrapper=hooks[hooks.index('local movingUnload ='):hooks.index('local allowed =')]
        self.lua.execute('local Q=CpUnloaderQueue; local U=AIDriveStrategyUnloadCombine; '+wrapper)
        self.lua.execute('''
            u:unloadMovingCombine()
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL and u.queueData.pocketDeparturePause)
            exitPocket(0); Q.holdPocketDeparture(u,false,5)
            g_currentMission.time=10000; cv.rootNode.z=5
            u:startUnloadingTrailers(); finishSearch(true)
            assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=13; assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_ordinary_full_departure_has_no_extra_pause(self):
        self.arm_pocket_departure(pocket=False)
        self.lua.execute('finishSearch(true); assert(not u.queueData.pocketDeparturePause); assert(not Q.holdPocketDeparture(u,true,15))')

    def test_stale_native_pocket_substate_cannot_hold_a_later_moving_unload(self):
        self.pocket_fixture()
        self.lua.execute('''
            resumeWork()
            assert(combine:isAboutToReturnFromPocket())
            u.getAllTrailersFull=function() return true end
            Q.capturePocketDeparture(u,cv,true)
            assert(not u.queueData.pocketDeparturePause,'ordinary working unload captured stale pocket')
            u.state=u.states.MOVING_BACK_WITH_TRAILER_FULL; u.state.properties={vehicle=cv}
            u:startUnloadingTrailers(); finishSearch(true)
            assert(not u.queueData.pocketDeparturePause and not Q.holdPocketDeparture(u,true,15))
            assert(u.course==route and route.aligned)
            u:onLastWaypointPassed(); assert(result():find('handover'))
        ''')

    def test_pocket_substate_cannot_capture_final_unloading(self):
        self.pocket_fixture()
        self.lua.execute('''
            resumeWork()
            combine.state=combine.states.UNLOADING_ON_FIELD
            combine.unloadState=combine.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
            Q.capturePocketDeparture(u,cv)
            assert(not u.queueData.pocketDeparturePause)
        ''')

    def test_working_state_waits_for_normal_course_offset_and_physical_row_entry(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); resumeWork()
            row.offsetX=5 -- old offset not yet updated on the fieldwork course
            cv.rootNode.z=0; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=20; assert(Q.holdPocketDeparture(u,true,15))
            assert(not u.queueData.pocketDeparturePause.exitPose)
            combine:updateFieldworkOffset(row)
            assert(Q.holdPocketDeparture(u,true,15)) -- still on offset pocket line
            cv.rootNode.x=0; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=32.9; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=33; assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_curved_working_row_releases_after_full_physical_length(self):
        self.pocket_fixture()
        self.lua.execute('''
            setRow({{x=0,z=0},{x=0,z=6},{x=6,z=12},{x=12,z=18}})
            combine.course=row; combine.fieldWorkCourse=row
            Q.capturePocketDeparture(u,cv)
            u:startUnloadingTrailers(); finishSearch(true); exitPocket(0)
            assert(Q.holdPocketDeparture(u,true,15))
            relevantIx=2; cv.rootNode.t=math.pi/4
            cv.rootNode.x=5; cv.rootNode.z=11
            assert(Q.holdPocketDeparture(u,true,15),'curve chord is not yet a full length')
            cv.rootNode.x=6; cv.rootNode.z=12
            assert(not Q.holdPocketDeparture(u,true,15),'frozen pocket tangent trapped curved-row departure')
        ''')

    def test_backward_motion_while_working_cannot_accumulate_clearance(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); exitPocket(0); assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=10; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=8; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=20.9; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=21; assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_wrong_parallel_row_and_misaligned_heading_do_not_count_as_exit(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); resumeWork()
            cv.rootNode.x=15; cv.rootNode.z=0; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=100; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.x=0; cv.rootNode.t=math.pi; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.t=0; assert(Q.holdPocketDeparture(u,true,15))
            cv.rootNode.z=113; assert(not Q.holdPocketDeparture(u,true,15))
        ''')

    def test_replaced_fieldwork_course_drops_obsolete_pocket_hold(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); assert(Q.holdPocketDeparture(u,true,15))
            combine.fieldWorkCourse={}
            assert(not Q.holdPocketDeparture(u,true,15) and not u.queueData.pocketDeparturePause)
            assert(u.course==route and not Q.owns(u))
        ''')

    def test_missing_geometry_cannot_create_an_unreleasable_hold(self):
        self.pocket_fixture()
        self.lua.execute('''
            W.rigidModel=function() return nil end
            Q.capturePocketDeparture(u,cv)
            assert(not u.queueData.pocketDeparturePause)
            assert(u.queueData.reason:find('geometry unavailable'))
        ''')

    def test_pocket_pause_changes_only_returned_speed_and_preserves_native_route(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true)
            Q.speed=function() end; Q.holdIncomingTurn=function() return false end
            AIDriveStrategyUnloadCombine.getDriveData=function() return 12,34,true,15,0.8 end
        ''')
        hooks=(ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
        wrapper=hooks[hooks.index('local drive = U.getDriveData'):hooks.index('local stoppedUnload =')]
        self.lua.execute('local Q=CpUnloaderQueue; local U=AIDriveStrategyUnloadCombine; '+wrapper)
        self.lua.execute('''
            local x,z,f,s,a=u:getDriveData()
            assert(x==12 and z==34 and f and s==0 and a==0.8 and u.course==route)
            exitPocket(0); u:getDriveData()
            cv.rootNode.z=13; x,z,f,s,a=u:getDriveData()
            assert(x==12 and z==34 and f and s==15 and a==0.8 and u.course==route)
        ''')

    def test_pocket_pause_is_removed_with_job_or_changed_combine_strategy(self):
        self.arm_pocket_departure()
        self.lua.execute('''
            finishSearch(true); assert(Q.holdPocketDeparture(u,true,15))
            cv.active=false
            assert(not Q.holdPocketDeparture(u,true,15) and not u.queueData.pocketDeparturePause)
            Q.remove(u); assert(not Q.holdPocketDeparture(u,true,15) and not u.queueData)
        ''')

    def departure_watch_fixture(self):
        self.pocket_fixture()
        self.lua.execute('''
            u:startUnloadingTrailers(); finishSearch(true)
            tractor={x=10,z=0,t=0}; u.vehicle.getAIDirectionNode=function() return tractor end
            u.isBeingHeld=function() return false end
            u.ppc={getRelevantWaypointIx=function() return 68 end}
            warning=false; obstacle=math.huge
            u.collisionAvoidanceController={isCollisionWarningActive=function() return warning end}
            u.proximityController={checkBlockingVehicleFront=function() return obstacle end,
                checkBlockingVehicleBack=function() return obstacle end}
            Q.watchNativeDeparture(u,15,false,true)
        ''')

    def test_native_departure_replans_after_no_motion_but_caps_stationary_retries(self):
        self.departure_watch_fixture()
        self.lua.execute('''
            g_currentMission.time=29999; assert(not Q.watchNativeDeparture(u,15,false,true))
            g_currentMission.time=30000; assert(Q.watchNativeDeparture(u,15,false,true))
            assert(starts==2 and not Q.owns(u)); finishSearch(true)
            g_currentMission.time=60000; assert(Q.watchNativeDeparture(u,15,false,true)); finishSearch(true)
            g_currentMission.time=90000; assert(not Q.watchNativeDeparture(u,15,false,true))
            assert(starts==3 and not result():find('handover'))
            tractor.z=2; Q.watchNativeDeparture(u,15,false,true)
            g_currentMission.time=120000; assert(Q.watchNativeDeparture(u,15,false,true))
        ''')

    def test_active_obstacle_and_pocket_wait_do_not_trigger_departure_replan(self):
        self.departure_watch_fixture()
        self.lua.execute('''
            for i=1,5 do
                g_currentMission.time=i*30000
                assert(not Q.watchNativeDeparture(u,0,true,true))
            end
            warning=true; g_currentMission.time=180000
            assert(not Q.watchNativeDeparture(u,0,false,true))
            warning=false; obstacle=10; g_currentMission.time=210000
            assert(not Q.watchNativeDeparture(u,0,false,false))
            assert(starts==1)
            obstacle=math.huge; g_currentMission.time=240000
            assert(Q.watchNativeDeparture(u,15,false,true) and starts==2)
        ''')

    def test_native_move_away_returning_idle_resumes_departure_not_preparation(self):
        self.lua.execute('''
            u:startUnloadingTrailers(); u.state=u.states.MOVING_AWAY_FROM_OTHER_VEHICLE
            Q.tick(u); assert(starts==1 and not Q.owns(u))
            u.state=u.states.IDLE; Q.tick(u)
            assert(starts==2 and u.state==u.states.WAITING_FOR_PATHFINDER and not Q.owns(u))
        ''')

    def test_stale_queue_completion_cannot_replace_native_marker_route(self):
        self.lua.execute('''
            Q.take(u,'prepare'); local data=u.queueData; data.searchGeneration=data.generation
            u:startUnloadingTrailers(); finishSearch(true)
            Q.startRoute(data,{{x=0,z=0},{x=0,z=10}})
            assert(u.course==route and u.state==u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL)
        ''')

    def test_native_job_stop_emits_configured_on_cp_full_after_engine_stop(self):
        # Execute the production stop method, with only GIANTS services mocked.
        mapping=ET.parse(ROOT/'config/InfoTexts.xml').getroot()
        item=next(e for e in mapping.iter() if e.attrib.get('class')=='AIMessageErrorIsFull')
        event=item.attrib['event']
        self.assertEqual(event, 'onCpFull')
        self.lua.execute('AIJob={new=function() end,stop=function() engineStopped=true end}')
        job_source=(ROOT/'scripts/ai/jobs/CpAIJob.lua').read_text()
        start=job_source.index('function CpAIJob:stop(')
        end=job_source.index('function CpAIJob:applyCurrentState(', start)
        self.lua.execute('CpAIJob={}; CpAIJob.__index=CpAIJob')
        self.lua.execute(job_source[start:end])
        self.lua.globals().fullEvent=event
        self.lua.execute('''
            local v=u.vehicle
            v.deleteAgent=function() end; v.aiJobFinished=function() end
            v.resetCpAllActiveInfoTexts=function() end; v.getIsControlled=function() return true end
            v.getCpDriveStrategy=function() return u end
            u.onFinished=function() finished=true; Q.remove(u) end
            local job=setmetatable({isServer=true,vehicleParameter={getVehicle=function() return v end},
                debug=function() end},CpAIJob)
            g_infoTextManager={getInfoTextDataByAIMessage=function() return 'NEEDS_UNLOADING',false,fullEvent,false end}
            g_messageCenter={unsubscribeAll=function() end}
            SpecializationUtil={raiseEvent=function(vehicle,event)
                assert(engineStopped and vehicle==v and event=='onCpFull'); eventRaised=true
            end}
            v.stopCurrentAIJob=function(_,message) job:stop(message) end
            Q.take(u,'prepare'); u:startUnloadingTrailers(); finishSearch(true); u:onLastWaypointPassed()
            assert(eventRaised and finished and u.queueData==nil and Q.members[u]==nil)
        ''')


if __name__=='__main__': unittest.main()
