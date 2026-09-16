# v0.31 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.131`.

## Live evidence

The v0.30 log from 16 September 21:43:19 identifies row waypoints 135 -> 136.
The goal is (-240.912, -40.060), heading -180 degrees. It detects the missing
field boundary after stopping, then searches from 21:43:26 to 21:44:09 before
exhausting 1,384 trials. The target is known; preparation timing is wrong.

`updatePreparation` permanently marked preparation done when a loaded course
had no cached field polygon. Detection is now requested asynchronously while
finishing the row; subsequent updates resume preparation once it is available.
No implement command or path installation happens during speculation. Folded
geometry is still measured and validated before driving the selected turn.

The log also records a soil-density rejection at (-226.000, 6.000), inside the
detected polygon. The envelope adapter required every perimeter sample to be
field ground as well as inside the boundary. Stock `PathfinderConstraints`
treats off-field ground as a cost for analytic paths, separately from collisions.
The adapter now defines containment through the detected field and its islands,
with the same clearance reserve. Soil classification is no longer a hard veto.
This does not add collision detection or claim that a field polygon detects
every physical obstacle; existing live CP controls still apply.

## Permanent replay and limits

`t7-v030-detected-field.json` contains the 24 logged vertices. `configureV030Exit`
uses the logged start/goal, pivot, 85-degree numerical joint limit and measured
folded footprint: implement x -3.977/3.830, z -5.311/11.166 relative to its direction
frame, and tractor x -1.400/1.400, z -1.056/3.894. The implement hitch in that frame
is (0.003, 11.259). These replace the previous approximate footprint and inset
course-boundary proxy for this case.

The exact density map is not captured. A regression deliberately reports false
soil membership everywhere while retaining the real polygon, proving soil state
cannot veto otherwise contained geometry. Separate tests require polygon and
island rejection. Later unfolding uses the existing working-state proxy; steering
and terrain dynamics remain planar approximations. The live run still needs
confirmation; this is not a claim to reproduce all GIANTS physics.

## Validation

Results are recorded in `out/v031-regressions.txt` and `out/v031-package.txt`.
The package audit includes two additional measured-exit cases, normal and delayed
steering, through deployment, handover and at least 8 m of subsequent work.
First/Last/Nearest startup and CP speed settings are unchanged. The scheduled
monitor remains paused.

All 99 regression tests and all 45 packaged execution cases passed. ZIP/source
parity, integrity and unchanged stock transport-start source were verified.

ZIP SHA-256: `c9c7b707a21a551589d28bcd1ac9ae21f90770f5c5f7e4bc4bdf44dc8058b7fa`.
