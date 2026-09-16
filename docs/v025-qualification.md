# v0.25 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.125`.

## Changes

The v0.24 log permitted plough deployment with approximately 78 degrees of
implement heading error. Prediction and execution now share a combination
alignment predicate: both tractor and trailer must be within two degrees on
the final straight. The tractor-only candidate exception and redundant model
copy have been removed.

Initial folded travel uses the generated row centre rather than a stale
working-side automatic plough offset. Deployment allowance for initial travel
covers braking/lookahead, half-width and the pike sweep; folded alignment is
already checked before deployment. Normal row turns retain their preparation
allowance. Deployed work markers and CP's resulting offset are remeasured and
validated before lowering; there is no unchecked handover.

Lateral work-entry tolerance is 5% of working width, bounded to 10–25 cm.
Planning uses 60% and local repair 80% of that allowance. Tests check accepted
small drift, rejected excess displacement, curved entries and hydraulic
transients. Neither boundary clearance nor heading limits were relaxed.

## Verification

- 99 regression tests pass.
- 34 execution cases pass against the actual packaged Lua, including v0.23 and
  v0.24 bent arrivals with steering delay, initial arrival angles, first-row
  exit offsets, signed pikes, response variation and hydraulic perturbations.
- Every successful package case lowers, hands over and works at least 8 m.
- The v0.24 replay plans the folded route in 0.50 simulated seconds and the
  working correction in 0.20 seconds. Entry error is approximately 0.117 m and
  0.32 degrees. These timings are not a guarantee of frame rate in FS25.
- All 245 packaged Lua files match the working sources. ZIP validation and
  packaging checks exclude implement-directory code and preserve mod identity.

SHA-256: `0dead47f17d2452221ed51e049c87250dd8d88cd3b22109a101d49d8849b2f53`.

## Limits

The field boundary is a conservative saved outer-headland centreline proxy.
The raw row centre is reconstructed from the logged course/field-detection
position, and deployment uses the earlier measured working markers with a
synthetic hydraulic heading change. Planar tyre/joint behaviour and steering
perturbations are not GIANTS physics. Passing these checks does not establish
universal implement support or prove the physical v0.25 run has succeeded.
