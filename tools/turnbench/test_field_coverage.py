import unittest
import math

from field_coverage import FieldCoverage


def frame(x, z, lowered=True):
    return dict(left=[x,z], right=[x+1,z], rearRight=[x+1,z-1],
                rearLeft=[x,z-1], lowered=lowered)


class FieldCoverageTests(unittest.TestCase):
    def test_later_pass_fills_gap_without_double_counting(self):
        c=FieldCoverage([[0,0],[3,0],[3,4],[0,4]])
        for x in (0,2):
            c.finish_vehicle()
            c.add_frame(frame(x,1));c.add_frame(frame(x,4))
        self.assertEqual(c.result()['missedArea'],4)
        c.finish_vehicle();c.add_frame(frame(1,1));c.add_frame(frame(1,4))
        self.assertEqual(c.result()['missedArea'],0)
        c.add_frame(frame(1,1));c.add_frame(frame(1,4))
        self.assertEqual(c.result()['workedArea'],12)

    def test_lifted_jump_and_separate_vehicles_do_not_paint_connecting_swath(self):
        for separate in (False,True):
            c=FieldCoverage([[0,0],[1,0],[1,5],[0,5]])
            c.add_frame(frame(0,1))
            if separate: c.finish_vehicle()
            else: c.add_frame(frame(0,2,False))
            c.add_frame(frame(0,5))
            self.assertEqual(c.result()['missedArea'],3)

    def test_reverse_sweep_covers_between_samples(self):
        c=FieldCoverage([[0,0],[1,0],[1,5],[0,5]])
        c.add_frame(frame(0,5));c.add_frame(frame(0,1))
        self.assertEqual(c.result()['missedArea'],0)

    def test_concave_field_and_island_are_not_missed_work(self):
        boundary=[[0,0],[4,0],[4,2],[2,2],[2,4],[0,4]]
        island=[[.5,.5],[1.5,.5],[1.5,1.5],[.5,1.5]]
        for poly in (boundary,boundary[::-1]):
            c=FieldCoverage(poly,[island])
            self.assertEqual(c.result()['requiredArea'],11)
            # Painting the notch or island cannot reduce required coverage.
            c._fill([[2,2],[4,2],[4,4],[2,4]],0);c._fill(island,0)
            self.assertEqual(c.result()['missedArea'],11)
            c._fill(poly,0)
            self.assertEqual(c.result()['missedArea'],0)

    def test_sloping_edge_matches_cell_centres_and_rectangles_preserve_area(self):
        c=FieldCoverage([[0,0],[4,0],[4,4],[2,4]])
        expected=sum((j+.5)*.25/2 <= (i+.5)*.25
                     for i in range(16) for j in range(16))*.25**2
        result=c.result()
        self.assertEqual(result['requiredArea'],expected)
        self.assertEqual(sum(w*h for x,z,w,h in result['gapRuns']),result['missedArea'])
        self.assertLess(len(result['gapRuns']),expected/.25**2)

    def test_large_field_has_bounded_grid_and_reports_coarser_resolution(self):
        c=FieldCoverage([[0,0],[100,0],[100,100],[0,100]],max_cells=1000)
        self.assertLessEqual(c.nx*c.nz,1000)
        self.assertGreater(c.result()['resolution'],.25)

    def test_swept_edges_match_repainting_body_during_rotation(self):
        boundary=[[-20,-20],[20,-20],[20,20],[-20,20]]
        fast=FieldCoverage(boundary)
        reference=FieldCoverage(boundary)
        previous=None
        for i in range(100):
            angle=math.radians(i-50)
            corners=[[x*math.cos(angle)+z*math.sin(angle)+i/20,
                      -x*math.sin(angle)+z*math.cos(angle)]
                     for x,z in [(-1,3),(1,3),(1,-3),(-1,-3)]]
            f=dict(zip(('left','right','rearRight','rearLeft'),corners),lowered=True)
            fast.add_frame(f)
            reference._fill(corners,0)
            if previous:
                for k in range(4):
                    reference._fill([previous[k],previous[(k+1)%4],corners[(k+1)%4],corners[k]],0)
            previous=corners
        self.assertEqual(fast.rows,reference.rows)
