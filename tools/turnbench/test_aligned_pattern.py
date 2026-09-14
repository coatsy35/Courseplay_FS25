import math
import time
import unittest

from engine import compare, inside
from aligned_pattern import BlockCoverage


class PatternCoverageTests(unittest.TestCase):
    def test_pw_warm_turn_is_rechecked_from_continuous_arrival(self):
        scenario=dict(alignedPlanner=True,alignedPattern=True,width=5.6,length=11.1,hitch=1.9,
                      front=4.6,back=18.3,clearance=20.7,lowerSeconds=2.5,drill=False,
                      headlandRows=9,fieldLength=500,fieldWidth=400,fieldShape='sloping',
                      edgeAngle=20,rowSpacing=39.2,allowReverse=True)
        compare(scenario)
        result=compare(dict(scenario,edgeAngle=25))
        run=result['baseline']
        self.assertTrue(run['metrics']['complete'])
        self.assertFalse(run.get('blocked',False))
        self.assertEqual(len(run['turns']),13)
        self.assertTrue(all(t['entry']['aligned'] and t['entry']['lowered'] for t in run['turns']))
        self.assertTrue(all('scenario' in t for t in run['turns']))

    def test_raster_matches_cell_centres_and_retains_real_gap(self):
        coverage = BlockCoverage(-2,2,-8,.5)
        polygons = [[[-2,-8],[0,-8],[0,0],[-2,-1]],
                    [[.5,-8],[2,-8],[2,1],[.5,.25]]]
        for polygon in polygons:
            coverage.stamp(polygon)
        expected=[]
        for i,column in enumerate(coverage.columns):
            x=coverage.west+(i+.5)*coverage.resolution
            for j in range(len(column)):
                z=coverage.bottom+(j+.5)*coverage.resolution
                if not any(inside(x,z,p) for p in polygons):
                    expected.append([x,z])
        self.assertEqual(coverage.gaps(),expected)
        self.assertGreater(len(expected),0)
        for polygon in polygons:
            coverage.stamp(polygon[::-1])
        self.assertEqual(coverage.gaps(),expected)

    def test_continuous_complete_skip_block_and_cache(self):
        scenario=dict(alignedPlanner=True,alignedPattern=True,width=12,headlandRows=6,
                      fieldLength=500,fieldWidth=400,fieldShape='sloping',edgeAngle=25,rowSpacing=84)
        result=compare(scenario)
        run=result['baseline']
        self.assertEqual(result['planner']['order'],[1,8,9,2,3,10,11,4,5,12,13,6,7,14])
        self.assertEqual(len(run['turns']),13)
        self.assertTrue(run['metrics']['complete'])
        self.assertTrue(run['boundaryChecked'])
        self.assertFalse(run.get('blocked',False))
        self.assertEqual(run['metrics']['missedArea'],0)
        self.assertEqual(run['gaps'],[])
        for a,b in zip(run['frames'],run['frames'][1:]):
            self.assertGreater(b['time'],a['time'])
            self.assertLessEqual(math.dist((a['x'],a['z']),(b['x'],b['z'])),3*(b['time']-a['time'])+.04)
        # Cached payloads must remain independent of caller modifications.
        run['frames'][0]['x']=99999
        start=time.perf_counter()
        cached=compare(scenario)
        self.assertTrue(cached['planner']['cached'])
        self.assertLess(time.perf_counter()-start,3)
        self.assertNotEqual(cached['baseline']['frames'][0]['x'],99999)


if __name__=='__main__':
    unittest.main()
