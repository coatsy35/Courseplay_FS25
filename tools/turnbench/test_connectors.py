"""Connector state, CP offset conventions and the PW articulation regression."""
import math
import unittest
from dataclasses import asdict

from engine import Bridge, Scenario, compare, drive_guidance, point, wrap


class ConnectorTests(unittest.TestCase):
    def test_guidance_tracks_cp_offset_positions_in_every_direction(self):
        p = Scenario()
        bridge = Bridge(p)
        for t in (0, math.pi/2, math.pi, -math.pi/2):
            for offset in (-2, 2):
                path = [dict(x=x, z=z, t=t, offset=offset, reverse=False, legEnd=20)
                        for x, z in (point(0, 0, t, along=d) for d in range(21))]
                x, _, z = bridge.g.waypointOffset(0, 0, t, offset)
                _, curvature, reverse = drive_guidance(p, bridge, path, 0, x, z, t, t, (x,z))
                self.assertAlmostEqual(curvature, 0)
                self.assertFalse(reverse)

    def test_reverse_pathfinding_is_disabled_for_wheeled_trailed_implement(self):
        for mounted in (False, True):
            p = Scenario(mounted=mounted, allowReverse=True)
            bridge = Bridge(p)
            path = bridge.g.connectingPath(bridge.lua.table_from(asdict(p)),
                                          0, 0, 0, 0, -20, math.pi)
            gears = [path[i]['reverse'] for i in range(1, len(path)+1)]
            self.assertEqual(any(gears), mounted)
            self.assertFalse(gears[-1])
            if mounted:
                self.assertTrue(all(path[i]['offset']==0 for i in range(1,len(path)+1)))

    def test_connection_uses_cp_goal_offset_for_alignment(self):
        for mounted in (False, True):
            p = Scenario(mounted=mounted, front=5.9)
            bridge = Bridge(p)
            x, z = bridge.g.connectionGoal(bridge.lua.table_from(asdict(p)), 10, 20, 0)
            self.assertEqual(x, 10)
            self.assertAlmostEqual(z, 20 if mounted else 14.1)

    def test_pw_connection_reaches_working_row_without_folding_over_ninety_degrees(self):
        run = compare(dict(courseLayout=True, fullCourse=True, width=5.6, length=12.3,
                           hitch=2, front=5.9, back=19.6, clearance=20.7, radius=9,
                           tightDistance=1, drill=False, headlandRows=9, roundHeadlands=0,
                           fieldWidth=220, fieldLength=240, headlandOverlap=7,
                           autoRowAngle=True, allowReverse=True, startZ=50))['baseline']
        self.assertTrue(run['metrics']['complete'])
        frames = [f for f in run['frames'] if f['phase']=='Connecting turn']
        self.assertTrue(frames)
        self.assertFalse(any(f['reverse'] for f in frames))
        maximum = max(abs(math.degrees(wrap(f['theta']-f['phi']))) for f in frames)
        # A regression threshold, not a measured drawbar joint limit.
        self.assertLess(maximum, 90)
        path = run['path']
        last = max(i for i,w in enumerate(path) if w['phase']=='Connecting turn')
        row = next(w for w in path[last+1:] if w.get('rowStart'))
        self.assertAlmostEqual(path[last]['x'], row['x'])
        self.assertAlmostEqual(path[last]['z'], row['z'])


if __name__ == '__main__':
    unittest.main()
