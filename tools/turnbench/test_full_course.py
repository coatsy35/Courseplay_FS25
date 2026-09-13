"""Integration checks against the production CP generator and reverse driver."""
import math
import json
import unittest
from pathlib import Path

from dataclasses import asdict
from engine import Bridge, Scenario, compare, drive_guidance, check_boundary


class CompleteCourseTests(unittest.TestCase):
    def test_inner_sharp_corner_matches_recorded_cp_waypoints(self):
        fixture=json.loads((Path(__file__).parent/'fixtures/pw10012-inner-sharp-corner.json').read_text())
        p=Scenario.parse(fixture['scenario'])
        b=Bridge(p)
        path=list(b.g.headlandCorner(b.lua.table_from(asdict(p)),*fixture['corner'],
            fixture['incoming'],fixture['outgoing'],*fixture['start'],fixture['incoming']).values())
        self.assertEqual(len(fixture['waypoints']),79)
        # Log positions, radius, tow length and angles are rounded. Compare
        # each recorded waypoint only to the same forward/reverse leg type.
        for recorded in fixture['waypoints']:
            distance=min(math.hypot(recorded['x']-w['x'],recorded['z']-w['z'])
                         for w in path if bool(w['reverse'])==recorded['reverse'])
            self.assertLess(distance,.2)

    def test_generator_radius_is_independent_of_driving_override(self):
        settings=dict(courseLayout=True,fieldWidth=160,fieldLength=220,
                      headlandRows=3,roundHeadlands=3,generatorRadius=5)
        a=compare(dict(settings,radius=9))['baseline']['layout']['routes']
        b=compare(dict(settings,radius=12))['baseline']['layout']['routes']
        c=compare(dict(settings,generatorRadius=10))['baseline']['layout']['routes']
        self.assertEqual(a,b)
        self.assertNotEqual(a,c)

    def test_working_headland_correction_uses_cp_and_trailer_geometry(self):
        for mounted in (False,True):
            p=Scenario(width=5.6,hitch=1.9,length=11.1,mounted=mounted,tightDistance=1)
            b=Bridge(p)
            points=b.lua.table_from([b.lua.table_from(v) for v in
                [(0,0),(0,5),(2,9),(6,12),(11,12),(16,12),(21,12)]])
            offsets=list(b.g.workingCourseOffsets(b.lua.table_from(asdict(p)),points).values())
            if mounted: self.assertEqual(offsets,[0]*len(offsets))
            else:
                self.assertGreater(max(offsets),1)
                self.assertLess(abs(offsets[-1]),max(offsets))

    def test_headland_loop_setting_selects_forward_only_cp_manoeuvre(self):
        for loop in (False,True):
            p=Scenario(width=5.6,hitch=1.9,length=11.1,front=4.6,back=18.3,
                       lowerSeconds=2.5,tightDistance=1,loopTurnsOnHeadland=loop)
            b=Bridge(p)
            path=list(b.g.headlandCorner(b.lua.table_from(asdict(p)),0,0,0,math.pi/2,0,16,0).values())
            self.assertEqual(any(w['reverse'] for w in path),not loop)
            self.assertTrue(any(w['lower'] for w in path))

    def run_course(self, **changes):
        settings=dict(courseLayout=True, fullCourse=True, allowReverse=True,
                      fieldWidth=140, fieldLength=180, headlandRows=5,
                      roundHeadlands=5, fieldMargin=3, startZ=50)
        settings.update(changes)
        return compare(settings)['baseline']

    def test_pw100_duplicate_headland_connector_does_not_run_away(self):
        run=self.run_course(width=5.6,length=12.3,front=5.9,back=19.6,clearance=20.7,
                            tightDistance=1,drill=False,headlandRows=9,roundHeadlands=0,
                            fieldWidth=220,fieldLength=240,headlandOverlap=7,autoRowAngle=True,
                            fieldMargin=0)
        self.assertTrue(run['metrics']['complete'])
        # This regression concerns the former 159 m runaway connection. Sharp
        # headland finishing now continues until the estimated rear marker
        # crosses its line; its footprint is a separate, still-failing check.
        connection=[f for f in run['frames'] if f['phase']=='Connecting turn']
        self.assertTrue(connection)
        self.assertLess(max(f['x'] for f in connection),230)

    def test_work_order_drives_headlands_and_centre_continuously(self):
        for first in (True, False):
            with self.subTest(headlandFirst=first):
                run=self.run_course(headlandFirst=first)
                self.assertTrue(run['metrics']['complete'])
                self.assertFalse(run['preview'])
                self.assertEqual(bool(run['path'][0]['headland']),first)
                self.assertTrue(any(f['headland'] for f in run['frames']))
                self.assertTrue(any(f['row'] for f in run['frames']))
                for a,b in zip(run['frames'],run['frames'][1:]):
                    self.assertLessEqual(math.hypot(b['x']-a['x'],b['z']-a['z']),3*(b['time']-a['time'])+.02)

    def test_patterns_and_skipped_rows_are_production_sequences(self):
        paths=[]
        for pattern,extra in [('alternating',{}),('alternating',{'rowsToSkip':2}),
                              ('spiral',{}),('spiral',{'spiralFromInside':True}),
                              ('lands',{}),('racetrack',{})]:
            with self.subTest(pattern=pattern,extra=extra):
                run=self.run_course(rowPattern=pattern,**extra)
                self.assertTrue(run['metrics']['complete'])
                paths.append(run['paths'])
        self.assertNotEqual(paths[0],paths[1])
        self.assertNotEqual(paths[2],paths[3])

    def test_reverse_course_preserves_every_waypoint_and_swaps_markers(self):
        for first in (True,False):
            for vehicles in (1,2):
                settings=dict(courseLayout=True,fieldShape='irregular',fieldWidth=300,
                              fieldLength=240,headlandRows=3,headlandFirst=first,vehicles=vehicles)
                forward=compare(settings)['baseline']['layout']
                reverse=compare(dict(settings,reverseCourse=True))['baseline']['layout']
                self.assertEqual(len(forward['routes']),vehicles)
                for a,b in zip(forward['routes'],reverse['routes']):
                    self.assertEqual(len(a['waypoints']),len(b['waypoints']))
                    for v,w in zip(a['waypoints'],reversed(b['waypoints'])):
                        for key in ('x','z','block','row','headland'):
                            self.assertEqual(v[key],w[key])
                        self.assertEqual(v['rowStart'],w['rowEnd'])
                        self.assertEqual(v['rowEnd'],w['rowStart'])

    def test_full_irregular_playback_work_order_and_reversal(self):
        for first in (True,False):
            for reverse in (True,False):
                with self.subTest(first=first,reverse=reverse):
                    settings=dict(fieldShape='irregular',fieldWidth=300,fieldLength=240,
                                  headlandRows=4,roundHeadlands=4,headlandFirst=first,reverseCourse=reverse)
                    run=self.run_course(**settings)
                    self.assertTrue(run['metrics']['complete'])
                    self.assertEqual(bool(run['path'][0]['headland']),first != reverse)
                    # The CP route contains every section, including shorter rows.
                    layout=compare(dict(run['scenario'],fullCourse=False))['baseline']['layout']
                    lengths=[sum(math.dist(a,b) for a,b in zip(row,row[1:])) for row in layout['rows']]
                    self.assertGreater(len(lengths),run['scenario']['passes'])
                    self.assertGreater(max(lengths)-min(lengths),20)
                    self.assertTrue(any(v['connecting'] for v in layout['routes'][0]['waypoints']))
                    self.assertEqual(run['generatorErrors'],[])

    def test_steep_irregular_finishes_when_passing_final_waypoint(self):
        run=self.run_course(fieldShape='irregular',irregularInset=42,headlandFirst=False,
                            fieldWidth=300,fieldLength=240,headlandRows=4,roundHeadlands=0,
                            custom=True,mounted=True,front=3,back=4,clearance=5)
        self.assertTrue(run['metrics']['complete'])
        self.assertEqual(run['frames'][-1]['state'],'Finished')
        self.assertEqual(run['events'][-1]['kind'],'Course finished')

    def test_fleet_has_distinct_complete_routes_and_shared_timeline(self):
        run=self.run_course(vehicles=2,headlandRows=3)
        self.assertEqual(len(run['fleet']),2)
        self.assertTrue(all(v['metrics']['complete'] for v in run['fleet']))
        self.assertNotEqual(run['fleet'][0]['path'],run['fleet'][1]['path'])
        self.assertEqual(run['frames'][-1]['time'],max(v['frames'][-1]['time'] for v in run['fleet']))

    def test_shaped_courses_complete_all_patterns(self):
        for shape in ('sloping','irregular'):
            for pattern in ('alternating','spiral','lands','racetrack'):
                with self.subTest(shape=shape,pattern=pattern):
                    run=self.run_course(fieldShape=shape,rowPattern=pattern,
                                        fieldWidth=220,fieldLength=300)
                    self.assertTrue(run['metrics']['complete'])
                    self.assertEqual(run['generatorErrors'],[])

    def test_islands_and_two_sided_headlands_execute(self):
        island=self.run_course(islandCount=1,islandSize=35,headlandRows=3,
                               fieldWidth=200,fieldLength=250)
        self.assertEqual(len(island['field']['islands']),1)
        self.assertTrue(any(v.get('island') for v in island['path']))
        self.assertTrue(island['metrics']['complete'])
        narrow=self.run_course(narrowField=True,headlandRows=3)
        self.assertTrue(narrow['metrics']['complete'])

    def test_feasible_boundary_checked_complete_course(self):
        run=self.run_course(fieldWidth=220,fieldLength=300,headlandRows=8,
                            roundHeadlands=8,fieldMargin=6,enforceBoundary=True)
        self.assertFalse(run.get('blocked',False))
        self.assertTrue(run['metrics']['complete'])

    def test_analytic_fallback_requires_reverse_capability(self):
        forward=Bridge(Scenario(headland=30,enforceBoundary=True))
        reversing=Bridge(Scenario(headland=30,enforceBoundary=True,allowReverse=True))
        self.assertFalse(any(v['reverse'] for v in forward.path))
        self.assertTrue(any(v['reverse'] for v in reversing.path))
        unchecked=Bridge(Scenario(headland=30,allowReverse=True,enforceBoundary=False))
        self.assertTrue(any(v['reverse'] for v in unchecked.path))

    def test_reverse_axle_past_cusp_changes_to_forward(self):
        p=Scenario()
        path=[dict(x=0,z=0,t=0,reverse=True),dict(x=0,z=1,t=0,reverse=True),
              dict(x=0,z=0,t=math.pi,reverse=False),dict(x=0,z=-1,t=math.pi,reverse=False)]
        ix,_,reverse=drive_guidance(p,Bridge(p),path,1,0,-9,math.pi,math.pi,(0,2))
        self.assertEqual(ix,2)
        self.assertFalse(reverse)

    def test_incompatible_narrow_field_and_fleet_rejected(self):
        with self.assertRaisesRegex(ValueError,'Two-sided'):
            Scenario.parse(dict(courseLayout=True,fullCourse=True,narrowField=True,
                                vehicles=2,headlandRows=3))

    def test_zero_headlands_clear_legacy_depth(self):
        p=Scenario.parse(dict(courseLayout=True,headlandRows=0,headland=50))
        self.assertEqual(p.headland,0)

    def test_small_island_fully_inside_work_envelope_is_rejected(self):
        frame=dict(x=50,z=75,theta=0,hitch=[50,73],axle=[50,65],
                   left=[40,60],right=[60,60],rearLeft=[40,40],rearRight=[60,40])
        run=dict(scenario=asdict(Scenario(enforceBoundary=True)),preview=False,
                 field=dict(west=0,east=100,south=0,north=100,
                    boundary=[[0,0],[100,0],[100,100],[0,100]],
                    islands=[[[49,49],[51,49],[51,51],[49,51]]]),
                 frames=[frame],metrics={})
        rejected=check_boundary(run)
        self.assertTrue(rejected['blocked'])
        self.assertGreater(rejected['boundaryClearanceNeeded'],0)

    def test_full_course_boundary_estimate_does_not_replace_tracking_verdict(self):
        frame=dict(x=50,z=101,theta=0,hitch=[50,99],axle=[50,91],
                   left=[47,95],right=[53,95],rearLeft=[47,80],rearRight=[53,80])
        for completed in (True,False):
            run=dict(scenario=asdict(Scenario(enforceBoundary=True)),preview=False,
                     completeCourse=True,field=dict(west=0,east=100,south=0,north=100,
                        boundary=[[0,0],[100,0],[100,100],[0,100]],islands=[]),
                     frames=[frame],metrics=dict(complete=completed))
            checked=check_boundary(run)
            self.assertFalse(checked['blocked'])
            self.assertEqual(checked['metrics']['complete'],completed)
            self.assertGreater(checked['boundaryClearanceNeeded'],0)
            self.assertIn('simplified implement body',checked['boundaryWarning'])
            self.assertEqual(checked['frames'],[frame])


if __name__ == '__main__':
    unittest.main()
