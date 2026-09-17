# v0.38 qualification

**Subsequent in-game failure confirmed at 14:33:24 on 17 September 2026.**
These passing bench results did not establish reliability. See
[experiment handover](envelope-experiment-handover.md).

## Recorded failure and scope

The preserved `out/v037-live-failure.log` records resumed work from a saved
course. The first turn (292 to 293) completed; the second (315 to 316) failed
in working-position prediction after turnover. It was not a failure to select
the saved course start, nor evidence that the visually straight tractor was
crooked. The original stopped pose is retained as a negative replay: it must
not lower merely because no better path was found.

The outgoing working-side sample was taken on the first FINISHING_ROW update,
then compared with the later centred pose. This confounded centring with
settling while still driving to the raise point. Sampling now occurs immediately
before the stock onFinishRow controller event. An optional lifecycle hook is
the only new shared AITurn change; stock raising and controller ordering remain.
The log now records the outgoing tractor/tool headings at that event.

The exact final pre-centring pose was not recorded in v0.37. Its corrected
calibration cannot be recovered with certainty from screenshots. The tests
therefore vary the calibration independently; they do not label an inferred
angle as a measured value.

## Prediction and stopped replanning

The expanded tests exposed a separate restart mismatch. A stopped tractor can
retain steering, and the old PPC goal could change it while the planner was
calculating. The planner now reads curvature through the inverse of the
vehicle's existing steering mapping and holds that measured command while
stopped. It does not centre wheels artificially or change CP speed settings.
Future straight-entry previews explicitly start with straight steering.

The response model now advances steering, acceleration and braking in time,
with bounded distance steps, rather than assigning an entire spatial step's
travel time to the first steering update from rest. It retains the existing
engine steering-speed reduction. The 50 ms integration ceiling is a numerical
step, not a runtime driving-speed limit. Planar acceleration/braking and tyre
response remain approximations.

After a measured response change has invalidated the prediction, even a
retained path must recover planning margin. It no longer uses the full live
admission tolerance for that revalidation. The live width-relative allowance
(maximum 0.25 m here), angular tolerance, footprint and joint checks are unchanged.

## Added evidence

- Actual logged folded exit and independently replayed deployed arrival.
- Three calibration hypotheses, each with a complete turn, then 81 independent
  arrival combinations overall: CP turn speeds 8/20/25 km/h, steering response
  0.2/0.5/1.0 s, and frame intervals 1/60, 1/30 and 0.1 s.
- Each successful arrival must lower once, hand over once and work at least 8 m.
- Resumed-work lifecycle test with a different early FINISHING_ROW pose, followed
  by two turns retaining the learnt working-side geometry.
- Non-linear steering mapping, both reverser signs, non-centred stationary
  steering, a tight physical steering lock and future-pose state separation.
- Stock K-turn admission checks for reverse permission, articulated tractors,
  towed implements, row separation and headland space.
- Existing first/last/nearest, radius/XML, boundary/island, deployment, cold-start,
  consecutive-turn and independent response/braking tests remain mandatory.

The independent arrival tests translate the recorded pose laterally by the
arrival offset selected by the real planner. This is an explicit synthetic
assumption, not a reconstruction of GIANTS hydraulic and tyre physics. Full
turn execution is checked separately. Neither these tests nor the captured
vehicle catalogue prove support for every future mod.

## Second review

The first expanded run passed 120 regression tests. Review then found that
future-pose previews could inherit the current wheel angle, and holding a very
tight steering lock needed a shorter geometric target. Both were corrected
and covered by additional tests before restarting the full release checks.
Intermediate interrupted reports are retained; they are not qualification.

See `base-turn-strategy-review.md` for the review of stock turn selection,
configuration, headland placement, reversing, search relaxation and handover.
No new K-turn or shorter-loop optimiser is included in this build. The direct
search catalogue still differs from the broad search; a tested optimisation
is separate from this entry fix. A reversing alternative must retain CP's
reverse permissions and trailer alignment/control, not just a tractor-only path.

## Release results

All **124 regression tests passed** after the second review, in
`out/v038-regressions-final.txt`. All **112 packaged release cases passed**,
including the grouped 36-arrival and 81-arrival stress checks. The exact-ZIP
report is `out/qualification-v038/FS25_Courseplay_EnvelopeTurnsTest.qualification.json`.
CRC, all XML, title/version, source manifest and all 245 packaged Lua files
were checked; Lua bytes match the qualified worktree.

Test version: **v0.38**, packaged mod version **8.1.0.138**.
SHA-256: `916593be6d1b068ea146b1c2b9eed819d66b385157cf90fa28c240b3742b4d79`.

The distribution contains the stable `FS25_Courseplay_EnvelopeTurnsTest.zip`
and its qualification JSON. The installed game ZIP and live Courseplay build
were not modified. Monitoring remains paused. In-game completion of this
new version remains unverified.
