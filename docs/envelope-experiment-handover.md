# Envelope-turn experiment: handover and retirement

Status: **not reliable in game; do not treat v0.38 as a solved release**.
This branch preserves the experiment and its bench evidence. Further work is
moving to a clean stock-CP-based branch, not another envelope-planner patch.

## What was built

- A separate opt-in forward-turn planner, measured implement envelopes,
  deployment staging, working-side calibration and a guarded work-entry handover.
- Geometry capture and a bench catalogue of vehicles/attachment combinations.
- Replays of successive game failures, cold/resumed starts, both plough sides,
  CP speed settings, steering response, braking, frame intervals and boundaries.
- Versions 0.34-0.38 added initial-side learning, steering-speed prediction,
  intermediate deployment distances, early response correction, correctly timed
  row-finish sampling and measured steering state during stopped replanning.
- The stock-turn review is in `base-turn-strategy-review.md`.

## Where it reached

v0.38 passed 124 regression tests and 112 exact-ZIP qualification cases,
including grouped 36- and 81-arrival variations. These are synthetic planar
bench results, **not evidence of in-game reliability**. The last packaged
version was 8.1.0.138, test identity `FS25_Courseplay_EnvelopeTurnsTest.zip`.
SHA-256: `916593be6d1b068ea146b1c2b9eed819d66b385157cf90fa28c240b3742b4d79`.

The user then reproduced another game failure on 17 September 2026 at
14:33:24.576, during the loop. The controller reported:

> live footprint reached the reserved field edge at -297.487/56.184;
> tractor -294.894/51.121 heading 138.49, tool 70.80

The rejected calculated-envelope point was approximately 0.723 m from the
detected polygon edge, between (-265.25,38.25) and (-383.75,107.25).
This was the added conservative clearance check, not a detected physical
collision. The full local evidence is `out/v038-live-failure.log` (ignored
runtime output, not included in Git). The selected route was 127.9 m, admitted
after 17 candidates with 20.58 m deployment lead and 4.47 s planning.

The replacement predictor supports a rigid tractor and mounted equipment or
one passive trailer. Chained/articulated/actively steered combinations fall
back to ordinary CP, without its new straight-entry guarantee. Having captured
such machines does not mean their experimental control has been implemented.

## Why change approach

Repeated bench passes have failed to predict game behaviour. Increasing the
number of tests around the same simplified model has not resolved that gap.
The replacement also duplicates stock CP's established turn selection and
excludes combinations the user explicitly requires. Do not remove the failing
checks, increase tolerance blindly, force a rigid-vehicle K-turn on a trailer,
or call this branch stable.

## Agreed next direction

Start from the stock CP base at `150dcd51f8a108ffc86e95df3e3e240bcc80b6df`.
Retain its turn selection, vehicle configuration, First/Last/Nearest semantics,
speed settings and reversing controls. Build a live implement-entry controller
around that pipeline, with an attachment/pivot graph rather than a single
fictitious trailer. Arrange sufficient approach room before the turn; defer
unfolding, turnover and lowering until the required measured alignment exists.
Detect non-convergence early and use an allowed repositioning manoeuvre where
necessary. A K-turn is one candidate, not the universal solution.

Preserve captured geometry and failures as evidence. Test complete successive
manoeuvres with independently perturbed execution, not only the planner's own
assumptions. Review the result a second time before publishing another test ZIP.
The live game installation remains untouched and log monitoring remains paused.
