# v0.35 qualification

## Recorded failure

The v0.34 log is preserved in `out/v034-live-failure.log`. At 08:49:12 on
17 September, row 292 -> 293 stopped on its return arc because the live
footprint reached the reserved field boundary. This preceded deployment and
lowering. Earlier turns in the same session had completed.

The selected 128.5 m connection passed ideal pursuit/footprint prediction.
The new recorded fixture reproduces that selection and shows that its delayed
steering sweep crosses the same field boundary. Delayed steering in the
independent execution fixture also reproduces the boundary stop. These are
planar replays of logged geometry, not frame-exact GIANTS physics.

## Correction

After a candidate passes normal fine validation, run a second swept-footprint
check with steering response at each configured CP turn/field speed.
Both phases matter: delayed pursuit is not monotonic in speed. The response
allowance is one pursuit horizon (lookahead / speed), or the current model's
measured response if longer. Both tractor and implement follow the delayed trajectory through the existing
polygon, island and articulation checks. Reject a failing candidate and
continue the existing search.

The second sweep checks clearance only. It cannot replace the nominal
entry-alignment result, install a different path, unfold or lower an implement.
Live boundary and working-entry checks remain unchanged. No fixed runtime
speed or new speed cap is introduced. Local entry optimisation retains its
measured-response model and separate live admission checks.

The uniform extra-boundary-buffer trial was discarded: it unnecessarily
blocked previously usable tight turns. No buffer expansion or departure-ramp
code from that trial is included in the release.

Boundary stops now record the offending footprint point and exact tractor/tool
pose, rather than leaving diagnosis dependent on the previous two-second trace.
Successful candidate logs record the steering-response sweep parameters.

## Regression coverage

The recorded fixture uses the logged centred pose, pivot, collision bounds,
work markers, field polygon and prior right-side working geometry. Deployment
motion and tyre dynamics remain synthetic. The earlier working model is
seeded because this was a later-row failure; the separate cold-start sequence
continues to verify learning without any seeded cache.

New checks cover rejection of the original 128.5 m route, full turn/deployment/
entry/handover at CP speeds 8/20, 20/27, 25/30 and 25/20 km/h, synthetic steering
response up to one second, and irregular frame intervals. Every driving case
must deploy and lower once, resume once and travel at least 8 m in work.

All **114 regression tests** and **63 exact packaged driving cases** passed.
The archive passed CRC, manifest/version and every packaged Lua byte comparison.
Final reports: `out/v035-regressions-release.txt`, `out/v035-package-release.txt`
and `out/qualification-v035-release/FS25_Courseplay_EnvelopeTurnsTest.qualification.json`.

Test ZIP: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.135`.
SHA-256: `2314cf5317bc2d7f6e9b4c7355f134bee76fe84ead944388ba74c6b6b36b1390`.
Earlier failed trials and their reports remain in `out/`; they were not released.
Monitoring remains paused; the installed game mod is not modified by packaging.
