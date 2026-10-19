"""Loaded native departures yield to live working-header sweeps, not centrelines."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_yield as yielding
yielding.ROOT = yielding.runtime.ROOT = ROOT


class WorkingDepartureTests(unittest.TestCase):
    def setUp(self):
        yielding.YieldTests.setUp(self)
        self.lua.execute('''
            harvester,c,header=makeHarvester(0,0,0)
            c.states={WORKING={},TURNING={},UNLOADING_ON_FIELD={}}; c.state=c.states.WORKING
            c.setMaxSpeed=function() error('departure must not hold the combine') end
            local row={}
            for z=0,200,5 do row[#row+1]={x=0,z=z} end
            c.course=Course(harvester,row,false); c.fieldWorkCourse=c.course
            c.ppc.getRelevantWaypointIx=function() return math.floor(harvester.rootNode.z/5)+1 end
            harvester.lastSpeedReal=10/3600
            place(11,-12,0)
            u.state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            u.getCurrentCourse=function(self) return self.course end
            u.ppc.getRelevantWaypointIx=function() return 1 end
            u.getFieldSpeed=function() return 32 end
            u.course=Course(v,{{x=11,z=-12},{x=11,z=10},{x=-30,z=10}},true)
            original=u.course
            Q.data(u).nativeDeparture=true
            u.combineToUnload=nil -- native release has already happened
            AIMessageErrorIsFull={new=function() return {full=true} end}
            v.stopCurrentAIJob=function(_,message) assert(message.full); handovers=(handovers or 0)+1 end
            g_currentMission.vehicleSystem={vehicles={v,harvester}}
            function advanceCombine(z)
                harvester.rootNode.z=z; header.rootNode.z=z+5
                g_currentMission.time=g_currentMission.time+101
            end
        ''')

    def test_departing_full_rig_waits_outside_header_sweep_then_resumes(self):
        self.lua.execute('''
            assert(Q.holdWorkingDeparture(u,true,32))
            assert(u.course==original and not Q.owns(u) and not u.combineToUnload)
            advanceCombine(5); assert(Q.holdWorkingDeparture(u,true,0))
            advanceCombine(80); assert(Q.holdWorkingDeparture(u,true,32))
            g_currentMission.time=g_currentMission.time+2001
            assert(not Q.holdWorkingDeparture(u,true,32))
            assert(u.course==original and not Q.owns(u))
            handovers=0; u:onLastWaypointPassed(); assert(handovers==1) -- real native endpoint/full event
        ''')

    def test_intermittent_clearance_does_not_release_a_departure_into_the_header(self):
        self.lua.execute('''
            assert(Q.holdWorkingDeparture(u,true,32))
            for i=1,5 do
                advanceCombine(80); assert(Q.holdWorkingDeparture(u,true,0))
                g_currentMission.time=g_currentMission.time+1500
                advanceCombine(5); assert(Q.holdWorkingDeparture(u,true,0))
            end
            advanceCombine(80); assert(Q.holdWorkingDeparture(u,true,32))
            g_currentMission.time=g_currentMission.time+2001
            assert(not Q.holdWorkingDeparture(u,true,32))
            assert(u.course==original and not Q.owns(u))
        ''')

    def test_stopped_header_still_occupying_departure_route_does_not_count_as_clear(self):
        self.lua.execute('''
            assert(Q.holdWorkingDeparture(u,true,32))
            advanceCombine(5); harvester.lastSpeedReal=0
            for i=1,4 do
                g_currentMission.time=g_currentMission.time+1000
                assert(Q.holdWorkingDeparture(u,true,32))
            end
            advanceCombine(80); assert(Q.holdWorkingDeparture(u,true,32))
            g_currentMission.time=g_currentMission.time+2001
            assert(not Q.holdWorkingDeparture(u,true,32))
        ''')

    def test_changed_course_or_reverse_clears_the_previous_wait(self):
        self.lua.execute('''
            assert(Q.holdWorkingDeparture(u,true,32))
            u.course=Course(v,{{x=11,z=-12},{x=30,z=-12}},true)
            assert(not Q.holdWorkingDeparture(u,true,32))
            u.course=original; assert(Q.holdWorkingDeparture(u,true,32))
            assert(not Q.holdWorkingDeparture(u,false,8))
            assert(not u.queueData.workingDepartureHold)
        ''')

    def test_header_tip_conflict_without_crossing_row_centrelines(self):
        self.lua.execute('''
            u.course=Course(v,{{x=11,z=-12},{x=8,z=10},{x=8,z=60}},true)
            assert(Q.holdWorkingDeparture(u,true,32),'header width omitted')
        ''')

    def test_parallel_clear_route_retains_native_movement_and_ad_handover(self):
        self.lua.execute('''
            place(15,-12,0)
            u.course=Course(v,{{x=15,z=-12},{x=15,z=80}},true)
            assert(not Q.holdWorkingDeparture(u,true,32))
            handovers=0; u:onLastWaypointPassed(); assert(handovers==1)
        ''')

    def test_prediction_uses_attached_body_length_not_native_tractor_length(self):
        self.lua.execute('''
            AIUtil.getLength=function() error('tractor-only length used for complete departure') end
            local native=Q.yieldArea; local horizons={}
            Q.yieldArea=function(vehicle,course,horizon,limit)
                if vehicle==harvester then horizons[#horizons+1]=horizon end
                return native(vehicle,course,horizon,limit)
            end
            Q.holdWorkingDeparture(u,true,32)
            trailer.size.length=trailer.size.length+20
            g_currentMission.time=g_currentMission.time+101
            Q.holdWorkingDeparture(u,true,32)
            assert(#horizons==2 and horizons[2]>horizons[1]+2)
        ''')

    def test_manual_departure_intent_survives_crossing_wait(self):
        self.lua.execute('''
            local manual=true
            u.isDriveUnloadNowRequested=function() return manual end
            assert(Q.holdWorkingDeparture(u,true,32))
            manual=false -- the native button pulse expires while the rig waits
            advanceCombine(80); assert(Q.holdWorkingDeparture(u,true,32))
            g_currentMission.time=g_currentMission.time+2001
            assert(not Q.holdWorkingDeparture(u,true,32))
            assert(u.queueData.nativeDeparture and u.course==original)
            handovers=0; u:onLastWaypointPassed(); assert(handovers==1)
        ''')

    def test_reverse_turn_clearance_and_preparation_are_not_held(self):
        self.lua.execute('''
            assert(not Q.holdWorkingDeparture(u,false,5))
            for _,name in ipairs({'MOVING_BACK_WITH_TRAILER_FULL','MOVING_BACK_BEFORE_PATHFINDING','MOVING_AWAY_FROM_OTHER_VEHICLE'}) do
                u.state=u.states[name]; assert(not Q.holdWorkingDeparture(u,true,10))
            end
            u.state=u.states.DRIVING_BACK_TO_START_POSITION_WHEN_FULL
            Q.data(u).nativeDeparture=nil; assert(not Q.holdWorkingDeparture(u,true,32))
        ''')

    def test_combine_that_stops_elsewhere_does_not_reserve_its_whole_future_row(self):
        self.lua.execute('''
            advanceCombine(-30); harvester.lastSpeedReal=0
            c.ppc.getRelevantWaypointIx=function() return 1 end
            assert(not Q.holdWorkingDeparture(u,true,32))
        ''')

    def test_current_occupant_can_clear_without_creating_a_reciprocal_hold(self):
        self.lua.execute('''
            place(0,15,math.pi/2)
            u.course=Course(v,{{x=0,z=15},{x=40,z=15}},true)
            assert(not Q.holdWorkingDeparture(u,true,10))
        ''')

    def test_all_working_combines_are_checked_and_stopped_jobs_are_released(self):
        self.lua.execute('''
            local fleet={v}
            for i=1,4 do
                local h,d=makeHarvester(60+i*10,0,0)
                d.states=c.states; d.state=d.states.WORKING; d.course=c.course
                fleet[#fleet+1]=h
            end
            fleet[#fleet+1]=harvester; g_currentMission.vehicleSystem.vehicles=fleet
            assert(Q.holdWorkingDeparture(u,true,32))
            harvester.active=false; g_currentMission.time=g_currentMission.time+101
            assert(not Q.holdWorkingDeparture(u,true,32))
        ''')

    def test_unavailable_geometry_retains_native_checks_and_ownership(self):
        self.lua.execute('''
            W.currentBodies=function() return nil end
            assert(not Q.holdWorkingDeparture(u,true,32))
            assert(u.course==original and Q.data(u).nativeDeparture and not Q.owns(u))
        ''')


if __name__ == '__main__':
    unittest.main()
