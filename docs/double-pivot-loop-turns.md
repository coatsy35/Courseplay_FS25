# Headland loop test 8.1.0.304

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
approach, retaining the shortest candidate that passes the checks. This is a
bounded search, not a globally shortest-path guarantee. The sum of link lengths
sets the search distances only; it does not replace the separate pivot model.

Each candidate is sampled at at most 0.5 m and two degrees of tractor heading
change. Passive trailer headings are integrated from each parent's actual hitch
displacement. Candidates exceeding a 45-degree relative heading at a conventional
hitch, or 25 degrees at either side of an approximated internal drawbar, are
rejected. The tighter internal limit is a clearance proxy for the missing
collision shape, not the cart's mechanical joint limit. Candidates must also
settle all headings within five degrees of the outgoing direction before the
estimated lowering position.
The lowering allowance uses CP's configured turn speed and lowering duration.

Each body's predicted working rectangle is checked
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
Declared solid-body rectangles are used for non-adjacent body intersections;
the 25-degree internal articulation limit protects the drill/cart coupling where
their declared rectangular envelopes overlap even when straight. Slopes, tyre
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
`history/8.1.0.304/` and a stable filename beside `history/`. Use a separate
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
