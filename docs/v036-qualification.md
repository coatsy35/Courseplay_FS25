# v0.36 qualification

## Recorded failure

The 17 September 09:53:40 v0.35 stop occurred after stock plough turnover,
at row 292 -> 293. The preceding raised approach had completed, with the
tractor about 0.7 degrees and the folded implement about 2 degrees from the
row. The stop was a rejected numerical approach, not a failed live lowering
check. The log is preserved in `out/v035-live-failure.log`.

The new fixture starts directly from the logged deployed pose, markers,
internal pivot, dimensions, field polygon and measured steering response.
It does not depend on reproducing the preceding hydraulic animation in the
synthetic bench. Before the fix it exhausted 96 trials with 0.208470 m best
predicted error, matching the game's 0.208414 m to the logged precision.

## Correction

The prediction included steering delay but continued accelerating towards
the full CP speed while steering caught up. GIANTS already reduces speed
according to normalised steering error. The numerical prediction now includes
that adjustment, using curvature as an approximate steering coordinate.
The additional conservative boundary sweeps retain their full-speed model.

Reference: [FS25 AIVehicleUtil.driveToPoint, lines 67-78](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=91&class=881&version=script).
The 1 km/h value in the prediction is the engine's existing adjustment floor,
not a new commanded driving speed. Actual speed requests still come from CP.
Entry tolerances, controller behaviour and First/Last/Nearest are unchanged.

The recorded-response replay now selects a correction in four trials. Its
worst predicted entry error is 0.183 m; the live fixture lowers at 0.183 m and
1.15 degrees, with the first work corner 0.62 m before entry. It then lowers
once, resumes once and completes over 8 m in work without another turnover.

## Validation

- 115 regression tests passed: `out/v036-regressions-final.txt`.
- All 75 driving cases passed against the exact packaged Lua, including 12
  recorded-arrival combinations of CP turn speeds 8/20/25 km/h and independent
  steering responses 0.2/0.5/0.704/1.0 seconds. Existing cold starts, both
  plough sides, consecutive turns and narrow angled fields remain in the gate.
- ZIP CRC, XML, manifest and packaged-source checks passed.
- Report: `out/qualification-v036/FS25_Courseplay_EnvelopeTurnsTest.qualification.json`.

The bench remains approximate planar physics, not a GIANTS terrain/tyre
simulation. These checks reproduce and address the logged rejection; in-game
completion is not yet verified. Monitoring remains paused.

Test ZIP: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.136`.
SHA-256: `37cd39649e44f3d726b0512f69137b697c9fc160e5e2f920bec4676ae61f71cc`.
