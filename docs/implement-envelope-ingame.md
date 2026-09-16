# In-game envelope turn test

Branch: `codex/implement-envelope-ingame`, based on `codex/implement-envelope-turns`.
The implement-directory changes are maintained separately and are not included.

Current test: **v0.33**, packaged mod version **8.1.0.133**. The ZIP filename
remains stable; the in-game title and `[CP envelope] v0.33` records identify it.

Version 0.33 previews the measured working-side correction before selecting
the raised arrival line. A remembered deployment transform can select a lateral
staging offset without moving the course's working row. The actual working
geometry and entry remain measured and validated after deployment.
See [v0.33 qualification](v033-qualification.md).

### Version 0.32

Version 0.32 separates deployment space from speed-dependent braking. The
latest failure is reproduced with the saved T7 settings (20 km/h turn, 27 km/h
field); the previous replay incorrectly used 8 km/h. Braking follows remaining
route distance, including the arc before the final straight. Deployment space
retains tracking lookahead at both raised and working-position transitions.
See [v0.32 qualification](v032-qualification.md).

### Version 0.31

Version 0.31 prepares the field boundary while finishing the row and uses the
boundary/islands for containment, removing the additional soil-density veto.
The latest logged folded footprint and detected polygon are permanent bench
fixtures. See [v0.31 qualification](v031-qualification.md).

### Version 0.30

Version 0.30 interleaves short and broad route searches and records the actual
field polygon, measured footprint and boundary rejection source. The v0.29
live stall is not yet reproduced: this is a search scheduling and diagnostic
build, not a verified correction of that stall.
See [v0.30 qualification](v030-qualification.md).

### Version 0.29

Version 0.29 restores stock CP first/nearest/last startup behaviour and removes
the experimental initial-entry controller and outward headland target.
See [v0.29 qualification](v029-qualification.md) for evidence and checks.

### Version 0.28

Version 0.28 compares shorter asymmetric connections with a validated fallback,
continues candidate preparation during folding and removes the three-second
search failure. Stock K-turn eligibility is retained with guarded final entry.
CP speed settings and full envelope/entry validation remain in force.
See [v0.28 qualification](v028-qualification.md) for tests and limitations.

### Version 0.27

Version 0.27 removes the experimental fixed speed caps. CP's field speed applies
in the middle of long turns and turn speed on final approaches. Braking uses the
remaining stopping distance; deployment waits for a straight, stationary combination.
Working-entry prediction includes steering response estimated during the turn.
Cheap candidate screening now rejects boundary violations before full PPC replay,
reducing the search cost of the recorded row 14 -> 15 timeout.

**104 regression tests and 41 packaged execution cases pass.**
See [v0.27 qualification](v027-qualification.md) for checks and limitations.
The one-off working-side measurement phase remains a follow-up.

### Version 0.26

Version 0.26 adds stock Dubins CSC alternatives for raised row reversals,
checks a compact staging allowance after a bounded full-allowance search, and
uses the same deployment model during straight-row preparation and stopped
validation. Difficult cold searches have a three-second ceiling. Existing
paths are checked against the live admission limit; newly selected paths keep
their planning margin. Final local corrections run at up to 3 km/h.

Validation: **102 regression tests and 37 packaged execution cases pass**,
including the logged failure after the second row. See
[v0.26 qualification](v026-qualification.md) for scope and limitations.
The one-off working-side measurement phase remains a follow-up.

### Version 0.25

Version 0.25 requires both tractor and trailer alignment before deployment,
uses the original generated row centre during folded initial travel, and
applies CP's working offset after deployment. Lateral admission is 5% of working
width, bounded to 0.10�0.25 m; planning and repair retain margins. The two-degree
heading limit, physical footprint checks and one-second stopped-planning budget
are unchanged. **99 regression tests and 34 packaged execution cases pass**.
See [v0.25 qualification](v025-qualification.md). This remains an experimental
build requiring in-game confirmation.

### Version 0.24

Version 0.24 rejects a retained stock approach if it reaches the deployment
straight with too little run-in. The raised recovery draws forwards before a
compact return, reducing the existing hitch angle rather than immediately
tightening it. Completed GIANTS transport folding is no longer followed by an
extra CP centring command. **97 regression tests and 32 packaged execution
cases pass**. See [v0.24 qualification](v024-qualification.md). In-game physical
verification remains required.

### Version 0.23

Version 0.22 entered work successfully in the 16 September live run, then
exceeded the stopped planning budget after the first short row. Version 0.23
preserves CP's plough-side offset at that immediate handover, tries a compact
raised return turn before longer shapes, and defers initial GIANTS plough
preparation until the envelope controller confirms the final straight.
Footprint transforms and clearance-grid lookups are faster without changing
their sample points, reserves or working-entry tolerances. See
[v0.23 qualification](v023-qualification.md) for the replay scope and limitations.
Validation: **96 regression tests and all 30 packaged execution cases pass**.
The subsequent live v0.23 test exposed the late deployment fixed in v0.24.

### Version 0.22

