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

## Long pikes: 12 m drill, six skipped rows

The browser fixture `?mode=aligned&case=long-pike-12m` uses a 500 m long,
400 m wide field with a flat far end. Six intervening rows are skipped: the
incoming row is 84 m across from the outgoing row. Six headlands (72 m nominal
depth) are held fixed throughout this sweep. **Whole field** switches between
the complete field outline and a closer view of the turn; playback remains an
isolated row-end experiment.

| Angle | Next row end farther out | Absolute entry angle | Modelled envelope depth |
| --- | ---: | ---: | ---: |
| 10° | 14.81 m | 0.20° | 29.06 m |
| 20° | 30.57 m | 0.17° | 28.45 m |
| 25° | 39.17 m | 0.11° | 28.28 m |
| 30° | 48.50 m | 0.01° | 28.28 m |
| 35° | 58.82 m | 0.20° | 28.22 m |
| 40° | 70.48 m | 0.53° | 28.03 m |
| 45° | 84.00 m | 1.11° | 27.77 m |

All seven short-to-long cases complete browser playback with aligned entry,
hydraulic readiness, no sampled entry gaps and no modelled boundary violation.
Each uses a steering-led forward turn with a 5.4 m final straight. The greatest
working-edge error is 3.82 cm at 40°; maximum articulation is 62.1° at 45°.
These are observed results, not a proof of the worst possible angle or minimum
headland requirement.

The 45° long-to-short control also passes, but uses 35 m envelope depth and has
1.15° entry angle with 5.64 cm working-edge error. Direction alone does not make
a turn easier. The coverage simulation continues far enough to finish the full
20 m sample at both sides of the sloping working edge, including the 45° case.
`tools/turnbench/long-pike-angles-test.cjs` checks all eight cases in the browser.

## Complete skipped-row blocks and screenshots

Enable **Complete skipped-row block** in Aligned entry comparison. Seven widths
across selects a 14-row block, skipping six rows and then filling them in CP's
actual order: 1, 8, 9, 2, 3, 10, 11, 4, 5, 12, 13, 6, 7, 14. All 13 turns and
the full intervening working rows are driven continuously. Tractor position,
heading and implement yaw carry through each row; cached poses are never spliced
into the animation. This completes the central working block, not headland work.

Coverage now measures the whole working block at 0.25 m cell centres. Green
shows actual lowered work-envelope sweeps and pink marks uncovered cells. This
reveals outer-edge gaps that the previous 20 m row-end samples could miss.
The PW's 10°, 25°, 30°, 35°, 40° and 45° short-start cases respectively show
0.56, 0.50, 1.44, 0.31, 1.56 and 0.19 m² remaining; 20° shows zero. The 45°
long-start case shows 0.19 m². These gaps remain visible and are not counted as
covered merely because heading/edge alignment passes its tolerance.

The gallery captures 500 × 400 m blocks with the PW (5.6 m, nine headlands),
6 m drill (nine headlands) and 12 m drill (six headlands), at 10°, 20°, 25°, 30°,
35°, 40° and 45° short-start, plus 45° long-start. The drill geometries remain
illustrative. The PW's adjacent-row turns approach the provisional 85° model
articulation ceiling; in-game joint/body constraints still need validation.

Speed changes precompute gear-leg ends and navigation points, avoid redundant
coverage tests, use convex half-plane clearance checks where applicable, and
reuse validated turn parameters. A changed pike angle may start from a prior
valid shape, which is rechecked at 50 ms and 25 ms. Each actual arriving state is
simulated at 25 ms; failure triggers bias refinement or a fresh search. Recorded
turn scenarios preserve the chosen parameters. Warm-start results can differ
from a cold bounded search and do not establish a globally minimum turn.

Four complete results and 64 turn templates are cached in memory. Repeated
identical PW configuration measured 0.69 s calculation / 1.66 s HTTP round trip;
new-angle requests remain longer. Browser coverage uses an incremental backing
canvas. **Show result** jumps straight to the finished coverage; 16×, 32× and
64× playback are available.

Run `node tools/turnbench/coverage-gallery.cjs`, then
`python tools/turnbench/build-coverage-gallery.py` to build the completed coverage
gallery in `out/turn-coverage-gallery`. Captures resume from its `results.json`;
use a fresh output directory when deliberately regenerating every scenario.

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
