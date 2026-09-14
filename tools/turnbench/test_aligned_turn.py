from dataclasses import asdict, replace
import math
import unittest

from engine import Scenario, compare, polygon_clearance, point


PW = Scenario(alignedPlanner=True,width=5.6,length=11.1,hitch=1.9,
              front=4.6,back=18.3,radius=9,headlandRows=9,
              clearance=20.7,lowerSeconds=2.5,drill=False)


class AlignedTurnTests(unittest.TestCase):
    def verify_run(self, scenario):
        result=compare(asdict(scenario))
        self.assertTrue(result['planner']['feasible'],result['planner'])
        run=result['experiment']
        self.assertFalse(run.get('blocked',False))
        self.assertTrue(run['metrics']['complete'])
        self.assertTrue(run['metrics']['entry']['aligned'])
        self.assertTrue(run['metrics']['entry']['lowered'])
        self.assertEqual(run['metrics']['headlandShortfall'],0)
        self.assertLess(run['metrics']['maxArticulation'],85)
        for f in run['frames']:
            corners=[point(f['x'],f['z'],f['theta'],across=a,along=b)
                     for a in (-1.9,1.9) for b in (-2,4)]
            corners += [f[k] for k in ('left','right','rearLeft','rearRight','hitch','axle')]
            self.assertGreaterEqual(min(polygon_clearance(v,run['field']['boundary']) for v in corners),.5)
            if f['phase']!='exit' and f['lowered']:
                self.assertTrue(f['envelopeAligned'])
                self.assertLessEqual(f['edgeError'],.1)
                self.assertLessEqual(min(v[1]-run['scenario']['boundarySlope']*v[0]
                                         for v in (f['left'],f['right'])),0)
        commands=[e for e in run['events'] if e['kind']=='Lower requested']
        contacts=[e for e in run['events'] if e['kind']=='Working envelope active']
        self.assertTrue(commands)
        self.assertTrue(contacts)
        self.assertTrue(all(e['aligned'] and e['edgeError']<=.1 for e in commands))
        self.assertGreaterEqual(contacts[0]['time']-commands[-1]['time'],scenario.lowerSeconds-.03)
        return run

    def test_straight_and_large_headlands(self):
        normal=self.verify_run(PW)
        large=self.verify_run(replace(PW,headlandRows=18))
        self.assertGreater(large['planner']['approachLength'],normal['planner']['approachLength'])
        self.assertGreater(large['planner']['outgoingExtension'],normal['planner']['outgoingExtension'])

    def test_pikes_in_both_directions(self):
        for side,slope in ((1,'left'),(-1,'right'),(1,'right')):
            with self.subTest(side=side,slope=slope):
                self.verify_run(replace(PW,fieldShape='sloping',edgeAngle=25,
                                        side=side,slopeSide=slope))

    def test_mounted_pike(self):
        self.verify_run(replace(PW,mounted=True,front=3,back=5,clearance=8,
                                fieldShape='sloping'))

    def test_short_pike_to_a_much_longer_row(self):
        run=self.verify_run(replace(PW,fieldShape='sloping',rowSpacing=12*PW.width))
        self.assertGreater(run['planner']['rowEndDifference'],30)
        self.assertGreater(max(f['z'] for f in run['frames']),
                           run['planner']['rowEndDifference']+PW.radius)
        self.assertLessEqual(run['planner']['finalStraight'],4)

    def test_four_and_six_metre_drills(self):
        for width in (4,6):
            with self.subTest(width=width):
                self.verify_run(Scenario(alignedPlanner=True,width=width,length=9,
                                hitch=2,front=11,back=12,clearance=13,drill=True,
                                headlandRows=math.ceil(50/width),fieldShape='sloping'))

    def test_long_25_degree_pike_12m_drill_skipping_six_rows(self):
        run=self.verify_run(Scenario(alignedPlanner=True,width=12,length=9,hitch=2,
                            front=11,back=12,clearance=13,drill=True,headlandRows=6,
                            fieldShape='sloping',edgeAngle=25,fieldLength=500,
                            fieldWidth=400,rowSpacing=7*12,allowReverse=True))
        self.assertAlmostEqual(run['planner']['rowEndDifference'],39.17,places=2)
        self.assertEqual(len(run['field']['skippedRowSegments']),6)
        first,second=run['field']['rowSegments']
        self.assertEqual(second[0][1],first[0][1])
        self.assertGreater(second[1][1]-second[0][1],first[1][1]-first[0][1])
        boundary=run['field']['boundary']
        self.assertAlmostEqual(max(v[1] for v in boundary)-min(v[1] for v in boundary),500)

    def test_45_degree_wide_pike_finishes_the_entire_coverage_sample(self):
        run=self.verify_run(Scenario(alignedPlanner=True,width=12,length=9,hitch=2,
                            front=11,back=12,clearance=13,drill=True,headlandRows=6,
                            fieldShape='sloping',edgeAngle=45,fieldLength=500,
                            fieldWidth=400,rowSpacing=84,allowReverse=True))
        self.assertEqual(run['metrics']['missedArea'],0)

    def test_insufficient_headland_is_not_accepted(self):
        result=compare(asdict(replace(PW,headlandRows=3)))
        self.assertFalse(result['planner']['feasible'])
        self.assertIsNone(result['experiment'])

    def test_k_turn_reduces_mounted_headland_requirement(self):
        run=self.verify_run(replace(PW,mounted=True,front=3,back=5,clearance=8,
                                    headlandRows=4,allowReverse=True))
        self.assertEqual(run['planner']['manoeuvre'],'K-type')
        self.assertTrue(any(f.get('reverse') for f in run['frames']))
        self.assertLess(run['metrics']['envelopeDepth'],22)


if __name__=='__main__':
    unittest.main()