Version 0.21 failed the subsequent live first-row entry despite passing its
offline checks. Version 0.22 addresses that earlier approach: it keeps CP's
drive-to-work pathfinder, places its target farther towards the outer headland
where the full-width combination fits, and delays the usual 15-metre handover
until the tractor reaches the final straight. Folded ploughs stay folded during
transport; unfolded ploughs are centred once before driving. Turnover is allowed
on the straight, followed by measurement and validation of the working envelope.
The implement need not already be straight while centred: the raised forward
correction aligns its deployed working edges before lowering.

Local correction screens several tangent shapes and refines lateral lead before
fine production-PPC validation. Working limits remain 0.1 m / two degrees, with
the existing tighter prediction margin. Stopped experimental planning has a
one-second cumulative budget; physical centring/turnover is excluded. Exhaustion
stops explicitly and cannot authorise an unchecked path or restart the budget.
See [v0.22 qualification](v022-qualification.md) for evidence and limitations.
Validation: **92 offline regression tests and 27 packaged execution cases pass**.
The complete physical v0.22 start still requires an in-game test.

### Earlier versions

Version 0.21 fixes both failures which withdrew v0.20 from testing. Deployment
now reserves the controller's lookahead and braking distance as well as the
implement geometry. A short, consistent set of measured yaw samples can inform
the one allowed tracking correction before the remaining steering space is
used up. The local search also considers shorter run-ins before exhausting its
budget on one straight length. It still keeps the plough centred through the
loop, permits turnover only on the aligned approach, and measures the deployed
markers before lowering. Working limits remain 0.1 m / two degrees; CP/XML
radius and physical dimensions remain unchanged.

Validation: 83 distinct offline regression checks and all 22 packaged execution
cases pass, including both withdrawn-build failures in both turn directions.
Successful execution cases continue eight metres beyond CP's fieldwork handover.
See [v0.21 qualification](v021-qualification.md) for evidence and model limits.
The [v0.20 failure report](v020-qualification.md) remains as the historical record.

Version 0.20 addresses the 23:24–23:25 v0.19 recording. The centred loop
completed, but deploying the plough changed its work markers and CP offset;
all 96 final corrections failed. A replay of that late working pose still
failed with 3,680 candidates, so increasing retries was not a solution.

Centred manoeuvres now aim at a raised deployment point before the original
work boundary. Its lead comes from the measured implement length/work-marker
span plus the nominal half-width projected onto the angled inner boundary.
It does not alter the original working row, CP/XML radius or live admission
tolerances. Both tractor and implement must face that row within two degrees
before the stock turnover event is permitted. Rotation finishes stationary;
the actual working footprint and CP offset are then measured and the final
forward approach validated before lowering. No second loop is permitted.

The raised staging target allows up to 0.5 m positioning error (limited to
10% of working width), because folded markers are not working admission.
Working entry retains the 0.1 m / two-degree live limits and tighter planning
margin. All staged candidates retain field and articulation checks. The
search prioritises a bend based on trailer length, reducing the recorded
initial replay from 77 trials to 11; its working correction takes four.
Speculative row-finish planning no longer starts redundant work once stopped.

The new regression runs measured centred/working geometry and CP's offset
change through a seven-second turnover, hydraulic lowering, production
AITurn/plough/fieldwork handover, and eight metres of subsequent fieldwork.
It covers mirrored entries, square/angled boundaries up to 41.5 degrees,
independent trailer response, and mounted/trailed implements. The field,
hydraulic geometry interpolation and vehicle physics are synthetic; this
does not prove GIANTS collision/terrain behaviour. The desktop bench remains
on its separate branch and has not been presented as current runtime parity.
Validation: 80 offline checks pass (49 planner/runtime, 15 initial-entry,
eight tracking, five deployment/handover and three packaging/syntax checks).

Version 0.19 addresses the 22:47–22:49 T7.300/PW initial-entry recording.
Initial entry now waits stationary for GIANTS to allow plough rotation, then
uses CP's centring event before checking the forward course. It no longer
deploys the plough and drives close to the crop before checking alignment.
Existing reverse sections stay with CP; the complete forward approach is
validated from the stopped pose. A retained stock bulb only marks its final
incoming section for deployment, not an earlier section facing the same way.
If that route cannot align, a bounded forward correction is tried before the
complete recovery planner. The original row and field boundary remain the targets.

The recorded final stop was 0.132 m edge error / 0.58 degrees. The old 0.25 m
drift trigger exceeded the 0.1 m lowering tolerance. Correction now triggers
at the 0.05 m planning margin while there is space left, interpolating between
prediction samples to avoid treating sampling distance as drift. It remains
limited to one tracking repair before lowering; it cannot launch another bulb.
Lowering tolerance, CP/XML radius, physical dimensions and boundary reserves
are unchanged. Tests include the logged working approach mirrored both ways
with an independently different trailer response. These are offline simulations;
GIANTS articulation, unfolding collisions and real entry still need an in-game test.

