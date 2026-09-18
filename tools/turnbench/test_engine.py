import importlib.util
from dataclasses import asdict
import math
from pathlib import Path
import sys
import unittest

from engine import Bridge, Coverage, ROOT, Scenario, compare, simulate, simulate_field, implement_catalogue


class AlgorithmTests(unittest.TestCase):
    def test_sloping_side_rows_and_patterns(self):
        for side in ('left','right'):
            for angle in (20,30):
                for pattern in ('alternating','lands','racetrack'):
                    with self.subTest(side=side,angle=angle,pattern=pattern):
                        r=compare(dict(pattern=True,fieldShape='sloping',roundHeadlands=1,slopeSide=side,edgeAngle=angle,
                                       rowPattern=pattern,passes=6,headlandRows=10,
                                       fieldWidth=400,fieldLength=300,enforceBoundary=True))['baseline']
                        self.assertTrue(r['metrics']['complete'],r.get('reason'))
                        self.assertFalse(r.get('blocked',False))
                        rows=[sorted(row,key=lambda pt:pt[0]) for row in r['field']['rowSegments']]
                        self.assertEqual(len(rows),6)
                        for row in rows:
                            self.assertAlmostEqual(row[0][1],row[1][1])
                        sloped=0 if side=='left' else 1
                        for a,b in zip(rows,rows[1:]):
                            self.assertAlmostEqual(a[1-sloped][0],b[1-sloped][0])
                            self.assertAlmostEqual((b[sloped][0]-a[sloped][0])/(b[sloped][1]-a[sloped][1]),
                                                   math.tan(math.radians(angle))*(1 if side=='left' else -1))
                        self.assertEqual(len(r['turns']),5)
                        for a,b in zip(r['frames'],r['frames'][1:]):
                            self.assertLessEqual(math.dist((a['x'],a['z']),(b['x'],b['z'])),.301)

    def test_sloping_side_rejects_impossible_outline(self):
        for data in (dict(edgeAngle=0),dict(edgeAngle=46),dict(slopeSide='top'),
                     dict(edgeAngle=30,fieldWidth=240,fieldLength=1000)):
            with self.subTest(data=data), self.assertRaises(ValueError):
                Scenario.parse(dict(fieldShape='sloping',**data))

    def test_irregular_movement_patterns_preserve_pose_and_row_endpoints(self):
        for pattern in ('alternating','lands','racetrack'):
            with self.subTest(pattern=pattern):
                p=Scenario.parse(dict(pattern=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,rowPattern=pattern,
                                     headlandRows=9,fieldWidth=400,fieldLength=240,passes=6,
                                     enforceBoundary=True))
                r=compare(asdict(p))['baseline']
                self.assertTrue(r['metrics']['complete'])
                self.assertFalse(r.get('blocked',False))
                self.assertFalse(r['preview'])
                self.assertEqual(len(r['field']['rowSegments']),6)
                self.assertEqual(len(r['turns']),5)
                self.assertEqual(sorted(r['field']['order']),list(range(1,7)))
                lengths=[math.dist(*row) for row in r['field']['rowSegments']]
                self.assertGreater(max(lengths)-min(lengths),1)
                self.assertEqual(sum(e['kind']=='Raise requested' for e in r['events']),6)
                self.assertEqual(sum(e['kind']=='Lower requested' for e in r['events']),5)
                for a,b in zip(r['frames'],r['frames'][1:]):
                    self.assertAlmostEqual(b['time']-a['time'],.1)
                    self.assertLessEqual(math.dist((a['x'],a['z']),(b['x'],b['z'])),p.speed*.101)
                    for key in ('hitch','axle','work','left','right','rearLeft','rearRight'):
                        self.assertLess(math.dist(a[key],b[key]),1)

    def test_irregular_pw100_clearance_rejection_and_recovery(self):
        data=dict(pattern=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,width=5.6,length=12.3,front=5.9,
                  back=19.6,clearance=20.7,tightDistance=1,drill=False,
                  fieldWidth=220,fieldLength=240,enforceBoundary=True)
        small=compare(dict(data,headlandRows=9))['baseline']
        self.assertTrue(small['blocked'])
        fit=compare(dict(data,headlandRows=10))['baseline']
        self.assertTrue(fit['metrics']['complete'])
        self.assertFalse(fit.get('blocked',False))

    def test_irregular_rotated_mounted_and_excess_passes(self):
        r=compare(dict(pattern=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,custom=True,mounted=True,
                       front=3,back=4,clearance=5,rowAngle=65,side=-1,passes=3,
                       headlandRows=9,fieldWidth=400,fieldLength=240))['baseline']
        self.assertTrue(r['metrics']['complete'])
        self.assertEqual(r['metrics']['maxArticulation'],0)
        with self.assertRaisesRegex(ValueError,'Only .* rows'):
            compare(dict(pattern=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,passes=32,
                         headlandRows=9,fieldWidth=220,fieldLength=240))

    def test_irregular_partial_headlands_are_not_accepted_as_full_configuration(self):
        data=dict(pattern=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,width=4,headlandRows=14,
                  fieldWidth=400,fieldLength=400,enforceBoundary=True,generatorRadius=9)
        with self.assertRaisesRegex(ValueError,'CP generated only'):
            compare(data)
        r=compare(dict(data,roundHeadlands=0))['baseline']
        self.assertTrue(r['metrics']['complete'])
        self.assertFalse(r.get('blocked',False))
        self.assertEqual(len(r['field']['headlands']),14)

    def test_real_lowering_accepts_angled_drill(self):
        p = Scenario()
        bridge = Bridge(p)
        lower, _ = bridge.g.shouldLower(bridge.rig,p.width,0.3,math.pi+math.pi/4,p.width,1,p.speed)
        self.assertTrue(lower)

    def test_real_lowering_rejects_far_sideways_approach(self):
        p = Scenario()
        bridge = Bridge(p)
        lower, _ = bridge.g.shouldLower(bridge.rig,100,0.3,math.pi,p.width,1,p.speed)
        self.assertFalse(lower)

    def test_real_lowering_waits_before_boundary(self):
        p = Scenario()
        bridge = Bridge(p)
        lower, _ = bridge.g.shouldLower(bridge.rig,p.width,10,math.pi,p.width,1,p.speed)
        self.assertFalse(lower)

    def test_real_trailer_heading_straight(self):
        b = Bridge(Scenario())
        self.assertAlmostEqual(b.g.nextTrailerHeading(0,0,1,9),0)
        t = b.g.nextTrailerHeading(math.pi/4,0,0.1,9)
        self.assertLess(abs(t),math.pi/4)

    def test_real_course_correction_resets(self):
        b = Bridge(Scenario(tightDistance=1))
        offsets = [b.g.changeWaypoint(b.rig,i+1) for i in range(len(b.path))]
        self.assertGreater(max(map(abs,offsets)),0.1)
        self.assertEqual(offsets[-1],0)

    def test_generated_paths_are_finite(self):
        for side in (-1,1):
            b = Bridge(Scenario(side=side))
            self.assertGreater(len(b.path),50)
            self.assertTrue(all(math.isfinite(w[k]) for w in b.path for k in ('x','z','t')))
            self.assertAlmostEqual(b.path[-1]['x'],side*6,places=6)

    def test_real_raise_late_uses_rear_marker_and_strict_boundary(self):
        early, late = Bridge(Scenario(raiseLate=False)), Bridge(Scenario(raiseLate=True))
        for bridge in (early,late):
            self.assertFalse(bridge.g.shouldRaise(bridge.rig,0,0,0,6,5))
        self.assertTrue(early.g.shouldRaise(early.rig,0,1,0,6,5))
        self.assertFalse(late.g.shouldRaise(late.rig,0,1,0,6,5))
        self.assertFalse(late.g.shouldRaise(late.rig,0,5,0,6,5))
        self.assertTrue(late.g.shouldRaise(late.rig,0,5.01,0,6,5))

    def test_turn_generators_have_distinct_geometry(self):
        for side in (-1,1):
            dubins = Bridge(Scenario(side=side))
            reverse = Bridge(Scenario(side=side,turnType='reedsShepp'))
            loop = Bridge(Scenario(side=side,turnType='headlandLoop'))
            self.assertTrue(any(w['reverse'] for w in reverse.path))
            self.assertFalse(any(w['reverse'] for w in dubins.path+loop.path))
            self.assertNotEqual(dubins.path,reverse.path)
            self.assertAlmostEqual(loop.rig.workStart.t,side*math.pi/2)
            for bridge in (reverse,loop):
                self.assertTrue(all(math.isfinite(w[k]) for w in bridge.path for k in ('x','z','t')))


