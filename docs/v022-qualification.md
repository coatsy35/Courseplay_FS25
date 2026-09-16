# v0.22: initial approach and deployment

Test title: **CoursePlay - Envelope Turns Test v0.22**. Mod version:
**8.1.0.122**. Stable filename: `FS25_Courseplay_EnvelopeTurnsTest.zip`.

## What the live v0.21 recording established

On 16 September, CP found its original initial approach in 273 ms, with its
target 11.6 m behind the first row. Its ordinary handover began preparation
15 metres before the path ended, while the tractor was still turning. The
experimental starter subsequently centred the plough again. Its recovery
examined 312 candidates over 33.3 seconds and rejected them all. This explains
both the unwanted preparation/centring sequence and the long stopped wait.

The saved course's first central row is only 3.09 m long, in a corner with
converging boundaries. Earlier rectangular fixtures did not represent this
starting space. Passing those fixtures did not establish that this start worked.

## Changes

- Retain CP's initial pathfinder, reverse capability and configured radius.
  Choose its target by sampling the straight combination's full width and
  fore/aft extent towards the outer edge. Stop at the first unavailable strip;
  do not jump an island or non-field gap. Density data remains available while
  an asynchronous boundary detection refreshes a missing/stale polygon.
- Start boundary detection before the drive to the row rather than waiting
  until the tractor has stopped at the entry.
- Keep transport preparation until the final straight, within one metre of
  CP's approach endpoint and with tractor heading within two degrees of the row.
  Centre an unfolded plough once before transport; never request turnover of
  a transport-folded plough. Preparation timeouts cannot bypass centring.
- Gate CP's plough-controller turnover commands by the active envelope phase.
  On the final straight, turn to the working side, measure its actual markers
  and offset, and validate the raised forward correction before lowering.
- Screen compact and broader local steering leads before lengthy refinement.
  Verify promising coarse results with production PPC; coarse screening never
  admits a path. Preserve the best fine-validated result when using a shape hint.
  For closely spaced rows, same-heading recoveries and transfers wider than a
  turning diameter, prioritise bulb leads using trailer length and relative
  heading rather than exhausting short leads.
- Limit cumulative stopped experimental calculation to one second, excluding
  physical centring and turnover. Expiry stops with an explicit diagnostic;
  it neither accepts an unverified path nor permits another recovery budget.
- Index boundary segments spatially without simplifying the polygon or
  changing the footprint reserve.

The live 0.1 m / two-degree working-entry limits, 0.075 m repair prediction
limit, attachment measurements and effective CP/XML turning radius are unchanged.
No PW-specific turning radius or fixed 20 m final straight has been introduced.

## Validation and interpretation

Regression output: `out/v022-regressions-final.txt`. The exact packaged runtime
is exercised by `tools/turnbench/audit_envelope_build.py`; its adjacent
`.qualification.json` records every case, transitions and archive SHA-256.
Packaging refuses to publish a ZIP unless every execution case passes.

All **92 regression tests pass**, including compilation of the runtime sources
with baseline Lua 5.1 (not a claim of executing the GIANTS VM).

All **27 packaged execution cases pass**, with all 245 packaged Lua sources
matching the tested source. The five saved-pike arrivals use 0.05 seconds of
simulated initial validation and 0.35–0.80 seconds for the deployed correction,
separate from physical turnover. Qualified archive SHA-256:
`0ea9c058780531e933d85ba9654ade9648b14c610a77d841bc27881d25a520a7`.

The saved-course fixture is
`tools/turnbench/fixtures/t7-first-pike-outer-headland.json`: 366 points extracted
from the outermost headland centreline in the T7 saved course. It is an **inset
proxy**, not the game's detected field boundary. Its target is approximately
24.8 m behind the original row for the recorded PW dimensions; increasing tool
width moves that target inward. Five arrival yaw cases (0, ±5 and ±10 degrees)
exercise the raised straight, one turnover, working-envelope correction,
lowering, CP handover and eight metres of subsequent work.

Other cases cover both turn directions, mounted/trailed drills, signed pike
angles through 41.5 degrees, independent yaw response, steering lag, variable
frame intervals, braking and small marker shifts during lowering. Unit checks
also cover the transport handover, blocked turnover commands, polygon-index
equivalence and the one-second deadline.

These are synthetic horizontal dynamics with production CP tracking and
entry/handover code. They do **not** reproduce GIANTS wheel/drawbar collisions,
terrain or hydraulic transforms. The recorded three-metre first-row exit has a
separate handover regression; the continuous eight-metre execution uses a longer
row. The complete GIANTS drive-to-work route is not replayed here. The execution
fixtures advance the mission clock in 50 ms initial planning slices and use a
continuous clock afterwards, so both initial and correction searches enforce
the deadline. This checks the time budget on this test host; it does not promise
that GIANTS scene queries or another computer will have identical performance.

The outer target query places a destination; it does not certify every point of
CP's preceding path. Unsupported articulated tractors and attachment chains
retain stock CP. The desktop bench remains separate and has not been updated
to claim parity with this runtime build. The first in-game v0.22 run is still
needed to verify the physical preparation sequence and complete first-row entry.