Version 0.18 addresses the T7.300/PW initial-entry failure recorded on 15 September
at 22:19–22:20. Initial entry bypassed the normal row-finish event, so its recovery
loop used an uncentred plough. It now raises implements and emits CP's stock
`onFinishRow(false)` event, then waits stationary for centring before measuring
and planning the loop. CP still owns rotation back to the working side.
The initial route also follows stock CP's event timing: its rotation/lowering
controller is called only on the final forward approach, not throughout the
outgoing route whenever the tractor briefly faces the incoming row.

The drift check also treated a nearby future tail sample as if the tractor had
already completed the bulb (40° tractor / 85° implement heading error). A local
correction now requires the incoming course phase, a tractor within 30° of its
direction, and a nearest predicted sample on that phase. Lowering tolerances,
field containment and joint limits are unchanged. Replays cover the logged pose
in both directions, with stock plough rotation and one aligned lowering. Field,
centred marker motion and physics remain synthetic; in-game validation is required.
The earlier unnumbered builds used 8.1.0.3. Version 0.3 fixed their live
`coroutine.create/resume` crash: FS25 does not expose that library. The search
and simulation now retain explicit state between updates. All integration
tests run with `coroutine=nil`, including the complete startup path.

Version 0.17 addresses the v0.16 initial recovery recorded at 21:26-21:27 on
15 September. One complete loop was selected, but the real plough straightened
about five degrees faster than predicted despite close tractor-path tracking.
The unchanged admission check stopped at 0.624 m edge error / 2.44 degrees before
lowering. Forward hitch-motion samples indicate a response lever near 10.4 m,
compared with the measured 11.09 m geometric lever. No specific lever is coded.

During a turn, consistent forward-motion samples estimate a separate yaw-response
lever. A median and dispersion check reject noise/transients; straight, stationary,
large-step and implausible samples are ignored. The estimate belongs to this turn,
not an implement-name lookup. Collision bounds, axle/pivot positions, work markers
and CP's selected turning radius retain their actual measured dimensions.

On the final approach, the controller compares the live work-envelope pose with
its predicted pose. A discrepancy above 0.25 m triggers one stopped recheck while
there is still room to steer. This threshold triggers replanning; it is not a
lowering tolerance. The remaining route is revalidated with the observed response,
then a bounded forward steering correction is tried if needed. No additional bulb
or post-lowering retry is allowed. Entries which still cannot align stop normally.

Tests replay the logged approach in both directions and drive a complete recovery
with independently faster trailer physics. They require one correction, aligned
entry, one lowering command and unchanged physical geometry. The field and physics
remain synthetic, so v0.17 still needs an in-game run. All 66 offline checks pass:
49 planner/runtime, 11 initial-entry, three tracking and three packaging/syntax.

Version 0.16 fixes the initial-entry recovery exposed by the 20:27 v0.15 log
on 15 September. The first local approach could not align (about 1.66 m edge
error). Two tractor-only CP pathfinder loops were then driven before their
trailer entry was checked; the first returned with about 78 degrees of joint
angle, and the second deviated about 10 m from its path. This was an entry and
tracking failure, not evidence of insufficient headland depth.

The initial CP approach is retained, including any permitted reverse sections.
If its final/local correction cannot align, one complete recovery is planned
using the same CP Dubins solver, trailer simulation and envelope controller as
the row turns. The whole candidate must pass joint, footprint and entry checks
before it moves. The envelope controller enforces the measured combination
radius while driving it. Failed execution cannot launch another recovery loop
or lower late. The original working row and CP/XML geometry remain unchanged.

Initial envelope approaches are capped at 8 km/h and do not acquire CP's changing
tight-turn lateral compensation. Ordinary CP starts and fieldwork keep their
existing compensation. No tolerance was widened and no PW-specific radius was
introduced. Recovery is forward-only; this does not add a reverse trailer solver.

Regression coverage replays the v0.15 starting geometry on both sides through
the actual planner, pursuit controller and lowering state machine, with finite
acceleration and hydraulic delay. Both must complete on the original row with
one lowering command. The test field is synthetic: the log did not capture the
complete live field polygon. Mounted, 6 m/12 m drill, plough, original short-row
order, cancellation, bounded failure and packaging regressions are also checked.
All 63 offline checks pass (49 planner/runtime, 11 initial-entry and three
packaging/syntax checks). In-game confirmation of v0.16 is still required.

Version 0.15 addresses the evening v0.14 session on 15 September. The last
recorded search was still calculating when the job ended; that session contains
no selected envelope bulb or envelope no-path stop. The saved course's first
row is only 3.09 m long. Stock start-row handling initialised on its turn marker,
but the next waypoint callback advanced beyond it. The resulting search targeted
the third row from the first row's heading. The envelope hand-off now explicitly
preserves a short row's pending turn marker and uses CP's normal finish-row/raise
phase before turning. It does not reorder or regenerate the course.

