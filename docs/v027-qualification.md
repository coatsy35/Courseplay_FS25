# v0.27 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.127`.

## Evidence and changes

The v0.26 live log records four successful entries, then a stopped-search timeout
at 13:55:07 on row 14 -> 15. Turnover itself no longer failed. The failure was
not evidence that no geometrically valid route existed.

- Removed the experimental 8, 5 and 3 km/h caps. The existing CP field-speed and
  turn-speed settings now govern travel. Initial entry inherits stock CP speed.
- Braking follows distance to the predicted deployment pose and work boundary.
  Tractor and trailer must be straight and stationary before turnover starts.
- Deployment reserve uses the configured turn speed. The working-entry predictor
  estimates steering delay from actual yaw and commanded curvature, rather than
  relying on artificially slow travel to conceal actuator lag.
- Candidate screening rejects field-boundary violations before the more expensive
  production PPC verification. Full containment and alignment admission remain.
- The recorded later exit is now a regression and packaged execution fixture.

## Validation

- All 104 regression tests pass.
- All 41 packaged execution cases pass, using the exact packaged Lua.
- Each completes lowering and handover and works at least 8 m.
- Default CP settings (8 km/h turn, 20 km/h field) reached 20 km/h in replay;
  configured 12/25 km/h settings reached 25 km/h. No fixed 8 km/h cap remains.
- The recorded later exit planned in 2.00 simulated seconds, followed by a
  0.20-second working-entry check. Wall time and GIANTS timing may differ.
- Checks include steering response delays up to one second, both turnover sides,
  saved straight arrivals, sloping boundaries and hydraulic perturbations.
- ZIP Lua/source matching and archive integrity passed.

ZIP SHA-256: `bf2685372a1a5b586d8ab9df15c6a4cbe995d0a3978f5d5aa6f94551c7a1acd9`.

## Limits

These are production-Lua replays with planar tractor/trailer dynamics, not GIANTS
physics. The latest raised pose and markers are recorded; its later working shape
and hydraulic movement use the existing measured PW proxy and synthetic animation.
The field boundary is the conservative saved outer-headland centreline proxy.
The steering-response estimate is a first-order model, not a complete tyre model.

The initial working-offset shift is still possible: one-off working-side measurement
before course entry has not been implemented. In-game verification remains necessary.
