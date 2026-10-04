"""Execute the real queue policy with controlled fleet snapshots (not game physics)."""
from pathlib import Path
import random
import sys
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
    ROOT = Path(sys.argv.pop(1)).resolve()


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / 'scripts/ai/CpUnloaderQueuePolicy.lua').read_text())
        self.policy = self.lua.globals().CpUnloaderQueuePolicy

    def table(self, value):
        if isinstance(value, dict):
            return self.lua.table_from({k: self.table(v) for k, v in value.items()})
        if isinstance(value, list):
            return self.lua.table_from([self.table(v) for v in value])
        return value

    def combine(self, ident='c1', **kw):
        return dict(id=ident, capacity=20000, fill=12000, rate=40, callPercent=80,
                    **kw)

    def trailer(self, ident='t1', **kw):
        return dict(dict(id=ident, capacity=32000, fill=0, departPercent=85,
                         enabled=True, available=True,
                         compatible={'c1': True, 'c2': True, 'c3': True}), **kw)

    def plan(self, combines, trailers, etas=None):
        etas = etas or {}
        return self.policy.plan(self.table(combines), self.table(trailers),
                                lambda t, c: etas.get((t.id, c.id), 20))

    def test_partial_trailer_preferred_when_both_timely(self):
        p = self.plan([self.combine()], [self.trailer(), self.trailer('t2', fill=9000)])
        self.assertEqual(p.leads.c1.trailer, 't2')

    def test_late_partial_does_not_delay_available_empty(self):
        p = self.plan([self.combine()], [self.trailer(), self.trailer('t2', fill=9000)],
                      {('t2', 'c1'): 120})
        self.assertEqual(p.leads.c1.trailer, 't1')

    def test_unknown_rate_prepares_without_suppressing_native_call(self):
        c = self.combine(); c['rate'] = 0
        self.assertEqual(self.policy.deadline(self.table(c)), 0)
        p = self.plan([c], [self.trailer()])
        self.assertEqual(p.leads.c1.trailer, 't1')

    def test_native_reverse_clearance_not_available(self):
        p = self.plan([self.combine()], [self.trailer(available=False)])
        self.assertIsNone(p.leads.c1)
        self.assertIsNone(p.trailers.t1)

    def test_capacity_and_compatibility(self):
        for trailer in [self.trailer(fill=27200), self.trailer(compatible={}),
                        self.trailer(enabled=False), self.trailer(failed=True)]:
            self.assertIsNone(self.plan([self.combine()], [trailer]).leads.c1)

    def test_nearby_busy_trailer_can_cover_one_future_combine(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1000
        c2 = self.combine('c2')
        t1 = self.trailer(owner='c1', available=False, fill=8000,
                          transferring=True, transferRate=300)
        p = self.plan([c1, c2], [t1, self.trailer('t2')],
                      {('t2', 'c2'): 60})
        self.assertEqual(p.leads.c2.trailer, 't1')
        self.assertTrue(p.leads.c2.future)
        self.assertTrue(p.trailers.t2.pool)

    def test_distant_busy_trailer_does_not_cover_next_combine(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1000
        t1 = self.trailer(owner='c1', available=False, fill=8000,
                          transferring=True, transferRate=300)
        p = self.plan([c1, self.combine('c2')], [t1, self.trailer('t2')],
                      {('t1', 'c2'): 200})
        self.assertEqual(p.leads.c2.trailer, 't2')
        self.assertIsNone(self.plan([c1,self.combine('c2')],[t1],
                                   {('t1','c2'):200}).leads.c2)

    def test_future_reservation_expires_when_transfer_stops(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1000
        t1 = self.trailer(owner='c1', available=False, fill=8000,
                          transferring=True, transferRate=300)
        fleet = [t1, self.trailer('t2')]
        self.assertTrue(self.plan([c1, self.combine('c2')], fleet).leads.c2.future)
        t1['transferring'] = False
        self.assertEqual(self.plan([c1, self.combine('c2')], fleet).leads.c2.trailer, 't2')

    def test_projected_departure_disallows_future_reservation(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 14000
        t1 = self.trailer(owner='c1', available=False, fill=15000,
                          transferring=True, transferRate=300)
        p = self.plan([c1, self.combine('c2')], [t1, self.trailer('t2')])
        self.assertEqual(p.leads.c2.trailer, 't2')

    def test_only_one_future_reservation_per_trailer(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1000
        t1 = self.trailer(owner='c1', available=False, fill=1000,
                          transferring=True, transferRate=300)
        p = self.plan([c1, self.combine('c2'), self.combine('c3')], [t1])
        self.assertEqual(len(list(p.leads.items())), 1)

    def test_full_current_trailer_has_successor_prepared(self):
        c = self.combine(owner='t1')
        p = self.plan([c], [self.trailer(fill=26000, owner='c1', available=False),
                            self.trailer('t2')])
        self.assertIsNone(p.leads.c1)
        self.assertEqual(p.successors.c1.trailer, 't2')

    def test_unassigned_trailers_leave_start_as_pool_members(self):
        p = self.plan([], [self.trailer(), self.trailer('t2')])
        self.assertTrue(p.trailers.t1.pool)
        self.assertTrue(p.trailers.t2.pool)

    def test_all_native_setting_values_close_progressively(self):
        for level in range(60, 91, 5):
            c = self.combine(); c['callPercent'] = level
            gaps = []
            for fill in range(0, 20001, 500):
                c['fill'] = fill
                gaps.append(self.policy.lag(self.table(c), 24, 15, 3))
            self.assertEqual(gaps, sorted(gaps, reverse=True))
            self.assertGreaterEqual(min(gaps), 36)
        for level in range(40, 101, 5):
            t = self.trailer(departPercent=level, fill=32000*level/100)
            self.assertIsNone(self.plan([self.combine()], [t]).leads.c1)

    def test_fleet_permutation_does_not_change_assignments(self):
        combines = [self.combine('c1'), self.combine('c2')]
        trailers = [self.trailer('t1'), self.trailer('t2'), self.trailer('t3')]
        for _ in range(20):
            random.Random(_).shuffle(combines); random.Random(_+1).shuffle(trailers)
            p = self.plan(combines, trailers)
            self.assertEqual(p.leads.c1.trailer, 't1')
            self.assertEqual(p.leads.c2.trailer, 't2')

    def test_generated_snapshots_never_double_book_or_reassign_native_owner(self):
        rng = random.Random(2989)
        for _ in range(1000):
            combines = [self.combine(f'c{i}') for i in range(1, 4)]
            trailers = [self.trailer(f't{i}', fill=rng.randrange(32001),
                                    available=rng.choice([True, False])) for i in range(1, 6)]
            for c in combines:
                c.update(fill=rng.randrange(20001), rate=rng.choice([0, 10, 40, 120]),
                         callPercent=rng.randrange(60, 91, 5))
            p = self.plan(combines, trailers)
            chosen = [a.trailer for _, a in p.leads.items()]
            self.assertEqual(len(chosen), len(set(chosen)))
            for ident in chosen:
                t = next(t for t in trailers if t['id'] == ident)
                self.assertTrue(t['available'])
                self.assertLess(t['fill'], t['capacity']*t['departPercent']/100)

    def test_sequence_transfer_reservation_clearance_and_next_assignment(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1200
        c2 = self.combine('c2'); c2['fill'] = 8000
        t1 = self.trailer(owner='c1', available=False, fill=8000,
                          transferring=True, transferRate=300)
        t2 = self.trailer('t2')
        total_transferred = 0
        # Engine boundary supplies measured transfer; policy must retain current
        # ownership and reserve just the next job throughout the transfer.
        for second in range(5):
            p = self.plan([c1,c2], [t1,t2])
            self.assertEqual(p.leads.c2.trailer,'t1')
            self.assertTrue(p.leads.c2.future)
            self.assertIsNone(p.leads.c1)
            amount = min(300,c1['fill'])
            c1['fill'] -= amount; t1['fill'] += amount
            total_transferred += amount
            c2['fill'] += c2['rate']
        self.assertEqual(total_transferred,1200)
        self.assertEqual(t1['fill'],9200)
        # Native clearance owns the tractor even after the association clears.
        c1.pop('owner'); t1.pop('owner'); t1['transferring'] = False
        p = self.plan([c2], [t1,t2])
        self.assertEqual(p.leads.c2.trailer,'t2')
        t1.update(reservedFor='c2',releaseIn=5)
        p = self.plan([c2],[t1,t2])
        self.assertEqual(p.leads.c2.trailer,'t1')
        self.assertTrue(p.leads.c2.future)
        t1['available'] = True
        self.assertEqual(self.plan([c2],[t1,t2]).leads.c2.trailer,'t1')

    def test_faults_revoke_future_coverage_in_next_snapshot(self):
        c1 = self.combine(owner='t1'); c1['fill'] = 1000
        c2 = self.combine('c2')
        for fault in ['failed','incompatible','stopped','removed','late','full']:
            t1 = self.trailer(owner='c1',available=False,fill=8000,
                              transferring=True,transferRate=300)
            fleet = [t1,self.trailer('t2')]
            self.assertEqual(self.plan([c1,c2],fleet).leads.c2.trailer,'t1')
            etas = {}
            if fault == 'failed': t1['failed'] = True
            if fault == 'incompatible': t1['compatible'] = {'c1':True}
            if fault == 'stopped': t1['transferring'] = False
            if fault == 'removed': fleet.pop(0)
            if fault == 'late': etas[('t1','c2')] = 1000
            if fault == 'full': t1['fill'] = 32000
            self.assertEqual(self.plan([c1,c2],fleet,etas).leads.c2.trailer,'t2',fault)

    def test_cross_field_or_unreachable_eta_never_reserves(self):
        for eta in [float('inf'),float('nan'),-1,None]:
            p = self.plan([self.combine()],[self.trailer()],{('t1','c1'):eta})
            self.assertIsNone(p.leads.c1)

    def test_deadline_priority_with_insufficient_trailers(self):
        c1 = self.combine(); c1['fill'] = 10000
        c2 = self.combine('c2'); c2['fill'] = 17500
        self.assertEqual(self.plan([c1,c2],[self.trailer()]).leads.c2.trailer,'t1')

    def test_waiting_combine_wins_equal_deadline(self):
        c1 = self.combine(); c1['fill'] = 17000
        c2 = self.combine('c2',waiting=True); c2['fill'] = 19900
        p = self.plan([c1,c2],[self.trailer()])
        self.assertEqual(p.leads.c2.trailer,'t1')

    def test_urgent_successor_not_starved_by_lower_priority_lead(self):
        c1 = self.combine(owner='t1',waiting=True); c1['fill'] = 19000
        c2 = self.combine('c2'); c2['fill'] = 4000
        fleet = [self.trailer(owner='c1',available=False,fill=31000),self.trailer('t2')]
        p = self.plan([c1,c2],fleet)
        self.assertEqual(p.successors.c1.trailer,'t2')
        self.assertIsNone(p.leads.c2)

    def test_end_of_work_does_not_prepare_unneeded_successor(self):
        c = self.combine(owner='t1',hasMoreWork=False); c['fill'] = 1000
        p = self.plan([c],[self.trailer(owner='c1',available=False,fill=27000),self.trailer('t2')])
        self.assertIsNone(p.successors.c1)
        self.assertTrue(p.trailers.t2.pool)

    def test_existing_reservation_resists_small_eta_fluctuations(self):
        fleet = [self.trailer(),self.trailer('t2',reservedFor='c1')]
        for eta in [18,20,22,24]:
            self.assertEqual(self.plan([self.combine()],fleet,{('t2','c1'):eta}).leads.c1.trailer,'t2')
        self.assertEqual(self.plan([self.combine()],fleet,{('t2','c1'):60}).leads.c1.trailer,'t1')

    def test_mutations_are_detected_by_behavioural_assertions(self):
        source = (ROOT / 'scripts/ai/CpUnloaderQueuePolicy.lua').read_text()
        original = self.policy
        cases = [
            ('if a.partial ~= b.partial then return a.partial end',
             'if a.partial ~= b.partial then return not a.partial end',
             self.test_partial_trailer_preferred_when_both_timely),
            ('elseif not trailer.available then','elseif false then',
             self.test_native_reverse_clearance_not_available),
            ('arrival > deadline or free <', 'false or free <',
             self.test_distant_busy_trailer_does_not_cover_next_combine),
            ('used[best.trailer] = true','used[best.trailer] = false',
             self.test_only_one_future_reservation_per_trailer),
        ]
        for before,after,assertion in cases:
            self.assertIn(before,source)
            self.lua.execute(source.replace(before,after))
            self.policy = self.lua.globals().CpUnloaderQueuePolicy
            with self.assertRaises(AssertionError,msg=f'Mutation survived: {before}'):
                assertion()
        self.policy = original


if __name__ == '__main__':
    unittest.main()