class FieldTests(unittest.TestCase):
    def test_custom_mounted_tool_is_rigid_and_trailed_tool_can_articulate(self):
        for mounted in (False,True):
            r=compare(dict(custom=True,mounted=mounted,front=3,back=4,clearance=5,
                           drill=False,pattern=True,width=4))['baseline']
            self.assertTrue(r['metrics']['complete'])
            if mounted:
                for f in r['frames']:
                    self.assertAlmostEqual(f['phi'],f['theta'])
                    self.assertAlmostEqual(math.dist(f['work'],(f['x'],f['z'])),3)
                self.assertEqual(r['metrics']['maxArticulation'],0)
            else:
                self.assertGreater(r['metrics']['maxArticulation'],10)

    def test_explicit_width_controls_rectangular_movement_boundary(self):
        for side in (-1,1):
            p=Scenario.parse(dict(pattern=True,passes=1,fieldWidth=400,side=side))
            field=simulate_field(p)['field']
            self.assertAlmostEqual(field['east']-field['west'],400)
        with self.assertRaisesRegex(ValueError,'Field width must be at least'):
            Scenario.parse(dict(pattern=True,fieldWidth=100,passes=8))

    def test_irregular_wide_field_can_log_corner_warnings_offline(self):
        r=compare(dict(courseLayout=True,fieldShape='irregular',irregularInset=23,roundHeadlands=1,headlandRows=9,
                       fieldWidth=400,fieldLength=240))['baseline']
        self.assertGreater(len(r['paths'][0]),100)
        self.assertEqual(len(r['layout']['headlands']),9)

    def test_standalone_logger_preserves_warnings_and_errors(self):
        bridge=Bridge(Scenario())
        bridge.lua.execute((ROOT/'tools/turnbench/field_layout.lua').read_text())
        self.assertFalse(bridge.g.CourseGenerator.isRunningInGame())
        bridge.lua.execute('''
            capturedLogs={}
            print=function(message) table.insert(capturedLogs,message) end
            Logger('bench regression'):warning('Corner %d remains rounded', 3)
            Logger('bench regression'):error('No room for %d headlands', 20)
        ''')
        self.assertIn('[WARNING]',bridge.g.capturedLogs[1])
        self.assertIn('Corner 3 remains rounded',bridge.g.capturedLogs[1])
        self.assertIn('[ERROR]',bridge.g.capturedLogs[2])

    def test_four_passes_alternate_ends_and_remain_continuous(self):
        p = Scenario.parse(dict(pattern=True,passes=4,headlandRows=6))
        r = simulate_field(p)
        self.assertTrue(r['metrics']['complete'])
        self.assertEqual(r['field']['rows'],[0,6,12,18])
        self.assertEqual([t['end'] for t in r['turns']],['North','South','North'])
        self.assertEqual([t['direction'] for t in r['turns']],['Right','Left','Right'])
        self.assertEqual(sum(e['kind']=='Raise requested' for e in r['events']),4)
        self.assertEqual(sum(e['kind']=='Lower requested' for e in r['events']),3)
        self.assertEqual(r['events'][-1]['kind'],'Field run finished')
        self.assertFalse(r['frames'][-1]['lowered'])
        for a,b in zip(r['frames'],r['frames'][1:]):
            self.assertAlmostEqual(b['time']-a['time'],.1)
            self.assertLessEqual(math.hypot(b['x']-a['x'],b['z']-a['z']),p.speed*.101)
            # Every physical marker must carry through row and turn handovers.
            for key in ('hitch','axle','work','left','right','rearLeft','rearRight'):
                self.assertLess(math.dist(a[key],b[key]),1)
        self.assertGreater(r['metrics']['northDepth'],0)
        self.assertGreater(r['metrics']['southDepth'],0)
        self.assertTrue(all(-p.fieldLength+p.headland-1 <= z <= -p.headland+1
                            for x,z in r['gaps']+r['exitGaps']))

    def test_headland_rows_shorten_working_rows_with_fixed_outer_boundaries(self):
        runs = [simulate_field(Scenario.parse(dict(pattern=True,passes=1,headlandRows=n))) for n in (4,6)]
        for r in runs:
            self.assertEqual((r['field']['north'],r['field']['south']),(0,-160))
            self.assertEqual(r['turns'],[])
            self.assertIsNone(r['metrics']['entry'])
        self.assertEqual(runs[0]['field']['rowLength']-runs[1]['field']['rowLength'],24)

    def test_mirrored_field_and_odd_pass_count(self):
        a,b = [simulate_field(Scenario.parse(dict(pattern=True,passes=3,side=s,tight=False))) for s in (1,-1)]
        self.assertTrue(a['metrics']['complete'] and b['metrics']['complete'])
        self.assertEqual(len(a['frames']),len(b['frames']))
        for x,y in zip(a['frames'],b['frames']):
            self.assertAlmostEqual(x['x'],-y['x'],places=6)
            self.assertAlmostEqual(x['z'],y['z'],places=6)
        self.assertEqual(b['field']['rows'],[0,-6,-12])
        self.assertEqual(a['events'][-1]['end'],'North')

    def test_invalid_field_inputs(self):
        for data in (dict(passes=1.5),dict(passes=True),dict(passes=33),
                     dict(headlandRows=-1),dict(headlandRows=2.5),dict(pattern='true'),
                     dict(pattern=True,turnType='reedsShepp'),dict(pattern=True,entry=True),
                     dict(pattern=True,fieldLength=100,headlandRows=6)):
            with self.subTest(data=data), self.assertRaises(ValueError):
                Scenario.parse(data)

    def test_production_patterns_visit_each_row_once(self):
        for pattern in ('alternating','lands','racetrack'):
            r=compare(dict(pattern=True,passes=8,rowPattern=pattern,headlandRows=9,fieldLength=240))['baseline']
            self.assertTrue(r['metrics']['complete'])
            self.assertEqual(sorted(r['field']['order']),list(range(1,9)))
            self.assertEqual(len(r['turns']),7)
            if pattern!='alternating':
                self.assertNotEqual(r['field']['order'],list(range(1,9)))
            for a,b in zip(r['frames'],r['frames'][1:]):
                self.assertLessEqual(math.dist((a['x'],a['z']),(b['x'],b['z'])),.301)

    def test_pw100_twelve_nine_headlands_fit_and_unsafe_extension_is_rejected(self):
        r=compare(dict(pattern=True,width=5.6,length=12.3,radius=9,front=5.9,back=19.6,
                       clearance=20.7,tightDistance=1,headlandRows=9,fieldLength=160,
                       drill=False,enforceBoundary=True,extension=20))
        self.assertTrue(r['baseline']['metrics']['complete'])
        self.assertNotIn('blocked',r['baseline'])
        self.assertTrue(r['experiment']['blocked'])
        self.assertEqual(r['experiment']['paths'],[])
        self.assertGreater(len(r['experiment']['rejectedPath']),100)
        self.assertGreater(len(r['experiment']['rejectedEnvelopes']),0)
        self.assertGreater(r['experiment']['boundaryClearanceNeeded'],0)
        self.assertTrue(r['experiment']['diagnosticPlayback'])
        self.assertFalse(r['experiment']['preview'])
        self.assertGreater(len(r['experiment']['frames']),100)
        self.assertFalse(r['experiment']['metrics']['complete'])
        self.assertIsNone(r['experiment']['metrics']['missedArea'])

    def test_cp_complete_layout_for_both_shapes_and_patterns(self):
        for shape in ('rectangle','irregular'):
            for pattern in ('alternating','lands','racetrack'):
                r=compare(dict(courseLayout=True,fieldShape=shape,rowPattern=pattern,
                               fieldLength=300,fieldWidth=250,headlandRows=4))['baseline']
                self.assertEqual(len(r['layout']['headlands']),4)
                self.assertGreater(len(r['paths'][0]),100)
                self.assertTrue(all(math.isfinite(v) for point in r['paths'][0] for v in point))
                self.assertTrue(r['preview'])
                self.assertIsNone(r['metrics']['missedArea'])
                self.assertEqual(r['layout']['errors'],[])

    def test_configuration_catalogue_preserves_real_values_without_inventing_width(self):
        items=implement_catalogue()['implements']
        self.assertGreater(len(items),100)
        pw=next(i for i in items if i['name']=='pw10012.xml')
        self.assertEqual(pw['overrides']['turnRadius'],'9')
        self.assertEqual(pw['overrides']['raiseLate'],'true')
        self.assertNotIn('workingWidth',pw['overrides'])


