# Base Courseplay turn review

Reviewed against upstream `150dcd51f8a108ffc86e95df3e3e240bcc80b6df`
and the experimental worktree, 17 September 2026. This is a code review of
the fieldwork turn pipeline, not proof of every vehicle's physical behaviour.

| Area | Stock behaviour | Consequence for the refinement |
| --- | --- | --- |
| Radius | `AIUtil.getTurningRadius` combines the tractor radius, vehicle XML override, GIANTS minimum and each implement's configured/calculated radius. | Continue calling this function; physical steering lock and the combination's planning radius are distinct. Existing regression executes this stock resolver with changing XML values. |
| K-turn | `AITurn.canMakeKTurn` checks row separation, reverse permission, tractor articulation, towed steering implement and available field space. | Preserve eligibility. The ordinary K-turn excludes this towed plough. Forcing it would omit trailer reverse control and swept geometry. |
| Calculated turn | `CourseTurn.generateCalculatedTurn` chooses Dubins for ample room or a towed implement; otherwise Reeds–Shepp. Headland corners have separate loop/corner manoeuvres. | A double loop is not a universal requirement. Keep the ordinary strategies for unsupported combinations and headland corners. |
| Angled headland | `AnalyticTurnManeuver` moves the analytic endpoint using the outgoing/incoming longitudinal separation so the main rotation happens towards the outside, leaving alignment distance. | Stock CP already addresses the user's proposed outside-first approach. Any new candidate must retain this advantage and validate the actual implement. |
| Insufficient space | The analytic manoeuvre can move the turn back and append forward/reverse alignment segments, subject to `AIUtil.canReverse`. | A controlled straight reverse is a more relevant stock starting point for this plough than forcing the rigid-vehicle K-turn. It still needs reverse prediction before admission by the experimental planner. |
| Pathfinder | Row distance and settings select pathfinding, optionally via the outer headland. Failure falls back to the calculated turn generator. Reverse pathfinding is normally disabled with a reversing wheeled implement. | Reusing the search does not automatically provide a validated reversing trailer manoeuvre. |
| Search relaxation | `HybridAStar` progressively increases allowed goal-heading error unless `mustBeAccurate`; it retains an iteration limit. Retry contexts can alter fruit/off-field penalties. | Relaxing a transit goal is separate from allowing a bent implement to start work. Do not use search relaxation to bypass the work-entry gate. |
| Tracking | CP applies tight-turn offsets, with `tightTurnOffsetDistanceInTurns` read recursively from vehicle configuration. | These offsets assume the stock tractor path. Do not apply them a second time to an explicitly simulated implement path. |
| Direction change | `changeDirectionWhenAligned` can skip the remainder of an alignment leg once implement marker direction agrees, then reinitialises PPC for the next direction. | Preserve this mechanism if adding a validated reversing turn; do not introduce a timed reverse. |
| Speed | Ordinary turns use configured turn speed; the middle of a long turn can use field speed. Reverse speed is also configured. | Keep these settings. Prediction must account for acceleration, steering response and the existing engine speed reduction without introducing a runtime fixed speed. |
| Work entry | `WorkStartHandler` owns raise/lower markers. Stock CP's final implement check distance grows with speed; readiness can hold the tractor before contact. | Retain the handlers and controller events. The additional alignment condition must run before lowering and handover. |
| Loaded course | Existing First/Last/Nearest selection determines the starting waypoint. | Entry refinement must operate after selection, not select another row or replay the course start. |

The present experimental forward planner has a narrower supported geometry
model than stock CP: a rigid tractor with mounted equipment or one passive
trailer. Chained, articulated or positively steered trailer arrangements
retain stock CP. Captured machines in the bench are not evidence that all
those arrangements have a validated experimental controller.

The shorter direct-connection search currently explores fewer deployment
distances than the broad turn search. A probe extending that catalogue found
a shorter feasible route with corrected calibration, but also approximately
doubled planning time for the recorded exit. It is not yet a qualified change.

A reversing alternative should therefore build on CP's existing reverse
permission, `AIReverseDriver`, alignment-controlled direction changes and
configured reverse speed, with independent reverse-kinematics and swept-body
tests. A tractor-only Reeds–Shepp curve is insufficient for this long plough.
