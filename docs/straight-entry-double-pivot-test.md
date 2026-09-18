# Straight Entry + Loop Test v0.19

ZIP identity: `FS25_Courseplay_StraightEntryTest.zip`.
In-game title: `CoursePlay - Straight Entry + Loop Test v0.19`.
Manifest version: `8.1.0.307`.

This local test merges straight-entry v0.13 at `7aad509b` with the main-based
double-pivot headland-loop work. It lives on
`codex/pw100-headland-recovery`; neither source branch is modified.

The v0.13 short-headland handover fix prevents CP from skipping a pending corner
when the Quadtrac has already passed the short incoming headland section. All
earlier straight-entry and field-corridor work in that branch is included.

For forward loop turns on headland corners, supported serial wheeled chains use
separate hitch and axle geometry, detected body/working width, articulation,
settling and field-boundary checks. The captured Seed Hawk 84 / PD 1000 drawbar
is now split into approximately 3.78 m and 4.31 m internal links. Candidate loops
check both internal articulation angles, non-adjacent physical bodies and every
modelled working footprint against CP's field polygon. This case stops with CP's
no-path message if the field boundary is unavailable or no safe candidate fits.
The accepted chain route does not apply the old moving 9.7 m tow-bar offset.

CP's configured driving speeds are retained. This is a planar planning test,
not proof of physical drill/cart clearance. Keep collision detection enabled and
inspect the actual hitch motion during the first turn.

The release gate runs 49 straight-entry regressions, 17 loop regressions, six
packaging tests, runtime Lua compilation, deterministic source packaging and
both suites again against the extracted ZIP. The numbered archive and stable
copy are written only under `dist/straight-entry-double-pivot`; existing test
build folders and the live `FS25_Courseplay.zip` are untouched.

## Multi-vehicle final-row connection (v0.19)

Centre-first multi-vehicle courses now connect each vehicle's final offset row
straight ahead to its assigned innermost headland where a valid forward
intersection exists. Connection happens after lane offsets and small-island
bypasses are generated, and accounts for clockwise/counter-clockwise headland
assignment and symmetric lane changes. Row geometry and headland allocation
are retained. Headland-first courses keep their existing generation order.

The same conservative fallbacks as v0.17 remain: no forward intersection,
an endpoint already beyond the assigned headland, or an island connection.
This does not force every connection straight or change driving/turn strategies.
Regenerate saved multi-vehicle courses to get the new connection.

Full-generator regressions cover two to five vehicles, both headland directions,
both lane-change modes, angled rows and one/two headland passes per vehicle.
They verify each lane's alignment, assignment and unchanged row endpoint, and
exercise the outside-row fallback. Additional cases cover headland-first and
zero-headland courses. Existing single-vehicle, recovery and loop tests remain.

## PW100 headland recovery correction (v0.16)

Based on combined v0.15 (`cedcc61d`). The separate v0.13 candidate, branch and
archive remain unchanged. No course-generator nodes or corner-selection rules
are changed.

The 18 September T7.300/PW100 log records a 26 m unchecked straight finishing
course at waypoint 4410, an object blockage, then a successful recovery path.
Its appended tangent diverged from the curved headland; the v0.13 handover guard
correctly refused the resulting unaligned continuation at 14:35:03.

Headland finishing now checks the field corridor up to the selected lifting
marker, ignoring unused reserve waypoints. If that approach leaves the field,
it continues working only to the safe approach limit, with a reserve based on
actual speed (two seconds of travel, at least half the working width), then
raises and starts the existing checked turn. This is a conservative planning
reserve, not a model of tyre grip or guaranteed physical stopping distance.
Early lifting can leave a patch at a constrained corner; inspect coverage in
game. Collision detection remains active.

Forward pathfinder turns now append the actual saved headland when it curves,
stopping before a further marked corner. Straight, reverse, calculated loop and
ordinary row-turn endings retain their previous behaviour. The complete
pathfinder course still passes the existing boundary check before installation.
The v0.13 handover guard is retained.

Added regressions use saved PW100 waypoints 4411�4423: the old tangent fails the
real handover, while the curved continuation passes in both mirrored directions
and five world headings. Tests also cover the next pending corner, unchanged
source points, early/late and mounted markers, unknown field boundaries, and
finishing at 5, 12, 20 and 35 km/h. These are production-Lua planar tests, not an
FS25 physics replay. No running game or installed ZIP is changed by this build.

## Forward row-to-headland connection (v0.17)

New single-vehicle, centre-first courses project the final adjusted row in its
current direction to the first forward intersection with the innermost headland.
An intersection inside an edge splits that edge and becomes the headland start;
an exact existing vertex is reused. This preserves the headland's direction,
perimeter and full circuit instead of choosing a nearby vertex off the row line.
The row's work-end and pathfinding attributes remain intact.

No forward intersection, a degenerate approach, an island approach/bypass or an
already-outside endpoint retains the stock nearest-vertex fallback. The first
exit is used on concave headlands, rather than a distant lobe. Headland-first
and multi-vehicle generation keep their existing selection. Runtime clearance,
turn generation, reversing permissions and field-boundary checks are unchanged;
a geometric intersection alone is not a validated vehicle manoeuvre.

Regenerate a course to use this change; saved courses are not rewritten.
Tests cover the saved JD row/edge coordinates, mirrored and rotated shapes,
exact vertices, concavities, no-hit and island fallbacks, circuit length and
closure, and complete centre-first generation with 1, 3 and 6 headlands in both
directions. The v0.13 archive and its handover safeguards remain preserved.

## Prepare the plough before obstacle recovery (v0.18)

The T7.300/PW100 run on v0.16 stopped at 15:42:45 on 18 September. At 15:40:57,
its lifting marker was still 2 m short of the work end when recovery began.
Recovery bypassed the finishing-row preparation, and headland turns normally
skip plough centring. The driver then exhausted two recovery attempts and the
unaligned handover guard stopped the job. Drawbar contact was reported by the
user; the log cannot independently identify that physical contact.

Recovery now raises the implements before moving. Rotatable ploughs wait for
lifting/rotation permission, request CP's existing synchronised centre event,
and confirm that animation has stopped at the implement's configured centre.
Already-centred and non-rotatable tools require no centring animation. There is
no fixed animation timer or substituted driving speed. Obstacle callbacks do
not consume retries during the deliberate preparation wait. Reverse course
creation and pathfinding happen after readiness, using the resulting pose.
Forward recovery entry also checks rotation readiness before lowering; stock
reverse-entry behaviour remains unchanged.

Tests exercise the real recovery constructors and controller methods with both
working sides, centre positions 0.35/0.5/0.7, delayed lifting permission, running
and stopped-off-centre animations, repeated polling, retries, both pathfinding
permissions and working-side restoration. Existing ordinary-turn tests remain.
This fixes the missing preparation; actual drawbar clearance still needs FS25
confirmation. The change also applies to existing saved courses.

API reference: GIANTS' documented [Plow centring implementation](https://gdn.giants-software.com/documentation_scripting_fs22.php?category=48&class=531&version=script)
uses `spec_plow.ai.centerPosition`; CP already uses its `setRotationCenter()` API
through `PlowCenterTurnEvent`. The published reference is FS22, not an FS25
physics validation.
