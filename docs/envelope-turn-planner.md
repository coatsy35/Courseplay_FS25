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

## Working bench prototype — 14 September 2026

Choose **Field & pattern → Run mode → Aligned entry comparison**, or open the
bench with `?mode=aligned`. The CP baseline remains available in its own tab.
Set the configuration, then start playback. This is a bounded row-end test,
not full-field or in-game integration.

The steering-led candidate joins CP's Dubins path to a curved lateral pull-in.
It solves for the rear working edge's displacement, rather than merely waiting
for trailer yaw to decay on a long straight. The cubic pull-in is bounded by the
selected turning radius. Candidates are simulated at 50 ms, and accepted results
are verified again at 25 ms with every turn pose retained for footprint checks.

Acceptance requires aligned front/rear working edges at lowering and entry,
alignment throughout the working sample, hydraulic readiness at first contact,
completed tracking and 0.5 m clearance around the modelled tractor/implement.
Lowering is cancelled if alignment is lost before contact. Hydraulic travel can
require braking before the boundary. Pike coverage is measured along the sloping
inner boundary, including its triangular ends.

The search starts with shorter curved approaches. More available headland permits
a modestly longer final straight and outward turn placement. It is a bounded
candidate search, not a proof of the globally smallest turn or headland.
With reversing enabled, Reeds–Shepp K-type candidates are also tested; feasible
K candidates and the forward result are compared by depth, then distance.

Verified examples with the logged PW geometry and 9 m CP minimum radius:

| Case | Final straight | Modelled envelope depth |
| --- | ---: | ---: |
| Straight, nine headlands | 4 m | 43.2 m |
| 25° pike, adjacent row | 4 m | 39.4 m |
| Larger headland, eighteen rows | 8.3 m | 48.0 m |
| Short pike to row twelve widths away (31.3 m farther out) | 4 m | 32.8 m |

**Rows across to next pass** tests the last case: the target is the actual next
row endpoint, not a fixed offset from the short row. The rig travels across and
farther along the headland before returning. All these cases pass the modelled
boundary check and show no sampled entry gap. Tests also cover mounted pikes,
4/6/12 m drills, opposite pike directions, insufficient headland, and a mounted
K-turn in four 5.6 m headland widths.

## Remaining limits and next integration

- The 85° articulation ceiling is a provisional test limit, not a captured safe
  drawbar angle. Actual joint stops, body interference, steering modes and chained
  implements still require measured geometry. In-game operation is unchanged.
- Reversing candidates track an analytic tractor path in the planar model;
  trailer propagation can reject a compact tractor-only K-turn as a jackknife.
  The PW K candidates tested here fail; mounted K candidates can pass.
- The rectangular working envelope and planar motion are approximations. No
  claim of GIANTS physics parity or drawbar collision certification is made.
- Integrate the candidate selection with actual generated full-field row ends,
  captured joint constraints and runtime stop/replan behaviour before enabling
  this planner in the game. Headland corner playback still uses the CP baseline.
