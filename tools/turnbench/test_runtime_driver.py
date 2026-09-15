"""Shared-Lua execution regressions: test admission and coverage, not drawn lines."""
import math
import unittest
from engine import Scenario, compare
from runtime_driver import RuntimeDriver
from sync_runtime import validate


class RuntimeDriverTests(unittest.TestCase):
    def test_snapshot_is_intact(self):
        self.assertEqual(validate()['version'],'0.15')

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


if __name__=='__main__': unittest.main()
