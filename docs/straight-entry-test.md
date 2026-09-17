# Straight Entry Test v0.10

ZIP identity: `FS25_Courseplay_StraightEntryTest.zip`.
In-game title: `CoursePlay - Straight Entry Test v0.10`.
Manifest version: `8.1.0.210`. Keep this ZIP filename for subsequent builds.
Enable only this Courseplay version in the test save. Packaging does not write
to the installed mods folder or overwrite either previous Courseplay ZIP.

## Change

v0.10 replaces the additional tractor-to-plough 15-degree gate with a
five-degree tractor-to-row check. The plough can remain angled relative to the
tractor while centred; requiring matching headings could consume the approach.
CP's existing plough-to-row check (30 degrees, or a lowering request) remains.
Turnover starts once the tractor is pointing into the row, then the animation
pause preserves the remaining approach. This is a turn-phase condition, not a
measurement or guarantee of tyre/plough collision clearance. Bulb geometry,
configured speeds, mounted turnover and reverse entry are unchanged.

The v0.09 log is saved under `out/v009-turnover/game.log`. The waypoint 544
turn began turnover at 22:20:43.454, with roughly 28 m of approach remaining.
The waypoint 580 turn waited until 22:23:00.685, almost at work start. The log
has no hitch-angle samples, so it does not prove a particular frame offset.
The captured PW100 has several component directions; the previous test fixture
incorrectly treated its root and tractor headings as matching on entry.
A regression with unequal headings fails on v0.09 and passes on v0.10.
Tests cover both turn sides, three speeds, five plough headings, continued
movement before alignment, one animation request, no premature lowering, and
six world headings including wrapping through 180 degrees.

Historical changes below describe the earlier builds; v0.10 supersedes the
v0.09 extra 15-degree gate.

v0.09 increases the crossing extension from about 2.41 m to 2.80 m for the
9 m radius, 5.6 m width PW100 combination when there is enough approach distance.
The radius, field corridor checks and reserved straight approach are unchanged.

Forward towed-plough turnover now also requires the plough and tractor directions
to be within 15 degrees. The tractor continues at CP's configured speed while
closing that angle; a lowering request cannot override this check. Once turnover
starts, the existing animation pause still preserves the remaining approach.
Mounted-plough and reverse-entry turnover handling remain as before. This is
an articulation allowance, not a physical swept-volume collision guarantee.

The saved v0.08 log under `out/v008-turnover/game.log` shows PW100 turnover
starting at 22:03:01.584 and the animation pause holding the combination while
still angled. The user reports the plough catching the tractor at this point.
New tests cover both sides, three CP speeds, a late lowering request, continued
movement before turnover, and mounted-tool compatibility.

v0.08 removes all appended entry kicks, including startup kicks. The approach
into work is straight again. For calculated Dubins bulbs, it preserves the
original sampled curve up to its final quarter-circle, extends the crossing
tangent beyond the row, and returns with two tangent arcs of the original radius.
The crossing extension is limited by work width, steering length and available
run-in distance. It reserves 1.5 steering lengths plus hydraulic lead before work.
For a 9 m radius and 5.6 m width, the v0.08 maximum extension was about 2.41 m (2.80 m in v0.09).

This applies to calculated bulbs with at least a quarter-circle at their end.
Mounted tools, short final arcs and entries without sufficient run-in retain
their existing geometry. Pathfinder routes and startup alignment curves retain
their existing shapes, with no kicks; they are not deformed after obstacle checks.
There are no fixed driving speeds or new lateral-error stopping gates.

Startup run-in targets are limited to the contiguous field corridor. Row turns
also constrain their pathfinder targets. Calculated turns outside that corridor
use constrained pathfinding; analytic pathfinder connections cannot bypass the
boundary rule. Completed routes, including entry curves and startup fallback
routes, are checked before use. Failure to find a fitting route stops the job
instead of driving an unchecked fallback.

The corridor uses CP's field polygon and islands with a half-work-width/vehicle-
width margin, sampled along segments. It is not a full articulated swept-body
simulation and does not guarantee physical tracking against tyre slip. When CP
has no field polygon, the boundary helper cannot enforce this constraint. A
start outside the corridor is not supported by this constrained approach.

v0.05 gives mounted equipment a short approach on calculated/pathfinder row
turns and alignment-course startup: half the turning radius plus CP's hydraulic
lead at the configured turn speed. Lowering on those forward entries requires
the tractor direction to be within five degrees of the row. It keeps driving
while aligning; there is no stationary alignment wait. Mounted equipment gets
no outward bow. Stock K-turn generation and headland-corner coverage are outside
this change; stock reverse lowering and close direct-start decisions remain.

This focused build extends the approach before work on ordinary trailed
row turns. It starts from clean main (`9b915b07`), not the retired envelope
planner. Stock CP still selects and follows the turn and controls driving speed
and raising. First/Last/Nearest waypoint selection is unchanged.

v0.03 applies the same allowance to the drive-to-start pathfinder target and
fallback alignment route. StartRowOnly also observes turnover completion before
using that approach. This changes the approach to CP's selected waypoint, not
the selected waypoint or stock close-enough direct-start decision.