In v0.15, initial centre-row entries retained CP's approach, including permitted reverse
sections, but hold lowering until the measured working envelope is aligned with
the original row. The same adapter handles the sequences supplied by up/down,
skipped rows, lands, racetrack and spiral generation. Headland entries and
unsupported equipment retain stock CP. An available local forward correction is
validated after plough rotation. If that cannot fit, the adapter asks CP's normal
pathfinder for another approach behind the original entry, using CP's existing
reverse permission, collision checks and fruit setting. Two reposition attempts
are permitted; neither pathfinder success nor the last waypoint bypasses the
alignment gate. No reverse-only envelope solver or fixed 20 m approach is added.

Candidate screening now uses a planar transcription of CP's pursuit calculation,
avoiding scene-node creation during coarse samples. Every accepted candidate
still passes the production PPC and full footprint/joint/entry validation.
The recorded first-turn replay produced the same 312-trial path in approximately
4.2 seconds rather than 18.4 seconds offline; this is not an in-game timing claim.
Long searches now report candidate-count progress at five-second intervals.

The v0.15 build passed 61 checks: 49 planner/runtime regressions, nine initial-entry tests and
three packaging/syntax checks. The initial-entry fixture drives a mounted tool,
6 m and 12 m drills and PW-style trailed geometry from an offset, angled approach,
with finite acceleration and hydraulic delay. Tests also cover the short-row
hand-off, reverse permission, original-row targeting, rotation timeout,
cancellation and bounded failure. These use planar physics and mocked GIANTS
interfaces; the v0.15 start, reverse repositioning and complete field still need
confirmation in the game. CP/XML dimensions and entry tolerances are unchanged.

Version 0.14 addresses the fresh v0.13 run stopped at 09:41:20 on 15 September.
The first bulb took 318 trials and 83 seconds, then the plough rotated normally.
The measured tractor and implement headings differed by approximately 53 degrees.
The local entry search exhausted 96 trials, with a best predicted error of 0.389 m.
This was numerical exhaustion before driving the correction, unlike v0.12's
live entry-gate failure.

The local search's lateral-lead bound treated the steering target as an isolated
curve and allowed only about 1 m of lead in this pose. Searching all 2,016 old
parameter combinations still failed in the offline replay. The search now keeps
that compact bracket first. If minimisation presses against its edge, it widens
the bracket within half the implement width, one third of the remaining approach
and 3 m, before changing tangent lengths. An interior minimum instead moves on
to the next tangent pair, retaining the older cases' search-time limits.
The full tracked correction must still satisfy CP's resolved radius, joint
limits, boundary clearance and the original entry tolerances. It cannot loop
back out or lower early. No implement-specific dimension selects this behaviour.

The recorded geometry and its mirror now pass in 20 trials with approximately
2.49 m lateral lead, 0.0474 m worst predicted entry error and the same 4 m straight.
The corrected shape revalidates in one trial when reused. Both directions also
complete the production PPC/entry-state-machine fixture with finite acceleration
and hydraulic delay. A separate replay passes against the field's map outline
with recorded working corners and approximate tractor corners. These checks
do not reproduce GIANTS' physics or live field density; an in-game run is required.
The initial 83-second bulb search is not changed by this local-entry fix.
All 47 integration tests and three packaging/syntax checks pass for v0.14.

Version 0.13 addresses the stop after 34 successful v0.12 entries on 15 September.
The 35th turn found and drove its bulb, rotated the plough normally, then selected
a cached local correction with 0.064 m worst predicted admission error. The live
entry check measured 0.102 m against the unchanged 0.100 m limit and stopped before
lowering. CP reported no path found, but numerical pathfinding had succeeded.
Successful entries in that run ranged from 0.008 m to 0.067 m, with a maximum
heading error of 0.15 degrees. The field did not finish.

Cached corrections now meet the same preferred 0.050 m modelling margin as fresh
candidates before returning immediately. A marginal but finely verified candidate
is retained as a fallback while the existing bounded search attempts to improve it.
Good cached shapes still take one trial. Boundary, joint, lowering and live entry
guards remain unchanged, including the bounded 0.075 m repair fallback: this is
not a claim that every physical tracking discrepancy has been eliminated.

The failed snapshot and its mirror refine the reconstructed cached correction
in six trials, from approximately 0.064 m to 0.012 m worst predicted error, with
the same 4 m straight. This uses a different sideways lead, not a fixed increase
in run-in distance. A new log records the cached and selected margins so the
next in-game test can show when refinement ran. Regression checks also confirm
that the improved shape reuses in one trial and rejects a changed boundary.
These remain offline predictions; the first v0.13 game run is still required.

All 46 integration tests and three packaging/syntax checks pass. The recorded
failure also passes against the field's map outline with sampled work markers
and approximate tractor corners; this does not reproduce GIANTS' live physics
or field-density checks.

This build does not implement the separate extreme-pike entry-anchor experiment
or further change bulb-side selection. CP's existing row-end coverage adjustments
must be reconciled with actual inner-boundary geometry before that work is safe
to integrate; simply applying the experimental offset could count it twice.

