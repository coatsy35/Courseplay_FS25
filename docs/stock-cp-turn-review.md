# Clean-main turn review

Reviewed the runtime at `9b915b07`, which matches upstream `150dcd51`.
This is a source review, not evidence of a successful in-game replacement.

## Turn placement and approach

`AnalyticTurnManeuver:init` in `scripts/ai/turns/TurnManeuver.lua` deliberately
moves the analytic goal outwards on angled headlands. Its comments describe
finishing the full turn towards the field edge so the trailer can align, rather
than splitting the turn and leaving a final bend close to the row. This is
consistent with the user's proposed refinement for pikes.

`TurnContext:getTurnEndNodeAndOffsets` in `scripts/ai/turns/TurnContext.lua`
provides the goal for both calculated and pathfinder turns. The towed case uses
marker-derived spacing. Its TODO explicitly acknowledges that straightening
distance should depend on radius, starting angle and tow-bar length. It does
not calculate the settling distance of the complete attachment chain.

The analytic caller additionally applies `math.min(dz, endZOffset)`; the
pathfinder caller uses the goal directly. Any approach change must test both
paths, both signs of pike offset and both turn directions. Changing the shared
method without considering its other callers would also alter row starts and
connecting paths.

`appendEndingTurnCourse` continues the path into the row until the working
markers can reach it. Increasing that tail alone gives the implement room to
straighten after the intended work start. The required room belongs before it.

The user's observation that stock CP turns back too soon is a useful hypothesis
for turn placement. Source inspection alone does not establish whether the
main contributor is nominal course shape, dynamic offset or path tracking.
Compare the tractor path and actual implement orientation through the return
curve, with stock CP as the baseline.

## Existing support to preserve

- `AITurn.canMakeKTurn` and `CourseTurn:startTurn` select manoeuvres using available
  room, width, radius, implement reversing permission, articulation and settings.
  Stock K-turns exclude towed reversing implements and articulated tractors.
- `AIUtil.getTurningRadius` honours vehicle configuration, GIANTS minimum radius
  and child implement requirements. Do not substitute the tractor's steering
  lock or an arbitrary enlarged radius for this configuration pipeline.
- `AIUtil.calculateTightTurnOffsetForTurnManeuver` moves the tractor outside the
  curve using steering length and curve radius, with smoothing. Calculated turns
  also apply static offsets and mark selected sections for dynamic correction.
  A second independent offset controller could fight these mechanisms.
- `CourseTurn:getForwardSpeed` uses CP field speed through the middle of a long
  turn and turn speed near its ends. Reverse speed comes from CP settings. Keep
  this speed ownership and allow for its effect on tracking and hydraulics.
- `adjustCourseToFitField` already repositions an analytic turn with reverse
  sections where allowed. `AIReverseDriver` has trailer and dolly behaviour and
  special handling for articulated tractors. Retain those controls and their
  eligibility rules instead of forcing a rigid-vehicle K-turn.
- `AIDriveStrategyPlowCourse:getTurnEndSideOffset` accounts for changing working
  sides. Plough offset calculation and turn-end offset updates must be preserved.

## Work-entry checks and ordering

`WorkStartHandler:shouldLowerThisImplement` uses longitudinal work markers,
lowering duration and CP turn speed. Its 15-degree alignment check selects which
front-marker position to use; it is **not a requirement for lowering**. Forward
lowering also checks lateral distance, but that threshold comes from lowering
duration and speed rather than working width. Reverse lowering is based on
longitudinal position. A new work-entry condition must retain stock coverage and
hydraulic timing while checking actual implement alignment.

Stock `areAllImplementsAligned` uses AI-marker direction with a five-degree
tolerance. This is an existing practical reference, not justification for a
millimetre-scale lateral gate or an assumption that every offset implement's
root axis should match the row. AI markers can fall back to work areas or
configured vehicle-size markers; their provenance matters.

`WorkStartHandler` sends turn-progress events before lowering. `PlowController`
can start turnover within 30 degrees of the row, and has an additional lowering
event fallback. Stock startup has a separate unfold/rotate/lower sequence in
`AIDriveStrategyPlowCourse`. Checking just one event cannot control every entry.

`AITurn:onWaypointPassed` resumes fieldwork at the end of an ending-turn course.
An added lowering gate must consider this handover too. Merely withholding
lowering could otherwise be bypassed, leave a strip unworked or drive past the
row start indefinitely. Plan the approach early enough to avoid that situation.

First/Last/Nearest selection and ordinary drive-to-start paths have distinct
handling. Preserve their chosen waypoint and existing task transition semantics.

## Separate finding to verify if field-fit code changes

`TurnContext:getHeadlandAngle` explicitly returns radians. The headland-angle
guard in `AnalyticTurnManeuver:getDistanceToMoveBack` compares it with
`math.deg(10)` and `math.deg(170)`. Those thresholds cannot admit the returned
angle range, so the guarded swath-width correction never applies. This is a
source-level finding, not an established cause of the reported live failure.
It remains unchanged pending focused field-fit tests.

## Implementation direction

Start with the existing turn's return-curve placement and the available
straight approach before work. Permit asymmetric travel where there is room;
do not select a shape in advance or add a fixed 20-metre excursion. Measure
all relevant working attachments live, with practical tolerance, and account
for steering that is still unwinding. Keep stock selection, speed and tracking
as the baseline. Test complete turns and work handovers before issuing a build.
