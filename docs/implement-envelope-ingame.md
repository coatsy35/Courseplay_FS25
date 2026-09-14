# In-game envelope turn test

Branch: `codex/implement-envelope-ingame`, based on `codex/implement-envelope-turns`.
The implement-directory changes are maintained separately and are not included.

Current test: **v0.9**, packaged mod version **8.1.0.109**. The ZIP filename
remains stable; the in-game title and `[CP envelope] v0.9` records identify it.
The earlier unnumbered builds used 8.1.0.3. Version 0.3 fixed their live
`coroutine.create/resume` crash: FS25 does not expose that library. The search
and simulation now retain explicit state between updates. All integration
tests run with `coroutine=nil`, including the complete startup path.

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
The first live run of v0.9 is still needed. Field-density data does not describe every
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
