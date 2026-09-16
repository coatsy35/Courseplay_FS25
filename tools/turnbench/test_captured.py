"""Measured playback must preserve chains and coordinate frames."""
import math
import unittest
from captured import catalogue, recording, world


class CapturedTests(unittest.TestCase):
    def test_basis_transform_handles_yaw_and_pitch(self):
        p={'position':[10,20,30],'forward':[1,0,0],'up':[0,1,0]}
        self.assertEqual(world(p,[2,3,4]),[14,28])
        angle=.4
        p={'position':[0,0,0],'forward':[0,-math.sin(angle),math.cos(angle)],
           'up':[0,math.cos(angle),math.sin(angle)]}
        self.assertAlmostEqual(world(p,[1,2,3])[1],2*math.sin(angle)+3*math.cos(angle))

    def test_every_recorded_machine_and_state_survives_import(self):
        data=catalogue()
        self.assertEqual(len(data['machines']),34)
        self.assertEqual(len(data['recordings']),11)
        self.assertEqual(len({r['title'] for r in data['recordings']}),7)
        for entry in data['recordings']:
            run=recording(entry['id'])
            self.assertEqual(len(run['frames']),entry['samples'])
            ids={m['instance'] for m in entry['members']}
            for frame in run['frames']:
                self.assertEqual({m['instance'] for m in frame['machines']},ids)
                for machine in frame['machines']:
                    self.assertTrue(all(math.isfinite(x) for x in machine['position']))
                    for polygon in machine['work']:
                        self.assertEqual(len(polygon),4)
                        self.assertTrue(all(math.isfinite(x) for p in polygon for x in p))

    def test_carts_remain_children_of_the_drill(self):
        triples=[r for r in catalogue()['recordings'] if len(r['members'])==3]
        self.assertEqual(len(triples),2)
        for run in triples:
            self.assertEqual([m['parentInstance'] for m in run['members']],[None,1,2])
        self.assertEqual({round(r['widths'][1],1) for r in triples},{25.6,30.5})

    def test_recording_identifier_cannot_escape_library(self):
        with self.assertRaises(ValueError): recording('../../server.py')

    def test_recorded_lowering_gaps_are_reported_not_filled(self):
        data=catalogue()
        self.assertTrue(all(not any(r['loweringTransitions'].values()) for r in data['recordings']))
        self.assertEqual(sum(any(r['loweredSamples'].values()) for r in data['recordings']),2)


if __name__=='__main__': unittest.main()
