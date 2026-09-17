# v0.37 qualification

## Broader testing and the live failure

Monitoring was resumed at the user's request, then paused immediately after
the confirmed v0.36 stop at 10:29:36 on 17 September. The log is preserved in
`out/v036-live-failure.log`. No installed game ZIP was changed.

An additional 63-case v0.36 stress audit produced 51 passes and 12 failures.
The failures involved small lateral, longitudinal or implement-heading changes
at an already short working approach. The complete report is retained at
`out/v036-expanded/report.json`; the failures have not been overwritten.

The latest game run had no cached measurement for the required working side.
It accepted a centred turn with 12.96 m deployment lead. Its actual deployed
arrival then exhausted local correction at 0.878313 m predicted edge error.
The independent logged-pose replay reproduces this at 0.877542 m, allowing for
rounded inputs. It must still reject this late pose without lowering.

## Changes

The staging search previously jumped from the full allowance (20.89 m here)
straight to the compact allowance (12.96 m). It now reduces the allowance in
tracking-lookahead increments. Every candidate retains the same footprint,
joint and alignment checks. The new recorded-exit replay selects 18.20 m,
preserving about 5.24 m more correction room. It completes deployment,
lowering, handover and at least 8 m of work.

Stronger tests also showed that visible marker drift can lag behind a change
in steering response. The existing single early correction now also checks
the difference between measured and planned steering-response time, expressed
as travel at the current speed. It uses the existing spatial tracking margin
and only operates while correction room remains. The log identifies both
marker drift and steering-response travel separately.

Actual CP speed requests, entry tolerances, stock startup modes and deployment
permissions are unchanged. There is no model-name exception or extra loop
after deployment. The runtime changes remain within the existing planner and
turn adapter.

## Expanded permanent checks

- 27 combinations of CP speed, steering response and calibration, each running
  the existing two-turn cold-start sequence with learnt geometry retained.
- Six complete exits with the required working-side measurement absent, at
  different CP speeds and physical steering responses.
- A full recorded exit followed by 36 independent arrival perturbations:
  lateral +/-0.15 m, longitudinal +/-0.5 m, tractor heading +/-1 degree,
  implement heading +/-2 degrees, and steering response 0.2-1.0 seconds.
- The original late deployed pose remains a negative regression: the fix
  prevents that short arrival rather than permitting crooked or late lowering.

The independent arrival replays translate the recorded pose upstream by the
additional lead selected by the real planner. This is an explicit modelling
assumption, not a claim to have recreated the game's hydraulic animation or
braking frame by frame. Full turn execution is tested separately. The bench
still uses approximate planar physics and does not represent a complete
continuous field run or every mod's tyre, terrain and hydraulic behaviour.

The old v0.25 performance regression counted a maximum of 64 candidates in a
two-distance catalogue. It now checks actual simulated stopped planning time
(at most 10 seconds), retaining a meaningful responsiveness check while the
catalogue includes intermediate staging distances. Its measured check passed.

## Validation

117 regression tests passed in `out/v037-regressions-final.txt`.
All 109 packaged release cases passed, including the grouped full-exit and
36-arrival stress check. CRC, XML, manifest and source-byte checks passed.
The exact packaged execution report is stored in
`out/qualification-v037/FS25_Courseplay_EnvelopeTurnsTest.qualification.json`.
Release requires all its cases to pass, plus CRC, XML, manifest and source-byte
checks. In-game completion remains unverified; monitoring remains paused.

Test ZIP: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.137`.
SHA-256: `fbded98b6d752e0274e4af1c51b241d147884bc838159915228d751f683a1fb6`.
