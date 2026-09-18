"""Production corner geometry and forward/reverse marker-decision checks."""
import math
import unittest
from dataclasses import asdict, replace

from engine import Bridge, Scenario, compare
from full_course import compile_route, drive_course


class SharpCornerTests(unittest.TestCase):
    def test_finishes_at_selected_marker_before_generating_corner(self):
        p = Scenario(width=4, radius=6, hitch=2, length=5, front=3, back=8,
                     raiseSeconds=5)
        raw = [dict(x=x, z=z, headland=1, headlandTurn=turn, connecting=False,
                    rowStart=False, rowEnd=False, island=False, row=0)
               for x, z, turn in [(0, -40, False), (0, -5, False),
                                  (0, 0, True), (40, 0, False), (60, 0, False)]]
        starts = []
        for late in (False, True):
            q = replace(p, raiseLate=late)
            path = compile_route(q, raw, {'boundary': [[-100,-100], [100,-100],
                                                      [100,100], [-100,100]]})
            run = drive_course(q, path, 1)
            self.assertTrue(run['metrics']['complete'])
            raised = next(e for e in run['events'] if e.get('phase') == 'Finishing headland')
            started = next(e for e in run['events'] if e['kind'] == 'Headland turn started')
            # CP starts when the request is issued, not five seconds later when
            # the simulated hydraulics finish. Check the actual selected marker.
            self.assertEqual(raised['time'], started['time'])
            marker_z = raised['z'] - (q.back if late else q.front)
            self.assertGreater(marker_z, raised['target'][1])
            self.assertLessEqual(marker_z-raised['target'][1], q.speed*.1+1e-8)
            starts.append(started['z'])
        self.assertAlmostEqual(starts[1]-starts[0], p.back-p.front, delta=p.speed*.1)

    def test_angled_corner_work_boundaries_include_cp_overshoot(self):
        p = Scenario(width=6)
        bridge = Bridge(p)
        for angle, overshoot in ((90, 0), (60, math.sqrt(3)), (120, math.sqrt(3)),
                                 (-60, math.sqrt(3)), (175, 12)):
            out = math.radians(angle)
            work = dict(bridge.g.headlandWork(bridge.lua.table_from(asdict(p)), 0, 0, 0, out))
            self.assertAlmostEqual(work['overshoot'], overshoot)
            self.assertAlmostEqual(work['endZ'], -3+overshoot)
            self.assertAlmostEqual(work['startX']*math.sin(out)+work['startZ']*math.cos(out),
                                   -3-overshoot)

    def test_production_corner_has_three_legs_and_runtime_controls(self):
        for direction in (-1, 1):
            for mounted in (False, True):
                p = Scenario(mounted=mounted)
                bridge = Bridge(p)
                raw = bridge.g.headlandCorner(bridge.lua.table_from(asdict(p)),
                                              0, 0, 0, direction*math.pi/2, 0, -7)
                path = [dict(raw[i]) for i in range(1, len(raw)+1)]
                gears = []
                for w in path:
                    if not gears or gears[-1] != w['reverse']:
                        gears.append(w['reverse'])
                self.assertEqual(gears, [True, False, True])
                self.assertTrue(any('changeForwardX' in w for w in path))
                self.assertTrue(any(w['changeWhenAligned'] for w in path))
                self.assertTrue(any(w['lower'] and w['reverse'] for w in path))
                self.assertTrue(all(math.isfinite(w['x']) and math.isfinite(w['z']) for w in path))

    def test_reverse_lowering_uses_production_reverse_condition(self):
        p = Scenario()
        bridge = Bridge(p)
        for z, expected_forward, expected_reverse in ((1, True, False), (-20, False, True)):
            forward = bridge.g.shouldLowerAt(bridge.rig, 0, z, 0, p.width, p.back-p.front,
                                             p.speed, 0, 0, 0, False)[0]
            reverse = bridge.g.shouldLowerAt(bridge.rig, 0, z, 0, p.width, p.back-p.front,
                                             p.reverseSpeed, 0, 0, 0, True)[0]
            self.assertEqual(forward, expected_forward)
            self.assertEqual(reverse, expected_reverse)

    def test_zero_rounded_headlands_execute_corner_manoeuvres(self):
        run = compare(dict(courseLayout=True, fullCourse=True, allowReverse=True,
                           fieldWidth=160, fieldLength=200, headlandRows=2,
                           roundHeadlands=0, sharpenCorners=True, fieldMargin=3))['baseline']
        self.assertTrue(run['metrics']['complete'])
        corners = [v for v in run['path'] if v['phase'] == 'Headland corner']
        self.assertTrue(corners)
        self.assertTrue(any(v['reverse'] for v in corners))
        self.assertTrue(any(not v['reverse'] for v in corners))
        self.assertTrue(any(f['phase'] == 'Headland corner' and f['reverse'] for f in run['frames']))


if __name__ == '__main__':
    unittest.main()