Version 0.12 follows five completed v0.11 entries, with live working-edge errors
between 0.019 m and 0.063 m, and a sixth turn which exhausted 250 candidates.
The first bulb still took about 9.5 seconds to calculate on each turn. Replaying
the sixth snapshot against the nearby sloping map edge reproduces the failure:
smaller sampled radii violate articulation, while larger ones cross the boundary.
The search now also tries the midpoint between those radius factors. The replay
passes in 64 trials, without changing joint limits, boundary reserve or entry
tolerance. Radius factors apply to CP's resolved combination radius; no implement
name or fixed measured turning radius selects this behaviour. Exhaustion logs
now count every rejection reason instead of reporting only the last trial.

Candidate preparation runs during CP's final straight row-finishing phase and
while a reversible plough centres, with a two-millisecond numerical budget per
update. Stock CP still controls lifting at its chosen working marker. Preparation
cannot steer, lower, raise or install a path. After a completed turn the strategy
retains a numerical raised-state model for the same attached equipment and
dimensionless bulb parameters, mirrored where appropriate. Every execution
recaptures the actual stopped geometry and rebuilds and finely validates its
candidate against the current field. A changed rig, rejected guess or incomplete
preparation falls back to the ordinary search. An identical validated shape
replays in one trial. A loaded course without a field polygon still waits for
normal field detection; short rows and changed geometry may still require
stopped planning. Post-turnover repair remains separately validated.

The bulb now prefers the worked side where CP's outgoing-row attributes identify
exactly one worked side. It tries the corresponding alternative three-arc
Dubins family at compact bend lengths, then falls back to the unrestricted
search if those candidates do not pass. This leaves CP's shared solver unchanged.
Both directions retain full footprint, articulation and entry checks. The 25-degree
pike fixture shifts the bulb about six metres towards the worked side and reduces
its reach towards the unworked side by about six metres, with the same 5 cm
planned entry tolerance. Skipped-row drills can fall back when a three-arc bulb
cannot span the row spacing. CP's attributes reflect planned course order, not
measured soil coverage; unknown or ambiguous sides do not force a preference.
Logs identify the side and whether the preferred bulb was actually selected.

All 45 integration tests and three packaging/syntax checks pass. These are offline
geometry, controller and map-edge regressions. The first v0.12 in-game run is still
required to confirm execution, the preferred bulb and reduced waiting.

Version 0.11 follows two confirmed v0.10 working entries (0.041 m and 0.044 m
live error) and a third local-search failure. Post-turnover searches took about
9.9 s, 1.9 s and 12.4 s respectively, separately from the roughly seven-second
stock turnover. The third exhausted 96 trials with a reported 0.050059 m error.
The exact geometry replay also reproduces exhaustion before this change.

Local repair now evaluates the worst working-corner error over the complete
lowering/entry interval. It minimises that error with a bounded golden-section
search rather than solving signed mean error at a candidate-dependent first
failure point. Failed trials remain failed even if they align later. Changes
to the incoming tangent are tried before lengthening the straight. The 5 cm
margin is now a preferred target; a finely verified repair may use up to 7.5 cm,
leaving at least 2.5 cm before the unchanged live 10 cm limit. Physical heading,
boundary and joint checks remain mandatory. This avoids treating tiny misses
of an optimisation target as proof that no acceptable path exists.

Replays of all three deployed snapshots and their mirrors pass: 14, 4 and 28
trials respectively, versus 53, 5 and exhaustion at 96. These are geometry-only
replays: they do not establish live execution or field-boundary feasibility.
After a successful live entry, the strategy retains dimensionless shape
parameters for that turn direction. A later turn rebuilds that guess from its
current pose and width and runs coarse/fine validation; rejected guesses fall
back to the normal local search. No path, field clearance or model identity is
cached as approved. The log reports shape reuse, worst admission error and
planning duration. Rotation must still finish before measuring its final shape;
this reduces calculation delay rather than driving an unchecked rotating tool.

Version 0.10 addresses the v0.9 stop during hydraulic movement. The live log
recorded lowering at 0.094 m / 0.71 degrees, then stopped 0.54 seconds later at
0.101 m / 0.70 degrees, before the lowering wait had completed. While lowering,
the tractor now remains braked and intermediate alignment errors do not abort
the job. Boundary, articulation and premature entry checks remain active.
After the configured hydraulic duration and CP readiness checks pass, the
settled envelope must satisfy the original 0.1 m / 2-degree limits before
movement is released. Persistent displacement still stops and raises the tools;
the row target is not recalibrated to hide displacement. A READY log records
the settled result separately from LOWER and ENTRY.

The planner now reserves half the live lateral allowance for tracking and
settling: candidates must stay within 0.05 m from the lowering gate through
entry. This is a modelling margin, not a relaxed runtime threshold or a
PW-specific dimension. Replays of the latest geometry and its mirror verify
that a local correction with this margin exists. Tests also apply temporary
marker movement while stationary, complete runtime entry with mounted/trailed
tools, and reject movement that persists after lowering. Offline testing cannot
establish how far the live implement will settle; the first v0.10 game test is
still required. Width/overlap-based live tolerances remain future work.

