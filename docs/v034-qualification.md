# v0.34 qualification

The v0.33 log from 17 September is preserved in `out/v033-live-failure.log`.
Its second turn (waypoints 152–153) stopped after deployment at 00:08:41.
There was no cached working-side preview. The initial working side had been
unfolded by stock startup, outside the experimental turn's learning code.

## Runtime correction

Observe the actual working side during normal `finishRow`, before the stock
raise/centre event. Geometry capture for this observation does not depend on
asynchronous field-boundary detection. After centring, record the inverse
relative-heading change as a preview estimate for that side. A previously
measured deployment model with matching equipment is retained in preference
to this estimate. Actual deployment replaces the estimate with a fresh model.
Both observations use implement heading relative to the tractor.

No fixed driving speed, relaxed entry tolerance, additional unfolding cycle,
machine-name exception or changed First/Last/Nearest startup is introduced.
Actual deployment and lowering still require the existing live checks.

## Stronger checks

`run_cold_start_sequence` starts without a working-model cache, runs production
row finish before centring with the field polygon temporarily unavailable,
executes a first turn and fieldwork handover, then creates a fresh turn state
on the same tractor/implement and executes the recorded v0.33 second exit.
Each turn must deploy once, lower once, resume once and travel at least 8 m in
work. Both side models must have been learnt through runtime code.

The first turn uses the earlier recorded first-exit fixture; the second uses
the v0.33 logged pivot, markers, dimensions, target and detected polygon.
The original row's working geometry and animation yaw changes are reconstructed
from the available observations. This is not a frame-exact GIANTS replay.

The sequence is exercised at CP turn/field settings of 8/20, 20/27 and 25/30
km/h; with 0.5 and 1.0 s synthetic steering response; and with opposite signs
of initial calibration/animation variation. These cases are permanent release
checks in `audit_envelope_build.py`, including the failing stress case.

## Bench correction

The original one-second steering-response test omitted an existing part of
GIANTS' driving control: while the steering is catching up, `driveToPoint`
reduces the requested speed according to normalised steering error. The test
instead accelerated towards the full CP speed throughout that delay. It
therefore failed both the previous runtime and this candidate.

The bench now models this documented speed adjustment after updating its
steering actuator, before integrating acceleration and vehicle movement.
The one-second delay is retained. A separate regression checks both steering
directions, restored CP speed once steering settles, and preservation of a
zero-speed stop. The mod still delegates actual driving to the existing engine;
no additional steering controller or fixed travel-speed cap has been added.

Sources: [GIANTS FS25 AIVehicleUtil.driveToPoint, lines 67–78](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=91&class=881&version=script)
and [AIFieldWorker.updateAIFieldWorker, line 392](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=78&class=620&version=script).

This remains an approximate planar bench: it uses curvature as its normalised
steering coordinate, an exponential actuator perturbation and synthetic tyre,
terrain and hydraulic dynamics. It does not claim to reproduce GIANTS physics
exactly or prove in-game completion. The fixed bench case is retained in the
release gate; the gate itself is unchanged and still requires every case to pass.
Speed checks compare the strategy request with the configured CP limit, while
recording actual speed separately. Requiring a slow-steering tractor to reach
the full requested speed would contradict the engine behaviour being tested.

## Validation

All **112 regression tests** and **57 packaged driving cases** passed.
The ZIP passed CRC, manifest and source-byte checks. Stock transport-start
code remains identical to upstream `150dcd51f8a108ffc86e95df3e3e240bcc80b6df`.

Final results: `out/v034-regressions-engine.txt`, `out/v034-package-final.txt`
and `out/qualification-v034-final/FS25_Courseplay_EnvelopeTurnsTest.qualification.json`.
Earlier failed reports remain preserved under their original filenames.

Test ZIP: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.134`.
SHA-256: `95d73a6a6b7c1726ccb4f88c9dd9de00edcdff07f2048b270c078e55062bf603`.

Monitoring remains paused. The installed game mod is not modified by packaging.
