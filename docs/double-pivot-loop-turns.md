# Headland loop test 8.1.0.305

Branch: `codex/double-pivot-loop-turns`, based on main `9b915b07`.
This build contains no envelope planner, straight-entry experiment or implement
profile feature changes from the other branches.

## Behaviour

Only CP's forward **loop turns on headland corners** change. Row-end turns,
reverse headland manoeuvres, selected CP speeds and equipment settings remain
unchanged. Enable the existing loop-corner option to exercise this code.

The planner detects a serial chain of wheeled attachments using
their active input hitches and steering axle nodes. Each hitch-to-axle length,
parent axle-to-hitch offset and current implement heading is retained separately.
Declared body dimensions are expanded by the actual working marker extents,
including asymmetric markers. A 25.6 m unfolded drill is therefore not treated
as its 9 m declared transport width.

An implement input drawbar with one internal yaw joint is split at that joint.
The external drawbar and cart axle become separate links, so the Seed Hawk / PD
1000 combination has three modelled articulation points instead of falling back
to the first implement's 9.7 m steering length. This is a planar conservative
approximation: a free drawbar has no axle constraint and its exact motion still
depends on GIANTS physics.

For supported chains, the radius estimate propagates each off-axle hitch
separately. It then considers a bounded set of radius, pull-ahead and straight
approach, testing candidates in analytic-length order until one passes the checks. This is a
bounded search, not a globally shortest-path guarantee. The sum of link lengths
sets the search distances only; it does not replace the separate pivot model.

Each candidate is sampled at at most 0.5 m and two degrees of tractor heading
change. Passive trailer headings are integrated from each parent's actual hitch
displacement. Candidates exceeding the detected external hitch limit (45 degrees when
unknown), or the separate detected internal drawbar limit, are rejected. The drawbar remains a kinematic approximation, not a measured
collision shape. Candidates must also
reach a checked straight return before lowering and settle all headings within
five degrees of the outgoing direction before handing back to fieldwork.
The lowering allowance uses CP's configured turn speed and lowering duration.

Each body's declared physical rectangle and its separate working-marker area are checked
against the boundary and islands, including polygon edges and enclosed islands.
An edge grid limits repeated polygon work. These are sampled planar footprint
checks, not continuous swept-volume or game-physics guarantees. An internal-pivot
loop first uses the job's detected field polygon. If that cache is empty after a
save reload, it uses the saved custom-field boundary or the map field polygon.
The loop is refused only when none of those boundaries is available, so it cannot
silently take the tractor or implements outside an unchecked field. The selected
boundary source and geometry are logged.

Accepted chain routes disable the old moving single-trailer tracking offset,
because changing the route afterwards would invalidate the prediction. CP's
normal driving controller and configured speeds still execute the route.

## Unsupported layouts

Branched attachments, mounted adapters, missing axle/dimension data, off-centre
couplings, actively steered implement axles and multiple or ambiguous internal
yaw pivots do not use
the serial passive-trailer prediction. They use the width-based loop allowance:
the radius is at least half the greater of configured/detected working width,
plus 0.5 m, and pull-ahead uses that width. Stock tracking correction remains.
When a field polygon exists, this route is checked against a width corridor,
including its predicted CP tracking offsets. This is not a full unsupported
chain footprint check.

The existing 16 September capture of Seed Hawk 84 / PD 1000 contains one internal
60-degree yaw joint in the cart's drawbar. The planner now detects that joint and
separately models the approximately 3.78 m drawbar and 4.31 m pivot-to-axle link.
The live 18 September log showed why the former 13.3 m width-only loop was wrong:
it rejected this joint, generated only a 12.8 m pull-ahead and later applied the
old 9.7 m single-trailer offset. The new internal-pivot route disables that moving
offset and is accepted only after articulation, settling, footprint and field
boundary checks.

If no candidate passes the applicable checks, the job stops with CP's existing
no-path message. It does not substitute an unchecked pathfinder route.
The log prefix is `[CP headland loop]`, followed by the selected mode or rejection
reason. Unknown geometry is not silently described as a checked chain.