Version 0.9 follows the v0.8 live attempt: the local correction was found in
five trials, but lowering stopped at 0.154 m lateral error / 0.63 degrees.
The 0.1 m lateral limit has not been relaxed. A yaw-locked input coupling can
carry a front drawbar component whose actual yaw pivot is inside the implement.
The geometry adapter now uses GIANTS' declared turning pivot when its component
joint connects directly to that tractor-fixed input component. Hitch position,
axle lever, working markers and footprint all use this same pivot; the exposed
internal yaw limit also constrains articulation. Ordinary towing hitches retain
their input pivot. No implement names, measured PW dimensions or fixed angular
corrections are used to select this behaviour.

Prediction now checks alignment at the same pre-boundary lowering gate as live
execution, and retains it through entry. A candidate that only straightens
after that gate is rejected before driving. Generic fixtures independently
place the coupling and physical pivot, verify invariant marker geometry through
articulation, and complete entry with 5.6 m, 6 m and 12 m tools. All 33 integration
tests and three packaging/syntax checks pass. These are planar offline tests;
the remaining live entry error is not yet confirmed resolved.

Version 0.8 addresses the next v0.7 live failure: after rotation, the tractor
stayed stationary for 28 seconds while the local cubic family exhausted its
entry-alignment candidates. The corrected direction node was active and the
headland estimate remained 45.1 m. Changing tangent lengths alone did not supply
the necessary sideways steering lead from that measured working position.

Local corrections now include a smooth lateral lead which is zero, with zero
derivative, at both endpoints. Its amplitude is solved from the working edges'
signed error, balancing the most negative and positive displacements rather
than forcing one rear corner to zero while the front aligns too late. The
original strict per-edge, heading, braking-lead and footprint checks remain.
The path must progress towards the incoming row and cannot create a second loop.
Searches are limited to 96 candidate attempts and interleave tangent/straight
choices. Failure records include the trial count and best sampled entry error.

The logged 18:11:02 working-position snapshot and its mirrored counterpart both
find a verified planar correction in five trials (about 0.071 m predicted entry
error), instead of exhausting the previous family. This is not a field-boundary
or GIANTS-physics replay: neither was recorded in the log. The live result still
needs checking; no measured dimensions or fixed PW-specific bias were added to
production code. The first bulb's side selection is unchanged.

Version 0.7 follows stock `AIReverseDriver`'s direction-reference choice for
rotating/offset implements: prefer the tool's `getAIToolReverserDirectionNode()`
and fall back to `steeringAxleNode`. Measurements, trailer propagation, footprint
and live entry assessment now share that selected reference. Previously they
unconditionally used the ordinary steering-axle node, which need not point in
the wheels' travel direction on a reversible plough. No fixed angular correction
or model-specific value is applied. The log reports the selected source and its
heading difference, plus any separately declared turning-radius pivot.

The installed PW model declares a dedicated reverser node beside its wheel-axis
assembly; stock CP explicitly prefers that reference for rotating ploughs. In
the v0.6 live attempt the predictor expected 0.047 m error but entry was rejected
at 2.625 m / 10.22 degrees. This build corrects the reference selection; its live
effect remains to be verified. Tests cover both signs of a skewed ordinary node,
correct marker projection, the old false alignment rejection, and complete
runtime entry with the explicit direction node. These are still planar tests.

Stationary planning now has an 8 ms rather than 4 ms per-update budget, retaining
small sample batches and cancellation. This should reduce waiting; individual
engine calls can still exceed the budget. It does not change the approach speed
or loosen the alignment thresholds.

Version 0.5 restores stock CP plough centring through the main turn. CP's
`PlowController:onFinishRow` explicitly centres reversible ploughs to permit
tighter turns without the tractor's rear wheel touching the plough. The previous
test incorrectly moved the plough to its next working side before planning.
This version measures the centred outline, then uses the stock controller to
rotate on the final approach. It stops during rotation, remeasures the working
position and validates the remaining approach.
No new fixed turning radius or model-specific dimensions are introduced.

Version 0.6 addresses the live v0.5 sequence recorded on 14 September: the first
loop completed, rotation changed the working markers, remaining-approach
validation failed, and a full new loop was selected. That second loop failed
live entry alignment (8.535 m / 30.96 degrees), despite passing the predictor.
The initial loop family and its side selection are unchanged.

After rotation, the planner now first validates the existing approach, then
searches only local forward cubic corrections towards the row. It cannot launch
a second full loop with the deployed plough. The corrections retain the radius,
articulation, boundary and strict entry checks. If none passes, the job stops.
The initial outgoing headland estimate is retained: remeasuring along the
inward-facing tractor had incorrectly increased it from 45.1 m to 112.3 m.
Private prediction waypoint logging is disabled even with CP debug enabled.

An offline replay of the recorded post-rotation position and working markers
finds a local correction with 0.045 m predicted entry error. The log did not
include field vertices, so this validates the alignment calculation only. It
does not establish that the live rig will follow it or that it fits that field;
the runtime still checks the detected polygon, islands and field density.

