# Straight Entry + Loop Test v0.17

ZIP identity: `FS25_Courseplay_StraightEntryTest.zip`.
In-game title: `CoursePlay - Straight Entry + Loop Test v0.17`.
Manifest version: `8.1.0.305`.

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

The release gate runs 44 straight-entry regressions, 17 loop regressions, six
packaging tests, runtime Lua compilation, deterministic source packaging and
both suites again against the extracted ZIP. The numbered archive and stable
copy are written only under `dist/straight-entry-double-pivot`; existing test
build folders and the live `FS25_Courseplay.zip` are untouched.

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

Added regressions use saved PW100 waypoints 4411–4423: the old tangent fails the
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