The captures do not contain collision meshes or a measured safe drawbar angle.
Declared solid-body rectangles are used for adjacent and non-adjacent body intersections;
internal articulation is checked against the detected yaw limit, with separate
non-adjacent body clearance checks. Slopes, tyre
slip, articulated tractor motion and actual tracking require in-game tests. Keep
CP's existing collision detection enabled.

## Release and verification

Run `tools/double-pivot/build_test.py` with Python and `lupa` installed. The release
gate requires committed source; runs the shared packaging tests and the loop
regressions; compiles runtime Lua; checks the runtime diff against main; compares
packaged files with source; verifies deterministic packaging; then repeats the
regressions against the extracted archive before publishing it.

The source manifest retains its release title. The packaged title is
`CoursePlay - Implement Profiles Test`, and the filename stays
`FS25_Courseplay_ImplementProfilesTest.zip`, as requested by the project rules.
The builder writes the numbered archive and commit/checksum receipt under
`history/8.1.0.305/` and a stable filename beside `history/`. Use a separate
`dist/double-pivot-loop-turns` output directory so other branches' test archives
are not overwritten. It never writes to the installed mods folder or the live
`FS25_Courseplay.zip`.

The regressions use real CP Dubins, Course, TurnContext and turn integration with
planar GIANTS adapters. They include independent constant-circle kinematics,
separate link lengths, unfolded widths, internal drawbar geometry, mirrored loops,
settling allowances, field/island checks, rejection without course installation,
preserved configured speeds, cached and map field-boundary checks and the
width-only fallback. They do not claim
successful live driving.

In game, enable only this Courseplay test version. Check both loop directions
with the Seed Hawk/cart setup and with a supported two-trailer chain. Confirm the
logged mode, wider loop, retained speed, corner work coverage and straight return.
Also check a narrow field and an island: a rejected route must stop rather than
cross the boundary. Inspect actual hitch motion and clearance before judging
whether a separate model for the cart's internal drawbar is sufficient.

## Incremental loop search — test 8.1.0.311

The 8.1.0.310 live log records 475 rejected candidates in one update between
18:19:40.695 and 18:19:45.266. Every candidate failed the tractor boundary check.
The previous radius change did not resolve this failure.

Loop planning now has an explicit waiting state. It brakes before recording the
chain pose, prepares at most 16 analytic descriptors per step, and validates at
most 32 footprint samples per step. Runtime yields after a 5 ms budget between
steps (an individual step may exceed that budget); it does not use coroutines.
Course construction is still one bounded operation per candidate. Candidates
are ordered by analytic length including approach and exit distances, and the
search stops at the first validated route. Shorter entry distances and intermediate
radii are now considered. Configured driving speeds remain unchanged.

Boundary validation checks the union of the chassis and working-marker area.
It neither drops the working width nor stretches the entire chassis to that
width. Logs include initial chain geometry and rejection body/waypoint/world
position, along with rejection counts.

The saved Saxlingham corner was replayed with its map outline and approximate
start pose. The old search's universal tractor-boundary rejection was reproduced;
shorter entries admit tractor paths but full-chain checks still reject the replay.
This build addresses calculation stalls and improves diagnostics/search coverage;
it does **not** establish that this particular corner can be driven successfully.
The live initial pose and GIANTS dynamics are still required to resolve that.

The combined local test includes `aad9736b` and the straight-entry baseline.
Its filename remains `FS25_Courseplay_StraightEntryTest.zip`, in its own numbered
top-level folder outside `dist`. Release checks run on source and extracted ZIP.

## Saved-corner geometry correction - combined test 8.1.0.312

This supersedes the unresolved saved-corner result reported for 8.1.0.311.
The tractor curve endpoint was constrained relative to the drill work-start
node as though it were a tractor target. The search now considers tractor
endpoints ahead of that node, checking the predicted working markers remain
before the original lowering line. It separates the raised loop from a checked
straight return long enough for the cart to settle, with five metres of reserve.
The work-start node and configured speeds are retained.

External hitch limits prefer the limits already combined by GIANTS. Otherwise,
the parent output limit is multiplied by the active input-joint scale, following
[GIANTS AIVehicleUtil](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=91&class=881&version=script).
The captured combination gives separate limits of 78, 40 and 60 degrees;
copying the cart internal limit onto its external hitch was incorrect.

