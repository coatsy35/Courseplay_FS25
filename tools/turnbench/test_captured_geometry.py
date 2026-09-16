"""Check preserved capture data and attachment associations, without driving tests."""
import unittest
from captured_geometry import LIBRARY, load_vehicle, load_combination, read_json


class CapturedGeometryTests(unittest.TestCase):
    def test_every_saved_state_loads_with_components_and_dimensions(self):
        catalogue = read_json(LIBRARY / 'catalogue.json')
        self.assertEqual(18, len(catalogue['vehicles']))
        self.assertEqual(40, sum(len(v['profiles']) for v in catalogue['vehicles']))
        for vehicle in catalogue['vehicles']:
            for profile in vehicle['profiles']:
                with self.subTest(profile=profile['file']):
                    geometry = load_vehicle(vehicle['identity']['id'], profile['file'])
                    self.assertEqual(vehicle['identity'], geometry['identity'])
                    self.assertEqual(profile['state'], geometry['state'])
                    self.assertGreater(geometry['declaredSize']['length'], 0)
                    for joint in geometry['componentJoints']:
                        for index in joint['componentIndices']:
                            if index is not None:
                                self.assertIn(index, [c['index'] for c in geometry['components']])

    def test_all_combinations_keep_exact_recording_profiles_and_parent_links(self):
        catalogue = read_json(LIBRARY / 'catalogue.json')
        self.assertEqual(8, len(catalogue['combinations']))
        self.assertEqual(12, sum(len(c['recordings']) for c in catalogue['combinations']))
        for combination in catalogue['combinations']:
            for index in range(len(combination['recordings'])):
                with self.subTest(combination=combination['name'], recording=index):
                    loaded = load_combination(combination['id'], index)
                    members = {m['instance']: m for m in loaded['members']}
                    self.assertEqual(1, sum(m['parentInstance'] is None for m in members.values()))
                    self.assertEqual(set(members), {m['instance'] for m in loaded['initialSample']['machines']})
                    for member in members.values():
                        self.assertEqual(member['identity'], member['geometry']['identity'])
                        self.assertEqual(read_json(LIBRARY / 'profiles' / member['profileFile']), member['geometry'])
                        if member['parentInstance'] is not None:
                            self.assertIn(member['parentInstance'], members)
                            self.assertIsNotNone(member['jointIndex'])

    def test_latest_pw_keeps_internal_pivot_and_locked_input_coupling(self):
        geometry = load_vehicle('pw10012_7c87ec16')
        self.assertEqual('2026-09-16T21:14:57', geometry['capturedAt'])
        pivot = geometry['turning']['implementLimitation']['pivotSource']
        self.assertEqual({'index': 2, 'type': 'componentJoint'}, pivot)
        joint = next(j for j in geometry['componentJoints'] if j['index'] == pivot['index'])
        self.assertEqual([2, 3, None], joint['componentIndices'])
        self.assertAlmostEqual(1.570796327, joint['rotLimit'][1])
        active = next(j for j in geometry['inputCouplings'] if j['active'])
        self.assertEqual(0, active['upperRotLimitScale'][1])
        self.assertEqual(0, active['lowerRotLimitScale'][1])
        self.assertNotEqual(joint['pose']['position'], active['pose']['position'])


if __name__ == '__main__':
    unittest.main()