For extended forward entries, v0.02 pauses while the plough's turnover animation
is active, preserving the remaining approach for straightening in its working
position. Lowering waits for turnover to finish. There is no fixed wait duration:
the approach resumes at CP's configured speed when the animation finishes.
Stock reverse entry retains its existing lowering and direction-change sequence;
towed ploughs deliberately remain centred until lowering in that sequence.

The approach allowance uses CP's measured steering length and a passive-trailer
straightening estimate from 90 degrees to five degrees, plus its configured
turn-speed/hydraulic lowering allowance. The estimate is a planning allowance,
not a live alignment gate or a claim to model every attachment arrangement.
Both calculated and pathfinder row turns receive the earlier target. Stock
field fitting can introduce more reversing where the extended turn needs it.
If a calculated turn cannot fit the extra approach and reversing is unavailable,
it explicitly logs that it is retaining the stock approach.

Eleven runtime files change. No extra planner, fixed driving speed,
boundary-stop controller or strict lateral-error gate is introduced.

## Evidence and checks

Every release must have a clean source commit containing its code, tests and
release notes. The builder rejects uncommitted changes, preserves each numbered
ZIP under `history/<manifest version>/`, and records the commit and SHA-256 in
`build.json`. An existing version cannot be replaced by different source or ZIP
bytes. The stable test filename remains available for normal installation.

The v0.05 candidate was reconstructed from the recorded source patches and its
original 23 regression tests after its ZIP had been overwritten. It is recorded
on `codex/straight-entry-v005`; this is a recovered snapshot, not an original
release-time commit or a claim of byte-for-byte identity with the original ZIP.

Baseline: the second stock turn in the 17 September recording and saved log.
Lowering starts at 15:49:39.149; fieldwork handover occurs at 15:49:43.390;
work resumes at 15:49:45.921. The video shows the curved entry settling into a
straight worked edge. The log is preserved locally under
`out/entry-video-155015/game.log`.

Run `tools/straight-entry/build_test.py` with Python and `lupa` installed.
The release gate runs packaging tests, 31 regression tests, Lua compilation,
source-scope verification, ZIP byte comparison and the same regressions against
the extracted ZIP before publishing it.

The regressions run production CP course generation, Dubins, tight-turn offsets,
field fitting and target integration through a planar GIANTS test boundary.
They cover 288 combinations of length, speed, available forward room, direction
and row stagger; eight variants of the two recorded turns' scalar geometry;
front/rear markers, unmodified corner targets, short mounted targets, reverse restrictions,
pathfinder target forwarding and configured speed selection. The recorded
geometry cases retain more straight approach than stock and explicitly check
1.5 steering lengths of straight travel before hydraulic lowering after field fitting.

The v0.01 failure after nine headlands is preserved in
`out/nine-headland-failure/game.log`. Turnover began at 17:33:02.529, lowering
at 17:33:06.888 and completed-rotation offset update at 17:33:09.541. Much of
the approach was consumed while turnover was running. New tests exercise the
production plough controller, work-start handler and turn speed handling across
54 speed/side/animation-duration/frame-interval combinations, consecutive turns,
multiple implements, late turnover and stock reverse entry.

The v0.02 log contains 36 turnover waits followed by 36 returns to fieldwork;
the user confirmed these turns worked. The restart at 19:53:27 still requested
the stock -12.6 m startup offset. This log is preserved in
`out/startup-v002/game.log`. Startup tests now cover 54 combinations of steering
length, CP speed, front marker position and selected waypoint through the real
startup strategy and analytic route generator, plus StartRowOnly construction,
turnover waiting, configured-speed resumption and lowering handover.

The bulb tests verify the original prefix is unchanged, both turn directions,
three turning radii, continuous joins without radius reduction, crossing beyond
the row, exact lateral/heading rejoining, and the available-forward-distance cap.
They also check boundary rejection where the original bulb fits but the widened
return does not. An independent passive-trailer integration shows reduced final
lateral error on both sides for 12.5 m and 20 m steering lengths in the example
geometry. This is not a measured working-edge controller or proof of FS25 physics.
Startup and row-entry tests verify the old kicks have been removed.

The Deutz 6210 TTV/Cenio 4000 Super log at 20:37:23.457 shows lowering during
the final curve of the calculated turn (steering length zero, radius 4.7 m).
The preceding marker sample was still unaligned, 1.8 m sideways. The snapshot
is in `out/mounted-entry-v004/game.log`. Mounted tests check the five-degree
threshold on both sides at three speeds, continued movement while aligning,
reverse-entry compatibility and the shorter speed-scaled approach.

Boundary tests cover shortened run-in targets, corridor clearance, an island
crossed between two valid waypoints, analytic-node boundary enforcement,
rejection of unsafe startup success/fallback paths, and calculated-turn
selection of constrained pathfinding. These do not reproduce the game's map
or prove that a particular live route is feasible.

An independent numerical passive-trailer calculation checks the distance
estimate with both articulation signs and a 15% length perturbation. This is
not an independent FS25 vehicle simulator. Animation state is supplied by a test
boundary, not the game engine. Braking, map collisions, tyre slip, hydraulic
physics, complete articulated chains and actual work coverage still require
in-game verification. Passing route tests must not be described as validated
driving cases or proof that every implement now enters straight.

The broader live-entry controller in `stock-cp-entry-design.md` remains a future
design. This build tests stock-turn placement and turnover ordering; it does not
provide live working-edge alignment verification.
