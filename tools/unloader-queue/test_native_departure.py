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
