"""Finished/folded combine race through native job stop, reverse clearance and departure."""
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE/'tools/unloader-queue'))
import test_native_departure as departure
departure.ROOT = ROOT
departure.runtime.ROOT = ROOT
departure.runtime.native.ROOT = ROOT


class FinishedCombineTests(unittest.TestCase):
    def setUp(self):
        departure.NativeDepartureTests.setUp(self)
        source=(ROOT/'scripts/ai/jobs/CpAIJob.lua').read_text()
        begin=source.index('function CpAIJob:start(')
        end=source.index('function CpAIJob:applyCurrentState(', begin)
        self.lua.execute('CpAIJob={}; CpAIJob.__index=CpAIJob')
        self.lua.execute(source[begin:end])
        hooks=(ROOT/'scripts/ai/CpUnloaderQueueHooks.lua').read_text()
        self.lua.execute(hooks[hooks.index('if CpAIJob then'):hooks.index('local update =')])
        mapping=ET.parse(ROOT/'config/InfoTexts.xml').getroot()
        self.lua.globals().finishedEvent=next(e.attrib['event'] for e in mapping.iter()
            if e.attrib.get('class')=='AIMessageSuccessFinishedJob')
        self.lua.execute('''
            active=true; strategy=c; empty=0; ended=true
            c.isWaitingForUnloadAfterCourseEnded=function() return ended end
            c.getFillLevelPercentage=function() return empty end
            c.onFinished=function() end
            combine={rootNode=100,getIsCpActive=function() return active end,
                getCpDriveStrategy=function() return strategy end,
                deleteAgent=function() end,aiJobFinished=function() end,
                resetCpAllActiveInfoTexts=function() end,getIsControlled=function() return true end,
                createAgent=function() end,aiJobStarted=function() active=true; strategy=c end}
            job=setmetatable({isServer=true,vehicleParameter={getVehicle=function() return combine end},
                debug=function() end,onPreStart=function() end},CpAIJob)
            AIJob={stop=function() active=false; strategy=nil end}
            g_helperManager={availableHelpers={1},getRandomHelper=function() return {index=1} end}
            g_infoTextManager={getInfoTextDataByAIMessage=function(_,message)
                return 'message',true,message.event,false end}
            g_messageCenter={unsubscribeAll=function() end}
            SpecializationUtil={raiseEvent=function() end}
            u.states={}
            for _,collection in ipairs({AIDriveStrategyUnloadCombine.myStates,
                    AIDriveStrategyUnloadCombine.myCombineUnloadStates}) do
                for name,properties in pairs(collection) do u.states[name]={name=name,properties=properties} end
            end
            u.combineToUnload=combine; u.state=u.states.UNLOADING_STOPPED_COMBINE
            u.releaseCombine=nil -- actual native inactive-combine cleanup
            u.ppc={setNormalLookaheadDistance=function() end,isReversing=function() return true end}
            u.UNLOAD_TYPES={SILO_LOADER='loader'}
            reverse={reverse=true}
            Course.createStraightReverseCourse=function(vehicle,length)
                assert(vehicle==u.vehicle and length==15); reverseStarts=(reverseStarts or 0)+1; return reverse end
            Course.createStraightForwardCourse=function() return {idle=true} end
            u.settings.reverseSpeed={getValue=function() return 6 end}
            u.updateLowFrequencyImplementControllers=function() end
            u.calculateAutoAimPipeOffsetX=function() end
            u.getReverseDriveData=function() return 1,2,6 end
            u.setMaxSpeed=function(self,speed) self.maxSpeed=math.min(self.maxSpeed or math.huge,speed) end
            u.checkProximitySensors=function(self) if obstacle then self:setMaxSpeed(0) end end
            u.checkCollisionWarning=function() end
            u.combineUnloadStates={u.states.UNLOADING_STOPPED_COMBINE}
            CpUtil={isStateOneOf=function(state,states)
                for _,s in pairs(states) do if s==state then return true end end; return false end}
            clearance=-4
            u.getDistanceFromCombine=function(_,v) assert(v==combine); return 5,2,clearance end
            u.turningRadius=8
            u.isServingPosition=function(_,x,z) return x<500 end
            getWorldTranslation=function(node) return node,0,0 end
            other={rootNode=200,getIsCpActive=function() return true end,
                getCpDriveStrategy=function() return {callUnloader=function() end} end}
            g_currentMission.vehicleSystem={vehicles={combine,other}}
            function finish() job:stop({event=finishedEvent}) end
            function drive() u.maxSpeed=math.huge; return u:getDriveData(16) end
        ''')

    def test_finish_before_unloader_update_reverses_then_waits_for_local_combine(self):
        self.lua.execute('''
            finish(); assert(combine.queueFinishedEmptyCombine and not strategy)
            drive()
            assert(u.state==u.states.MOVING_BACK and u.course==reverse)
            assert(u.combineToUnload==nil and u.combineJustUnloaded==nil)
            assert(u.state.properties.vehicle==combine and not u.state.properties.holdCombine)
            assert(not Q.releaseFinishedCombine(u) and reverseStarts==1 and starts==0)
            obstacle=true; local _,_,_,speed=drive(); assert(speed==0)
            obstacle=false; clearance=1; drive()
            assert(u.state==u.states.IDLE and u.course.idle and starts==0)
        ''')

    def test_last_combine_departs_below_cutoff_only_after_native_clearance(self):
        self.lua.execute('''
            g_currentMission.vehicleSystem.vehicles={combine}; finish(); drive()
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL and starts==0 and u.course==reverse)
            assert(not u:getAllTrailersFull())
            clearance=1; drive()
            assert(starts==1 and u.state==u.states.WAITING_FOR_PATHFINDER and u.queueData.nativeDeparture)
            finishSearch(true); u:onLastWaypointPassed()
            assert(result():find('handover'))
        ''')

    def test_combine_on_another_field_does_not_keep_partial_trailer_waiting(self):
        self.lua.execute('other.rootNode=900; finish(); drive(); assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)')

    def test_adjustable_cutoff_and_manual_departure_override_remaining_work(self):
        for manual in (False, True):
            with self.subTest(manual=manual):
                self.setUp()
                self.lua.execute('''
                    u.settings.fullThreshold={getValue=function() return 73 end}
                    u.getAllTrailersFull=function(_,threshold) assert(threshold==73); return %s end
                    u.isDriveUnloadNowRequested=function() return %s end
                    finish(); drive(); assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL)
                ''' % ('false' if manual else 'true', 'true' if manual else 'false'))

    def test_manual_error_nonempty_or_nonfinal_stop_does_not_trigger_recovery(self):
        for setup, stop in [('', 'job:stop(nil)'), ('', "job:stop({event='onCpFull'})"),
                            ('empty=20', 'finish()'), ('ended=false', 'finish()')]:
            with self.subTest(setup=setup, stop=stop):
                self.setUp()
                self.lua.execute(setup+'\n'+stop+'''
                    assert(not combine.queueFinishedEmptyCombine)
                    assert(not Q.releaseFinishedCombine(u))
                    assert(u.combineToUnload==combine and u.state==u.states.UNLOADING_STOPPED_COMBINE)
                ''')

    def test_restart_clears_success_marker_before_subsequent_manual_stop(self):
        self.lua.execute('''
            finish(); assert(combine.queueFinishedEmptyCombine)
            job:start(1); assert(not combine.queueFinishedEmptyCombine and active)
            job:stop(nil); assert(not Q.releaseFinishedCombine(u))
        ''')

    def test_stale_preparation_is_cancelled_and_completion_is_idempotent(self):
        self.lua.execute('''
            local data=Q.data(u); data.search={}; data.assignment={}; data.waitingApproach={}; data.approachRetryAt=100
            local generation=data.generation
            finish(); assert(Q.releaseFinishedCombine(u))
            assert(data.generation>generation and not data.search and not data.assignment)
            assert(not data.waitingApproach and not data.approachRetryAt)
            assert(not Q.releaseFinishedCombine(u) and reverseStarts==1)
        ''')

    def test_other_modes_and_active_or_other_state_combines_are_untouched(self):
        for setup in ('u.augerWagon=true', 'u.useGiantsUnload=true', 'u.fieldUnloadPositionNode=1',
                      'active=true', 'u.state=u.states.DRIVING_TO_COMBINE'):
            with self.subTest(setup=setup):
                self.setUp()
                self.lua.execute('finish(); '+setup+'; assert(not Q.releaseFinishedCombine(u) and not reverseStarts)')


if __name__=='__main__': unittest.main()
