# v0.20 qualification: failed

The delivered `FS25_Courseplay_EnvelopeTurnsTest.zip` was rechecked on 16 September.
Its SHA-256 is `d7fdb88202029d3da4765ad324d482fd71068a74ea9e92d7bda496359cc723ba`.
Every packaged Lua file matches the source used by the test fixture. The four
experimental modules are loaded directly from the ZIP during this audit.

The earlier 80 offline regression checks passed. An additional independent
execution sweep exposes two failures, so those regressions are insufficient
to qualify this build for another in-game test. Do not describe v0.20 as reliable.

| Additional case | Result |
| --- | --- |
| Recorded initial pose, both mirrored directions | Pass |
| 30 Hz, 60 Hz and variable update intervals | Pass |
| Braking at 1.2 and 3.0 m/s² | Pass |
| Steering response time constants of 0.2, 0.5 and 1.0 s | Pass |
| 25° and 41.5° pikes with 0.2 s steering delay | Pass |
| 5 cm sideways/forward work-marker movement while lowering | Pass |
| Effective trailer response length 10.4 m | **Fail before handover** |
| Effective trailer response length 11.6 m | **Fail before handover** |

14 of 16 cases pass. Successful cases continue through CP's handover methods and
eight metres of fieldwork; counting a successful path search alone is not enough.

## Failure evidence

With the faster 10.4 m response, the centred rig reaches the turnover gate at a
different position. After deployment the tractor is at (-158.249, -128.336),
heading -0.547°, with tool heading -10.419°. The original row target remains
(-156.761, -118.820). All 96 local candidates fail; the best predicted edge error
is 0.1461 m. No lowering or fieldwork handover occurs.

With the slower 11.6 m response, the first local correction passes prediction
but deviates during execution. Repair starts 6.72 m before first working contact;
after braking the pose is (-157.612, -121.799), tractor heading 15.268° and tool
heading -8.733°. The second, bounded local check exhausts 96 candidates; best
predicted edge error is 0.1056 m. Again there is no handover.

These failures show sensitivity to trailer response and late correction, not a
missing ZIP file, Lua syntax error or evidence that nine headlands are insufficient.
Keep the failures visible; neither more retries nor relaxed lowering admission
is a demonstrated correction.

## Limits and next verification gate

The varied response lengths, actuator lag and marker movements are synthetic
stress parameters, not measurements of this particular GIANTS combination.
Vehicle/implement geometry and the CP offset change come from the recorded run;
the field polygon and physical dynamics do not. The fixture does not reproduce
terrain, tyre forces, joint collisions or every automatic plough-offset update.
Low-level implement actuation/readiness and unrelated game services remain mocked.

Before another test ZIP: both failures must pass without bypassing entry checks,
the full sweep must pass, and regression tests must still cover turnover,
lowering and continued fieldwork. This is a necessary gate, not proof of all
in-game behaviour. The original ZIP has not been overwritten by this audit.

Run from the envelope worktree:

```powershell
python tools/turnbench/audit_envelope_build.py <test-zip> out/v020-qualification.json
```

The command writes per-case transitions and failure details and exits unsuccessfully
when any case fails. The harness exposes timing, acceleration, braking and steering
response independently of the planner's idealised prediction.

`build_ingame_test.py` now runs this qualification on the candidate archive before
replacing the test ZIP. Failure or interruption leaves the existing ZIP untouched.
Its adjacent `.qualification.json` records the outcome. There is no skip switch.
