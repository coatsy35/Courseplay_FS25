# v0.32 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.132`.

## Failure and correction

The v0.31 run on 16 September exhausted 1,393 candidates at row 135 -> 136.
Its saved T7 settings in savegame18 are 20 km/h turn speed and 27 km/h field
speed. The previous replay used 8 km/h turn speed. Replaying the measured
folded geometry with 20 km/h reproduces planning failure; candidate counts
are not identical to the live run.

Deployment lead included braking distance at the full configured turn speed:
15.43 m at 20 km/h, compared with 2.47 m at 8 km/h. This shifted the geometric
staging target towards the outer boundary. Raising the speed setting could
therefore make a physically unchanged combination appear unable to turn.

Deployment lead is now geometric: implement length/work extent, tracking
lookahead for each of the raised-arrival and working-departure transitions,
and the sloping-row allowance. Speed no longer changes that target. The live
braking calculation uses remaining distance along the selected route, including
its incoming arc, rather than waiting until the final straight. The existing
1 m/s^2 deceleration model and live straightening checks remain in use.
Where a steering response has been measured, stopping distance also allows
95% settling of that response (three time constants). This prevents delayed
steering spending the working-alignment space while the vehicle slows down;
it is a distance-dependent speed calculation, not a fixed speed cap.
CP turn/field settings supply travel speeds; no fixed travel-speed cap is added.

The first revision removed braking distance without retaining enough tracking
space and failed earlier v0.25/v0.26 exits. It was not released. Those cases
remain in the qualification suite alongside the latest failed exit.

Logs now include configured speeds, deployment lead and estimated steering/
trailer response, so future replays need not assume those inputs.

## Validation scope

`configureV031Exit` uses the latest logged pose, the measured folded footprint
and detected polygon from the preceding run, and the actual saved speeds.
Packaged cases include nominal steering and 0.2/0.5 s synthetic steering lag.
Each must unfold once, hand over and complete at least 8 m of subsequent work.
The working deployment state is still a measured proxy from an earlier run;
terrain, tyre and joint physics remain synthetic. In-game confirmation is
still required. First/Last/Nearest startup remains stock CP.

Results: `out/v032-regressions.txt`, `out/v032-package.txt`, and the adjacent
packaged ZIP qualification JSON.

All 102 regression tests and all 48 packaged execution cases passed.
ZIP integrity, every packaged Lua/source pair and stock transport-start source
parity were verified. All three saved-speed cases reached 27 km/h.

ZIP SHA-256: `b82ffe5c81ac86c88fcbe52579c6266b7e4935b0870695233b0e8e5ce2adbea8`.
