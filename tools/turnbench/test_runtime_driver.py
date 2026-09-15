"""Shared-Lua execution regressions: test admission and coverage, not drawn lines."""
import math
import unittest
from engine import Scenario, compare
from runtime_driver import RuntimeDriver
from sync_runtime import validate


class RuntimeDriverTests(unittest.TestCase):
    def test_snapshot_is_intact(self):
        self.assertEqual(validate()['version'],'0.16')

    def test_pw_and_drills_use_runtime_entry_gate_on_straight_and_pike(self):
        for width,length,front,back,mounted in ((5.6,11.1,4.6,18.3,False),
                (6,9,11,12,False),(12,9,11,12,False),(6,1,3,4,True)):
            for angle in (0,25,45):
                with self.subTest(width=width,mounted=mounted,angle=angle):
                    p=Scenario(width=width,length=length,hitch=2,front=front,back=back,
                        radius=9,headland=110,mounted=mounted)
                    slope=math.tan(math.radians(angle))
                    layout=dict(boundary=[[-200,-350],[220,-350],[220,110+220*slope],
                                          [-200,110-200*slope]],islands=[])
                    r=RuntimeDriver(p,layout).run(dict(x=0,z=back+2.4,theta=0,phi=0),
                        [width*7,width*7*slope,math.pi],[0,0,0])
                    self.assertTrue(r['ok'],r['reason'])
                    kinds=[e['kind'] for e in r['events']]
                    self.assertEqual(sum(k.startswith('LOWER:') for k in kinds),1)
                    self.assertEqual(sum(k.startswith('ENTRY:') for k in kinds),1)
                    contact=r['frames'][-1]
                    self.assertTrue(contact['lowered'])
                    self.assertLess(contact['error'],.13)
                    self.assertLess(abs(contact['angle']),2)

    def test_impossible_entry_returns_runtime_failure_without_lowering(self):
        p=Scenario()
        r=RuntimeDriver(p,dict(boundary=[[0,0],[10,0],[10,10],[0,10]],islands=[])).run(
            dict(x=5,z=5,theta=0,phi=1),[5,7,0],[5,7,0],True)
        self.assertFalse(r['ok'])
        self.assertTrue(r['frames'])
        self.assertFalse(any(f['lowered'] for f in r['frames']))

    def test_full_course_preserves_entries_and_fills_later_passes(self):
        r=compare(dict(courseLayout=True,fullCourse=True,runtimeEnvelope=True,
            width=5.6,length=11.1,hitch=1.9,front=4.6,back=18.3,clearance=20.7,
            headlandRows=9,fieldWidth=140,fieldLength=220,headlandFirst=False,
            drill=False,roundHeadlands=0))['baseline']
        self.assertTrue(r['metrics']['complete'],r['runtimeFailure'])
        entries=[e for e in r['events'] if e['kind'].startswith('ENTRY:')]
        self.assertEqual(len(entries),r['runtimeTurns'])
        self.assertGreater(len(entries),2)
        self.assertLess(r['metrics']['entry']['lateral'],.13)
        self.assertEqual(r['coverage']['missedArea'],r['metrics']['missedArea'])

    def test_headland_first_pw_completes_checked_connection_and_all_centre_rows(self):
        r=compare(dict(courseLayout=True,fullCourse=True,runtimeEnvelope=True,
            width=5.6,length=11.1,hitch=1.9,front=4.6,back=18.3,clearance=20.7,
            lowerSeconds=2.5,tightDistance=1,headlandRows=9,fieldWidth=220,
            fieldLength=240,headlandFirst=True,drill=False,roundHeadlands=0))['baseline']
        self.assertTrue(r['metrics']['complete'],r['runtimeFailure'])
        kinds=[e['kind'] for e in r['events']]
        self.assertTrue(any(k.startswith('Initial connection needs complete envelope recovery:') for k in kinds))
        self.assertEqual(sum(k.startswith('ENTRY:') for k in kinds),r['runtimeTurns'])
        self.assertEqual(sum(k.startswith('LOWER:') for k in kinds),r['runtimeTurns'])
        self.assertGreater(r['runtimeTurns'],20)
        self.assertLess(r['metrics']['entry']['lateral'],.13)
        self.assertEqual(kinds[-1],'Course finished')
        # Coverage is still measured from actual lowered frames, including
        # headlands. Finishing the connector must not paint the field complete.
        self.assertGreater(r['coverage']['missedArea'],0)
        first_entry=next(e['time'] for e in r['events'] if e['kind'].startswith('ENTRY:'))
        self.assertTrue(any(f['headland'] and f['lowered'] and f['time']<first_entry for f in r['frames']))


if __name__=='__main__': unittest.main()
