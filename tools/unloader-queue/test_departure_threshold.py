"""Configured departure cutoff through native fullness, admission and reverse clearance."""
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 and not sys.argv[1].startswith('-') else SOURCE
sys.path.insert(0, str(SOURCE / 'tools/unloader-queue'))
import test_runtime as runtime
runtime.ROOT = ROOT
runtime.native.ROOT = ROOT


class DepartureThresholdTests(unittest.TestCase):
    def setUp(self):
        runtime.OwnershipTests.setUp(self)
        self.lua.execute((ROOT/'scripts/ai/util/FillLevelUtil.lua').read_text())
        self.lua.execute('''
            Q=CpUnloaderQueue
            CpMathUtil={divide=function(a,b) return b>0 and a/b or 0 end}
            fill=0; capacity=32000; free=nil; cutoff=85
            FillLevelUtil.getAllTrailerFillLevels=function()
                return fill,capacity,free or capacity-fill
            end
            u.settings={fullThreshold={getValue=function() return cutoff end}}
            u.isDriveUnloadNowRequested=function() return false end
            Q.refresh=function() end; Q.schedule=function() end; Q.target=function() return nil end
        ''')

    def test_exact_threshold_blocks_admission_and_native_call(self):
        for amount in (27200, 28800, 32000):
            with self.subTest(fill=amount):
                self.lua.execute(f'fill={amount}; assert(u:getAllTrailersFull()); assert(not u:isAllowedToBeCalled()); assert(not u:call(c,{{}}))')

    def test_below_threshold_remains_available(self):
        self.lua.execute('fill=27199; assert(not u:getAllTrailersFull()); assert(u:isAllowedToBeCalled())')

    def test_idle_at_threshold_starts_exit_without_native_timer(self):
        self.lua.execute('''
            fill=27200; u.combineToUnload=nil
            u.checkForTrailerToUnloadTo={get=function() return false end}
            Q.tick(u)
            assert(not Q.owns(u) and u.queueData.nativeDeparture)
        ''')
        self.assertIn('handover', self.lua.eval('result()'))

    def test_prepare_at_threshold_starts_exit(self):
        self.lua.execute('''
            Q.take(u,'prepare'); fill=27200; u.combineToUnload=nil
            assert(not u:isAllowedToBeCalled() and not u:call(c,{}))
            Q.tick(u); assert(not Q.owns(u) and u.queueData.nativeDeparture)
        ''')

    def test_active_transfer_uses_native_reverse_clearance_at_configured_cutoff(self):
        self.lua.execute('''
            fill=27200
            c.isTurning=function() return false end
            c.isAboutToTurn=function() return false end
            c.isAboutToReturnFromPocket=function() return false end
            u.startMovingBackFromCombine=function(self,state)
                assert(state==u.states.MOVING_BACK_WITH_TRAILER_FULL); self.state=state
            end
            assert(u:changeToUnloadWhenTrailerFull())
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL and not Q.owns(u))
            Q.tick(u)
            assert(u.state==u.states.MOVING_BACK_WITH_TRAILER_FULL and not Q.owns(u))
        ''')
        self.assertNotIn('handover', self.lua.eval('result()'))

    def test_no_remaining_mass_capacity_also_departs(self):
        self.lua.execute('fill=24000; free=0; assert(Q.atDepartureThreshold(u))')

    def test_configured_cutoff_and_explicit_threshold_are_respected(self):
        self.lua.execute('''
            cutoff=70; fill=22400; assert(u:getAllTrailersFull())
            assert(not u:getAllTrailersFull(90))
            cutoff=100; assert(not u:getAllTrailersFull()); fill=32000; assert(u:getAllTrailersFull())
        ''')

    def test_other_native_unloading_modes_keep_original_default_fullness(self):
        for mode in ('augerWagon','fieldUnloadPositionNode','useGiantsUnload'):
            with self.subTest(mode=mode):
                self.lua.execute(f'fill=27200; u.{mode}=true; assert(not u:getAllTrailersFull()); u.{mode}=nil')

    def test_fullness_preempts_queue_yield_with_native_departure(self):
        self.lua.execute('''
            u.combineToUnload=nil; Q.take(u,'yield'); fill=27200
            Q.yieldTarget=function() return nil end
            Q.tick(u); assert(not Q.owns(u) and u.queueData.nativeDeparture)
        ''')

    def test_manual_departure_below_cutoff_is_preserved(self):
        self.lua.execute('''
            fill=1000; u.combineToUnload=nil
            u.isDriveUnloadNowRequested=function() return true end
            Q.tick(u); assert(not Q.owns(u) and u.queueData.nativeDeparture)
        ''')


if __name__=='__main__': unittest.main()
