# v0.30 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.130`.

## Evidence and scope

The 16 September v0.29 log records turn 135 -> 136 searching for approximately
45 seconds before exhausting 1,305 broad-search trials. Rejections include 598
joint-angle, 587 field-boundary, 69 entry-alignment and 51 analytic-path failures.
This does not establish that the headland lacks space. Previous successful
runs and the bench route justify investigating the differing live constraints.

The fresh T7.300/PW 100-12 capture confirms the internal drawbar pivot and
tractor-coupling yaw lock. Its declared internal yaw limit is 90 degrees; the
planner's existing 85-degree ceiling is unchanged. The captures and live log
are preserved under `out/v029-capture` and `out/v029-live-stall.log` locally.
A probe using captured declared size and the logged root/direction-frame angle
still finds a route on the saved-course boundary proxy. It is not an exact
reproduction of the detected field or collision footprint.

## Changes

Short-route and broad-route searches now advance alternately in the existing
per-frame budget. A verified short connection need not wait for the broad
catalogue to exhaust. A completed broad solution remains available, and is
preferred if shorter than the direct solution. Exhaustion counts include both
catalogues. There is no new elapsed-time rejection or speed override.

CP logs now record the actual field/island vertices, footprint bounds, hitch
reference, scan completeness and joint limit. On exhaustion they distinguish
polygon clearance, island clearance and field-ground-data rejection, including
the first rejected coordinate for each source. Logs are per measured plan,
not per simulation sample. No clearance or alignment admission was relaxed.
Stock First/Last/Nearest startup remains intact.

## Validation and limitation

All 93 regression tests pass, including search starvation and boundary-source
reporting; `out/v030-final-regressions.txt`. All 43 packaged execution cases
pass, including deployment, fieldwork handover and at least 8 m of subsequent
work. ZIP integrity and packaged Lua/source equality pass.

ZIP SHA-256: `a63d3d89aa8412e2a6340410f600d63c72ad7b7e10bd44d3666460308e8b88e6`.

These checks use production Lua with planar physics and mocked game services.
The live v0.29 rejection remains unresolved until its actual constraints are
recorded. This build improves scheduling and supplies the missing evidence;
it must not be described as a confirmed fix for the live no-path failure.
The scheduled log monitor remains paused.
