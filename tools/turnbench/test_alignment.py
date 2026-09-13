import math
import unittest

from alignment import assess_envelope, straightening_distance


class EnvelopeAlignmentTests(unittest.TestCase):
    def test_parallel_but_displaced_is_not_aligned(self):
        state = assess_envelope((.3, 0), (.3, -12), 0, 5.6, (0, 0), 0)
        self.assertFalse(state.aligned)
        self.assertAlmostEqual(state.edge_error, .3)

    def test_front_on_line_does_not_hide_displaced_rear(self):
        a = math.radians(1)
        state = assess_envelope((0, 0), (-13.7*math.sin(a), -13.7*math.cos(a)),
                                a, 5.6, (0, 0), 0)
        self.assertLess(abs(state.angle), math.radians(2))
        self.assertGreater(state.edge_error, .23)
        self.assertFalse(state.aligned)

    def test_heading_must_point_into_the_row(self):
        self.assertFalse(assess_envelope((0, 0), (0, 12), math.pi,
                                        4, (0, 0), 0).aligned)

    def test_mounted_and_trailed_envelopes_use_the_same_criterion(self):
        for depth in (1, 13.7):
            self.assertTrue(assess_envelope((0, 0), (0, -depth), 0,
                                           5.6, (0, 0), 0).aligned)

    def test_rotated_and_translated_pike_row_has_identical_result(self):
        front, rear, a = (.08, 2), (-.04, -10), .01
        expected = assess_envelope(front, rear, a, 6, (0, 0), 0)
        for t in (math.radians(30), math.radians(-90), math.radians(179)):
            def transform(p):
                return (100+p[0]*math.cos(t)+p[1]*math.sin(t),
                        -40-p[0]*math.sin(t)+p[1]*math.cos(t))
            actual = assess_envelope(transform(front), transform(rear), a+t,
                                     6, (100, -40), t)
            self.assertAlmostEqual(actual.edge_error, expected.edge_error)
            self.assertEqual(actual.aligned, expected.aligned)

    def test_distance_agrees_with_independent_trailer_integration(self):
        # Integrate d(phi)/ds = -sin(phi)/L rather than repeating the formula.
        for initial in (math.radians(10), math.radians(-45)):
            distance = straightening_distance(11.1, 1.9, 4.6, 18.3, 5.6, initial)
            phi, travelled, previous = initial, 0.0, None
            while travelled < distance+.02:
                front = ((1.9-4.6)*math.sin(phi), 0)
                rear = ((1.9-18.3)*math.sin(phi), 0)
                state = assess_envelope(front, rear, phi, 5.6, (0, 0), 0)
                if state.aligned:
                    break
                previous = travelled
                step = .001
                mid = phi-step/2*math.sin(phi)/11.1
                phi -= step*math.sin(mid)/11.1
                travelled += step
            self.assertIsNotNone(previous)
            self.assertTrue(state.aligned)
            self.assertAlmostEqual(travelled, distance, delta=.002)

    def test_longer_axle_and_rear_marker_need_more_straight(self):
        args = (1.9, 4.6, 18.3, 5.6, math.radians(30))
        self.assertGreater(straightening_distance(15, *args),
                           straightening_distance(8, *args))
        self.assertGreater(straightening_distance(11.1, *args),
                           straightening_distance(11.1, 1.9, 4.6, 6, 5.6, args[-1]))

    def test_already_aligned_needs_no_extra_straight(self):
        self.assertEqual(straightening_distance(11.1, 1.9, 4.6, 18.3, 5.6, 0), 0)

    def test_invalid_geometry_cannot_be_declared_feasible(self):
        for angle in (math.nan, math.inf, math.pi/2, math.pi):
            with self.assertRaises(ValueError):
                straightening_distance(11.1, 1.9, 4.6, 18.3, 5.6, angle)
        for tolerance in (0, -1, math.nan):
            with self.assertRaises(ValueError):
                assess_envelope((0, 0), (0, -1), 0, 4, (0, 0), 0,
                                edge_tolerance=tolerance)


if __name__ == '__main__':
    unittest.main()
