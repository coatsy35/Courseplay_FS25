# v0.26 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.126`.

## Observed failure and correction

The 16 September v0.25 log confirms successful working entries at 12:39:03
and 12:40:38. At 12:41:02 the next turn reached the one-second planning
deadline, before deployment or lowering. The separate initial offset movement
was a deployed working-position correction; initial entry itself succeeded.

The experimental planner now considers stock LSL/RSR Dubins alternatives for
raised row reversals, not only the shortest tractor connection. It tries the
full deployment allowance first and a compact geometry-derived allowance after
32 candidates, always retaining full footprint, articulation and alignment
checks. The shared Dubins solver and CP's XML radius selection are unchanged.

Straight-row preparation uses the same deployment allowance as stopped
planning. Its proposed staging distance is bounded by freshly measured
geometry before reuse; the path is never accepted without revalidation.

The stopped-search ceiling is three seconds, with physical animation time
excluded. Local final corrections are limited to 3 km/h. Existing approach
revalidation uses the live entry allowance, avoiding unnecessary replacement
of an admissible path. New routes keep the tighter planning margin. A missing
fallback bracket during fine local search has also been corrected.

## Verification

- 102 regression tests pass; the ten deployment tests were rerun after the
  final preparation-reuse change.
- 37 cases run against the packaged Lua pass, including the new second-exit
  geometry with 0, 0.2 and 0.5-second synthetic steering-response delays.
- Every successful packaged case lowers, hands over and works at least 8 m.
- Existing first-row exits, initial entries, signed pikes, deployment and
  hydraulic perturbations remain in the qualification suite.
- Tests cover deadline extension and expiry, cumulative timing across recovery,
  unchanged lowering admission, preparation geometry and stale staging bounds.

## Limits and follow-ups

The failing row-end pose, hitch, axle and raised markers are from the live
log. The field boundary remains the conservative saved outer-headland
centreline proxy. Subsequent turnover uses previously measured working markers
and a synthetic hydraulic heading change. Steering and tyre behaviour are
planar approximations, not GIANTS physics; these tests cannot certify that
v0.26 will complete the physical field.

Pre-measuring each working side before starting has not been added in this
build. That remains the next step for removing the initial working-offset
correction on ploughs and other offset implements.

ZIP SHA-256: `9005a6342cff09d75ce8200de6bdc9734756424492cc7519a92cfbddd2d73736`.