Lowering is gated on the actual tractor reaching the straight return, rather
than its lookahead waypoint. Normal stopping while the drill lowers is retained.
The predicted lateral lag supplies a bounded lowering tolerance on this checked
return. Live drill, cart and drawbar headings must align before fieldwork resumes.
A combination that fails to settle within the checked return stops. Motion during
planning invalidates the captured pose and starts a fresh incremental search.
Coarse tractor-boundary rejection avoids unnecessary Course allocations; passing
it still requires the complete sampled chain checks.

The regression fixture uses the saved Saxlingham corner, field outline and
captured hitch, axle and working-marker geometry. It finds an inward left loop
of approximately 171 metres including the straight return. Original, one-metre
forward/backward and mirrored starts pass a finer 0.2-metre full-route check,
including body clearance, independent articulation limits and field boundaries.
All 29 loop regressions pass. This establishes a feasible planar prediction,
not verified live driving: GIANTS tracking, collision meshes and crop coverage
still require the next in-game test.

The combined ZIP includes aad9736b and 7aad509b. Its exact filename remains
FS25_Courseplay_StraightEntryTest.zip, in its own numbered top-level folder.


## Live return and search cost - combined test 8.1.0.313

The 21:29-21:30 live test of 8.1.0.312 spent 21.5 seconds testing 653
candidates. It completed the loop, lowered with the drill still angled, then
stopped at waypoint 173 because the live chain had not aligned within the
predicted return. The log identifies the alignment stop, but did not record
which live node failed it; this release includes that diagnostic.

Keep the complete, validated straight reserve (twice the chain length) instead
of truncating it at predicted settling plus five metres. Planning requires two
degrees at its endpoint; live handover still requires five degrees and can occur
earlier. The field and clearance checks cover the complete reserve. Lowering on
this return requires the working implement itself within five degrees, while
continuing forwards to straighten. Normal sowing-machine lowering stops remain.
This can lower later than the original work-start line: it does not establish
complete corner coverage, and does not add a coverage recovery pass.

The inward loop remains: this change does not claim to avoid existing crop.
The field boundary continues to constrain the complete combination.

Search no longer constructs and enriches Course objects for rejected candidates.
Only the accepted points are converted to a Course. Exact rectangle intersection
uses centre/extent projections, and boundary bounding boxes use the same closed
form rather than allocating corners. A 2,000-case independent corner-projection
regression checks the intersection optimisation. Four saved-corner replays take
about 19 seconds in the local harness, down from about 27 seconds before these
changes; that is not an in-game timing guarantee. The runtime search budget is
8 ms between bounded steps, raised from 5 ms, while stopped for planning.

All source and extracted-ZIP checks are required for this combined release.
Keep the same StraightEntryTest mod identity in its separate numbered folder.


## Checked fieldwork handover - combined test 8.1.0.314

The 21:54:03 log of 8.1.0.313 shows a successful live alignment followed by
"implements lowered, resume fieldwork". The stop came afterwards: the merged
straight-entry guard searched only ten waypoints beyond 476 and could not find
one ahead. This is a separate fault from the earlier cart-alignment stop.
Search time in that run was about 11 seconds, versus 21.5 seconds in 8.1.0.312.

The loop now supplies a continuation waypoint found by physical distance within
its checked return, rather than relying on ten waypoint indices. It does not
search across another corner, reversal, backwards progress or a departing row.
The saved outgoing headland reproduces the old failure and verifies the new
continuation beyond the ten-waypoint window.

Once the drill is aligned and has finished lowering, the turn can hand back
without waiting for the cart to reach five degrees if the outgoing fieldwork
course covers the settling reserve. Before doing so it checks live body
positions, independent hitch angles, clearance and boundary, then simulates the
actual outgoing course from those headings. This matters because the saved
headland bends gently away from the temporary straight. Another regression
checks earlier continuation with a four-degree drill and a trailing cart, and
rejects unaligned working tools, excessive articulation and an intervening corner.

This removes unnecessary temporary-course travel after the drill is ready.
It does not relocate the loop or its work-start line, and does not fix the
remaining late-lowering coverage gap. The inward loop and five-degree drill
lowering gate remain. Live performance and crop coverage still need testing.
