# Implement envelope turn planner

Development branch: `codex/implement-envelope-turns`.

## Accepted behaviour

- Plan backwards from an aligned working entry, for pikes and ordinary rows.
- Check every working implement's angle and front/rear edge displacement. A
  parallel implement displaced from the row is not aligned.
- Finish the curve far enough before entry for the coupled implements to settle.
  Explore longer outgoing travel, lateral sweeps and longer incoming straights.
- Use additional headland space where useful, checking the complete swept rig
  against the field and obstacles. Never make an unsafe candidate appear feasible
  by suppressing its clearance diagnostic.
- Keep implements raised until aligned; schedule hydraulic movement so the front
  soil-engaging edge starts work at entry. Preserve rear-edge clearance on exit.
- Treat hydraulic delay, loss of alignment and the point of boundary crossing as
  separate conditions. Define an explicit stop/replan outcome if no safe entry
  exists; do not merely lower late and leave an unreported gap.
- Derive behaviour from current attached geometry, not model-specific turn paths.
  Keep the original CP path available for comparison.

## First implementation

`tools/turnbench/alignment.py` assesses the entire rectangular working envelope
and estimates a straightening distance for one passive trailer, including the
rear working marker. Tests cover mounted/trailed envelopes, displaced rows,
rotated pike entries and independent numerical trailer integration.

The 2-degree and 0.1-metre defaults are provisional bench acceptance criteria,
not industry standards. The distance calculation assumes the tractor has already
reached the incoming row heading and centreline. It does not validate a turn,
drawbar clearance, articulated steering or multiple joints.

## Next integration

1. Generate candidate approaches and Dubins connections using the actual row
   endpoint and inner-boundary segment, with both turn directions where suitable.
2. Propagate the coupled geometry through each candidate; reject joint-limit,
   obstacle and swept-boundary violations before ranking feasible candidates.
3. Use alignment at the lowering decision and at first working contact to assess
   candidates, including wide tools crossing a sloping boundary progressively.
4. Expose an experimental planner in the bench alongside CP baseline playback.
   Test PW 100-12, mounted tools and 4/6/12 m drills on straight and pike entries,
   small and large headlands, and infeasible cases.
5. Only integrate the selected behaviour into in-game execution once the bench
   comparisons pass; the offline motion model remains an approximation.