class SimulationTests(unittest.TestCase):
    def test_synthetic_flick_reproduced(self):
        r = simulate(Scenario(entry=True))
        self.assertTrue(r['metrics']['complete'])
        self.assertAlmostEqual(r['events'][0]['angle'],45)
        self.assertGreater(r['metrics']['missedArea'],20)

    def test_longer_approach_trades_space_for_alignment(self):
        r = compare({'extension':15})
        a,b = r['baseline']['metrics'],r['experiment']['metrics']
        self.assertLess(abs(b['entry']['lateral']),abs(a['entry']['lateral']))
        self.assertLess(b['missedArea'],a['missedArea'])
        self.assertGreater(b['envelopeDepth'],a['envelopeDepth']+10)

    def test_deterministic(self):
        self.assertEqual(simulate(Scenario()),simulate(Scenario()))

    def test_timestep_convergence(self):
        a = simulate(Scenario(),dt=.025)['metrics']
        b = simulate(Scenario(),dt=.0125)['metrics']
        self.assertAlmostEqual(a['entry']['lateral'],b['entry']['lateral'],delta=.05)
        self.assertAlmostEqual(a['missedArea'],b['missedArea'],delta=.5)

    def test_mirror_without_dynamic_offset(self):
        a = simulate(Scenario(side=1,tight=False))['metrics']
        b = simulate(Scenario(side=-1,tight=False))['metrics']
        self.assertAlmostEqual(a['entry']['lateral'],-b['entry']['lateral'],delta=.01)
        self.assertAlmostEqual(a['missedArea'],b['missedArea'],delta=.1)

    def test_steering_proxy_matrix(self):
        for radius,hitch,articulated in ((9,2,False),(6,2,False),(4,2,False),(7,3,True),(6,3,True)):
            for side in (-1,1):
                with self.subTest(radius=radius,side=side):
                    r = simulate(Scenario(radius=radius,hitch=hitch,articulated=articulated,side=side))
                    self.assertTrue(r['metrics']['complete'])
                    self.assertTrue(all(math.isfinite(f['x']) for f in r['frames']))

    def test_lowering_delay_and_no_precommand_coverage(self):
        r = simulate(Scenario())
        command,active = r['events'][-2:]
        self.assertGreaterEqual(active['time']-command['time'],2)
        self.assertFalse(any(f['lowered'] for f in r['frames']
                             if f['phase'] != 'exit' and f['time']<command['time']))

    def test_full_cycle_exit_and_turn_join_without_teleport(self):
        r = simulate(Scenario(extension=15))
        self.assertEqual(r['frames'][0]['state'],'Exit working')
        self.assertTrue(r['frames'][0]['lowered'])
        self.assertEqual([e['kind'] for e in r['events']],
                         ['Raise requested','Working envelope inactive','Turn started',
                          'Lower requested','Working envelope active'])
        for a,b in zip(r['frames'],r['frames'][1:]):
            self.assertAlmostEqual(b['time']-a['time'],.1)
            self.assertLessEqual(math.hypot(b['x']-a['x'],b['z']-a['z']),.301)
        self.assertEqual(r['metrics']['exitMissedArea'],0)
        self.assertGreater(r['metrics']['exitOvershoot'],0)

    def test_raise_late_and_timer_change_exit(self):
        common = dict(front=5,back=15,clearance=0,raiseSeconds=0)
        early = simulate(Scenario(**common,raiseLate=False))
        late = simulate(Scenario(**common,raiseLate=True))
        self.assertAlmostEqual(late['events'][0]['time']-early['events'][0]['time'],10/3,delta=.06)
        self.assertGreater(late['path'][0]['z'],early['path'][0]['z']+9)
        timed = simulate(Scenario(**{**common,'raiseSeconds':2},raiseLate=True))
        self.assertGreaterEqual(timed['events'][1]['time']-timed['events'][0]['time'],2)
        self.assertGreater(timed['path'][0]['z'],late['path'][0]['z']+5)

    def test_special_turns_drive_without_invented_coverage(self):
        for name in ('reedsShepp','headlandLoop'):
            r = simulate(Scenario(turnType=name))
            self.assertFalse(r['preview'])
            self.assertTrue(r['metrics']['complete'])
            self.assertGreater(len(r['frames']),50)
            if name == 'reedsShepp':
                self.assertTrue(any(f.get('reverse') for f in r['frames']))
            self.assertIsNone(r['metrics']['missedArea'])
            self.assertIsNone(r['metrics']['envelopeDepth'])

    def test_synthetic_entry_has_no_exit(self):
        r = simulate(Scenario(entry=True))
        self.assertFalse(any(f['phase']=='exit' for f in r['frames']))
        self.assertIsNone(r['metrics']['exitMissedArea'])

    def test_headland_does_not_silently_change_manoeuvre(self):
        a = simulate(Scenario(headland=10))
        b = simulate(Scenario(headland=80))
        self.assertEqual(a['path'],b['path'])
        self.assertGreater(a['metrics']['headlandShortfall'],20)
        self.assertEqual(b['metrics']['headlandShortfall'],0)

    def test_no_spurious_comparison_for_controlled_entry(self):
        self.assertIsNone(compare({'entry':True,'extension':15})['experiment'])

    def test_raster_rectangle(self):
        c = Coverage(6,6)
        c.stamp([[3,0],[9,0],[9,-20],[3,-20]])
        self.assertEqual(c.gaps(),[])

    def test_invalid_inputs(self):
        for data in ({'length':0},{'radius':float('nan')},{'side':0},{'side':True},
                     {'drill':'true'},{'unknown':3},{'front':20,'back':10},{'width':True},
                     {'turnType':'unknown'},{'turnType':None},{'raiseSeconds':-1},
                     {'raiseLate':1},{'entry':True,'turnType':'reedsShepp'}):
            with self.subTest(data=data),self.assertRaises(ValueError):
                Scenario.parse(data)

    def test_source_provenance(self):
        r = compare({})
        self.assertIn('scripts/ai/turns/WorkStartHandler.lua',r['sources'])
        self.assertTrue(all(len(h)==64 for h in r['sources'].values()))

    def test_not_shipped_in_mod(self):
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location('build_mod',ROOT/'.github/scripts/build_mod.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for path in Path(__file__).parent.rglob('*'):
            if path.is_file():
                self.assertFalse(mod.is_runtime_file(path.relative_to(ROOT).as_posix()))


if __name__ == '__main__':
    unittest.main()