The v0.4 live attempt stopped before path search because its loaded course had
no field polygon. Version 0.5 invokes CP's existing asynchronous field detector
when the polygon is missing or belongs to another field. It waits for the
completed boundary and islands before planning; failed detection still stops.

Version 0.4 projects all measurements from world positions into horizontal
heading frames. Previously, local 3D pitch/roll contaminated the planar lengths
and marker offsets. Passive lateral axle offsets are now retained, rather than
rejected above 0.25 m; the longitudinal hitch lever controls trailer yaw while
the lateral offset remains in the body/marker positions. Tests cover both rolled
plough sides, pitch and offset axles.

Prediction and live execution now share a curvature calculation. The new turn
returns an equivalent goal in GIANTS' AI steering-node frame, enforcing CP's
resolved combination radius even when the tractor can steer more tightly. This
also handles a steering-node origin different from the PPC direction node. The
prediction PPC uses the actual tractor radius for its waypoint-passing tests.
The original engine still owns steering slew and physical movement; instantaneous
planar prediction does not reproduce every hydraulic, tyre or soil effect.
Version 0.3's live entry failure is not considered resolved until rechecked in
game. Geometry snapshots and two-second TRACK records support that comparison.

## Runtime compatibility

FS25 embeds Luau, not standard Lua. The [official Luau repository](https://github.com/luau-lang/luau)
lists Farming Simulator 2025 among its users. Luau derives from Lua 5.1 and has
a gradual, optional type system. Luau itself supports coroutines; their absence
in our live FS25 session is a restriction of GIANTS' embedded environment.

The bench currently executes through Lupa/Lua 5.2, with a separate Lua 5.1
syntax check. These validate numerical behaviour and baseline syntax, not the
Luau VM or GIANTS API availability. Removing `coroutine` from those tests covers
the observed failure but does not reproduce every FS25 restriction. Check
engine calls against [GIANTS' FS25 API](https://gdn.giants-software.com/documentation_scripting_fs25.php)
and validate execution in game. Standalone Luau validation remains to be added;
it would still not replace the GIANTS runtime check.

## Architecture

The shared Dubins solver has **not** been changed. The implementation has three
commented Lua modules, loaded explicitly through `modDesc.xml`:

- `scripts/ai/turns/EnvelopeTurnPlanner.lua`: numerical candidate generation,
  trailer propagation, working-envelope alignment and boundary checks.
- `scripts/ai/turns/EnvelopeTurnGeometry.lua`: live equipment dimensions, working
  markers, attachment pivot, effective steering axle, field polygon and islands.
  It also supplies a private production CP pursuit controller for prediction.
- `scripts/ai/turns/EnvelopeCourseTurn.lua`: a `CourseTurn` subclass owning
  preparation, time-sliced planning, execution, hydraulic waiting and hand-off.

The fieldwork strategy has a small, documented selection hook. An enabled,
supported row turn uses the new class. Headland corners and loop-on-headland
turns retain their existing code. Turning the new setting off retains CP's
normal row-turn choice, including K turns and pathfinder turns.

## What the first test implements

After finishing the row, CP's existing work-end handler raises the implement.
Its configured late-raise behaviour still waits for the rear working marker.
The new strategy stops, waits for stock plough centring to finish, and measures
that position. A centred plough uses the actual collision outline plus current
AI markers only when all four size probes hit. If any probe misses, the nominal
dimensions remain a conservative fallback. The working width still defines row
spacing; it does not force a centred plough to have its deployed body width.

On the final approach, CP's unmodified plough controller decides when to rotate
to the next side (within 30 degrees of the incoming direction). Lowering remains
disabled. The tractor stops while rotation completes, then the new geometry is
checked against the remaining path. It cannot resume from an unchecked working
position or lower against the saved centred marker positions.

The tractor radius comes from `AIUtil.getTurningRadius`, retaining GIANTS/CP
calculations and vehicle-configuration overrides. A PW profile is not embedded
in the planner. Working markers and body dimensions come from the actual rig.
CP's size scanner is read in its root frame and explicitly transformed: its
current reference-node implementation does not relocate the probe origin.

Candidate turns combine an unchanged Dubins curve, a bounded cubic sideways
pull-in and a short final straight. The lateral bias is solved against rear
working-edge displacement. Larger available headlands seed a longer tail and
farther outgoing placement. Pikes use both actual row endpoints, so moving from
short to long work includes the next row's greater outward distance.

The cubic curvature bound prevents commanding a tighter radius than the selected
candidate allows. Each candidate uses the production CP pursuit controller for
goal-point selection and a planar tractor/passive-trailer motion model. Coarse
0.15 m steps are rechecked at 0.075 m before acceptance. Calculation yields
between batches with an 8 ms update budget; individual engine calls can exceed
that budget. Equipment is scanned before planning and again after plough rotation.

The steering-goal conversion follows the curvature interface documented by
[GIANTS' FS25 AIVehicleUtil](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=91&class=881&version=script).
No shared GIANTS function or stock CP turn is patched. Outer field polygon,
island and density checks are unchanged.

Accepted candidates require all sampled work-edge errors <=0.1 m, heading error
<=2 degrees and clearance of the scanned tractor/implement perimeter. Concave
field polygons and island edges are checked, with 0.5 m reserve. Density queries
also reject non-field patches. A 0.25 m membership cache adds its half-diagonal
to the reserve, so cache rounding cannot turn insufficient clearance into a pass.

During execution the speed is capped at 8 km/h. On entry it slows, stops about
0.5 m before the first soil-engaging corner crosses the inner boundary, checks
live marker alignment, lowers through CP's normal per-object handler, waits for
the configured hydraulic duration and implement readiness, then enters at
3 km/h. This first build prioritises a verifiable entry over continuous-speed
lowering. It can work slightly into the already worked headland during lowering.

The end-of-course callback cannot bypass alignment, and the usual tight-turn
offset is disabled on the selected path: adding it would change the path after
it had been checked. Late lowering, unvalidated recovery paths and a silent
fallback after a failed supported-rig search are deliberately excluded. The job
stops with CP's no-path message and a specific log reason instead.

## Test procedure

Keep the live ZIP in the mods folder and enable only the test version for this
save. Use `FS25_Courseplay_EnvelopeTurnsTest.zip`, shown in game as
**CoursePlay - Envelope Turns Test**. It is separate from both the live ZIP and
the implement-directory test ZIP; retain this filename for subsequent builds.
The source setting defaults off; the local test package enables it by default.
For a vehicle already saved with this setting, its saved choice takes precedence.

1. Attach and unfold the PW 100-12, with its normal CP `pw10012.xml` override.
2. Check **CP vehicle settings → Implement → Aligned implement row turns (test)**.
3. Generate or load a course on the current field, initially with nine headlands
   and adjacent up/down rows. Missing field geometry is detected automatically
   while the vehicle waits at the turn.
4. Test straight ends, short-to-long pikes, then the same equipment with a
   larger headland. Compare with the setting off if desired.
5. For wider pike tests, use 6 m/12 m drills, skip six rows and start at short work.

The game log includes `[CP envelope]` records for preparation, measured geometry,
selected candidate, lowering and entry. Those records are written without
enabling verbose CP debug. A `stock CP turn selected` record identifies an
unsupported rig; a `STOP` record explains a failed candidate or runtime check.

## Validation and limits

`tools/turnbench/test_ingame_envelope.py` loads the exact production Lua modules,
Dubins solver, pursuit controller and work-start handler through the bench's
GIANTS boundary adapters. Tests cover the PW's straight/pike/large-headland cases,
6 m/12 m drills on 10/25/45-degree short-to-long pikes, insufficient headland,
concave boundaries/islands, coupling/marker measurements, exposed yaw limits,
live lateral misalignment, mounted tools, opposite turn directions, hydraulic
waiting, successful fieldwork hand-off, entry crossed before lowering/readiness,
last-waypoint protection and cancellation cleanup. Radius tests exercise the
actual CP resolver with the XML value and changed overrides, including 5 m;
the tractor's larger minimum still takes precedence. No PW-specific radius is
embedded in the runtime planner. Constructor and incremental-search tests cover
stationary preparation and prediction-node cleanup.
Additional tests use CP's actual `PlowController` to verify centring, delayed
working-side rotation, changed marker offsets and entry after expansion on
25-degree and 41.5-degree pikes. They also cover collision-probe fallback,
asynchronous field detection, rotation timeout and stationary replanning of an
invalid remaining approach. Angled test headlands use perpendicular depth, as
CP's polygon offsets do, rather than reducing usable depth with the field angle.

Run from the checkout with the bench Python environment:

```powershell
python -m unittest discover -s tools/turnbench -p test_ingame_envelope.py -v
python -m unittest discover -s tools/turnbench -p test_build_ingame.py -v
python tools/turnbench/build_ingame_test.py
```

These are offline checks, **not an in-game physics or collision certification**.
The first live run of v0.11 is still needed. Field-density data does not describe every
hedge/obstacle; CP's normal proximity controller remains active. A stopped job
does not imply that a different family of turn could never fit that headland.

Supported prediction is currently a rigid tractor with direct mounted implements
or one passive rear trailer, including a yaw-locked front drawbar with one
directly connected internal yaw pivot. Articulated tractors, attachment chains,
multiple wheeled tools and actively steered trailers retain normal CP, with a
log explanation. This integration adds forward steering-led turns; it does not
yet integrate the bench's experimental reversing K candidates.

The maximum articulation uses the smaller of the exposed raised-joint yaw limit
and an 85-degree numerical ceiling. Missing joint data does not prove clearance
between the drawbar and tyres; body-to-body interference and extra internal
implement joints still need a richer model. The 0.1 m/2-degree thresholds and
0.5 m reserve are test parameters, not agricultural or regulatory standards.
The rotation sweep itself is not simulated; the rig stops for rotation and the
completed working pose is measured before it drives again.

Future work: calibrate against recorded live tracking, add joint/body collision
constraints and chained/steered models, integrate checked compact reversing
alternatives, then remove unnecessary hydraulic stops where feedback permits.
