"""Queue geometry tests; no claim about GIANTS steering or suspension physics."""
import math
from pathlib import Path
import sys
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
    ROOT = Path(sys.argv.pop(1)).resolve()


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / 'scripts/ai/CpUnloaderQueueGeometry.lua').read_text())
        self.g = self.lua.globals().CpUnloaderQueueGeometry

    def table(self, value):
        if isinstance(value, dict):
            return self.lua.table_from({k: self.table(v) for k, v in value.items()})
        if isinstance(value, list):
            return self.lua.table_from([self.table(v) for v in value])
        return value

    def polygon(self, points):
        return self.table([dict(x=x, z=z) for x,z in points])

    def box(self, x=0, z=0, heading=0, width=3, length=8):
        return self.g.rectangle(self.table(dict(x=x,z=z,heading=heading)),
                                self.table(dict(width=width,length=length)), 0)

    def test_rotated_rig_corners(self):
        b = self.box(100,200,math.pi/2)
        self.assertAlmostEqual(b[1].x, 96)
        self.assertAlmostEqual(b[1].z, 201.5)

    def test_full_rectangle_inside_harvested_field(self):
        field = self.polygon([(-20,-20),(20,-20),(20,20),(-20,20)])
        self.assertTrue(self.g.within(self.box(), field, self.table([])))
        self.assertFalse(self.g.within(self.box(x=19), field, self.table([])))
        self.assertFalse(self.g.within(self.box(), None, self.table([])))

    def test_small_island_inside_trailer_footprint_rejected(self):
        field = self.polygon([(-20,-20),(20,-20),(20,20),(-20,20)])
        island = self.polygon([(-.1,-.1),(.1,-.1),(.1,.1),(-.1,.1)])
        self.assertFalse(self.g.within(self.box(), field, self.lua.table_from([island])))

    def test_concave_field_crossing_rejected_even_with_all_corners_inside(self):
        field = self.polygon([(-10,-10),(10,-10),(10,10),(1,10),(1,0),(-1,0),(-1,10),(-10,10)])
        rect = self.box(width=8,length=8)
        self.assertTrue(all(self.g.inside(field, rect[i]) for i in range(1,5)))
        self.assertFalse(self.g.within(rect,field,self.table([])))

    def test_touching_is_collision(self):
        self.assertTrue(self.g.overlap(self.box(), self.box(x=3)))
        self.assertFalse(self.g.overlap(self.box(), self.box(x=3.01)))

    def samples(self, tractor_clear, trailer_clear, reenter=False):
        samples = []
        for distance in range(21):
            tractor = self.box(x=10 if distance >= tractor_clear else 0, length=4)
            trailer = self.box(x=10 if distance >= trailer_clear else 0, z=-10)
            if reenter and distance == 20:
                trailer = self.box(z=-10)
            samples.append(self.table(dict(distance=distance,
                rectangles=self.lua.table_from([tractor,trailer]))))
        return self.lua.table_from(samples)

    def test_tractor_clear_does_not_release_combine_with_trailer_still_blocking(self):
        corridor = self.box(width=16,length=60)
        self.assertEqual(self.g.firstClearTime(self.samples(2,12),corridor,2),6)

    def test_route_reentering_corridor_is_not_a_clearance(self):
        corridor = self.box(width=16,length=60)
        self.assertEqual(self.g.firstClearTime(self.samples(2,12,True),corridor,2),math.inf)

    def test_head_on_forward_side_pass_can_beat_reverse(self):
        corridor = self.box(width=16,length=60)
        forward = self.table(dict(name='forward-left',valid=True,speed=3,
                                  samples=self.samples(3,12)))
        reverse = self.table(dict(name='reverse',valid=True,speed=1,
                                  samples=self.samples(2,8)))
        best, elapsed = self.g.bestClearance(self.lua.table_from([reverse,forward]), corridor)
        self.assertEqual(best.name,'forward-left')
        self.assertEqual(elapsed,4)

    def test_rejected_crop_or_collision_route_never_wins(self):
        corridor = self.box(width=16,length=60)
        unsafe = self.table(dict(name='crop',valid=False,speed=10,samples=self.samples(0,0)))
        safe = self.table(dict(name='reverse',valid=True,speed=1,samples=self.samples(2,8)))
        best, _ = self.g.bestClearance(self.lua.table_from([unsafe,safe]),corridor)
        self.assertEqual(best.name,'reverse')

    def test_no_safe_escape_returns_none(self):
        candidate = self.table(dict(valid=False,speed=3,samples=self.samples(0,0)))
        best, _ = self.g.bestClearance(self.lua.table_from([candidate]),self.box(width=16,length=60))
        self.assertIsNone(best)

    def test_rotation_and_mirroring_preserve_intersection(self):
        for degrees in range(0,360,5):
            a = math.radians(degrees)
            for sign in [-1,1]:
                b = self.box(100,200,a)
                c = self.box(100+sign*2*math.cos(a),200-sign*2*math.sin(a),a)
                self.assertTrue(self.g.overlap(b,c))

    def test_departure_sequence_keeps_cp_until_whole_train_reaches_headland(self):
        headland = self.polygon([(-40,0),(40,0),(40,40),(-40,40)])
        for tractor_z, expected in [(-30,False),(-10,False),(5,False),(10,False),(15,True)]:
            train = self.lua.table_from([self.box(z=tractor_z,length=4),
                                         self.box(z=tractor_z-10,length=8)])
            self.assertEqual(self.g.canHandOver(train,headland,self.table([])),expected)

    def test_no_exit_marker_or_failed_route_cannot_authorise_midfield_handover(self):
        train = self.lua.table_from([self.box(z=-100),self.box(z=-112)])
        self.assertFalse(self.g.canHandOver(train,None,self.table([])))
        headland = self.polygon([(-40,0),(40,0),(40,40),(-40,40)])
        self.assertFalse(self.g.canHandOver(train,headland,self.table([])))

    def test_departure_waits_when_headland_still_has_crop_or_combine_corridor(self):
        headland = self.polygon([(-40,0),(40,0),(40,40),(-40,40)])
        train = self.lua.table_from([self.box(z=25),self.box(z=15)])
        crop = self.box(z=15,width=1,length=1)
        self.assertFalse(self.g.canHandOver(train,headland,self.lua.table_from([crop])))
        self.assertTrue(self.g.canHandOver(train,headland,self.table([])))

    def test_handover_requires_all_trailers_clear(self):
        headland = self.polygon([(-40,0),(40,40),(40,60),(-40,60)])
        train = self.lua.table_from([self.box(z=50),self.box(z=40),self.box(z=10)])
        self.assertFalse(self.g.canHandOver(train,headland,self.table([])))

    def test_unknown_or_degenerate_vehicle_footprint_cannot_authorise_handover(self):
        headland = self.polygon([(-40,0),(40,0),(40,60),(-40,60)])
        for rectangles in [[],[[]],[self.box(z=30,width=0)]]:
            self.assertFalse(self.g.canHandOver(self.table(rectangles),headland,self.table([])))


if __name__ == '__main__':
    unittest.main()
