# CP / turn-bench audit

## 15 September: shared envelope row-turn execution

Full-field mode now offers an explicit controller choice, defaulting to the
versioned envelope runtime. Its planner, geometry checks and `EnvelopeCourseTurn`
entry/lowering state machine are unchanged snapshots from test mod v0.15; CP's
production PPC drives those manoeuvres. Source and dependency hashes are checked
when loading. See `runtime/manifest.json` and `sync_runtime.py`.

The bench plans at the actual simulated row exit, retains trailer heading across
passes, and feeds the actual lowered envelope into final coverage. Failed entry
checks stop that simulated run and preserve their reason. Headland corners and
section-connecting travel still use the older adapter described below. Their
arrival at a central row is checked by the envelope entry gate, but stock hybrid
pathfinding/repositioning and physical plough rotation are not simulated. The
headland-first PW case currently exposes a rejected connection into the centre;
this is not presented as successful fieldwork or as a measured in-game result.

The original audit below remains applicable to stock comparison mode and these
remaining adapters. Runtime row turns supersede its older row-turn limitations.

Audited against this checkout on 13 September 2026. Scope: the fieldwork behaviours represented by the bench, not unrelated CP jobs or menus.

**Finding: the bench is not an in-game feasibility simulator.** It runs substantial production CP code, but its driving adapter, implement model and boundary rule are different. Passing the existing completion tests did not establish parity. In particular, the default PW scenario is not validated against an in-game recording.

## Behaviour comparison

| Behaviour | CP source | Bench implementation / finding |
|---|---|---|
| Default generator settings | `config/CourseGeneratorSettingsSetup.xml` | Browser defaults now match the exposed settings: sharpening enabled, 7% overlap, automatic angle, two racetrack circles. Deliberate exceptions: zero rounded headlands and the user's nine-headland PW preset. Older API/saved fixtures retain their defaults. |
| Headlands and centre, row patterns, split blocks and connections | `FieldworkCourse.lua`, `Center.lua`, `BlockSequencer.lua`, `RowPattern.lua` | Production generator runs directly. Full-field mode uses the complete route; selected-pass tests deliberately discard short rows and select a subset. They are not interchangeable tests. |
| Automatic direction | `Center:_findBestRowAngle()` | Direct CP implementation: candidate angles in one-degree steps, scoring rows, blocks, small-block penalties and longest-edge alignment. |
| Manual direction and baseline override | `CourseGeneratorInterface.lua`, `Center.lua` | Browser compass angle now converts to the mathematical generator angle as CP does. Baseline uses the edge nearest the start location and takes precedence. Sloping fixture deliberately selects a manual direction; automatic remains available. |
| Start location / headland-first / centre-first | `CourseGeneratorInterface.lua`, `FieldworkCourse.lua` | Passed to the production generator. The start percentages are bench coordinates, not an actual vehicle location. |
| Reverse complete course | `FieldworkCourse:reverse()`, `WaypointAttributes:_reverse()` | Each fleet path is reversed and CP reverses the attributes, including row and pathfinder markers. Reversing also reverses the original work order. |
| Sharp headland corner geometry | `CourseTurn:generateCalculatedTurn()`, `HeadlandCornerTurnManeuver`, `Corner.lua` | Previously missing. Now calls the production reverse/forward/reverse corner generator at CP's headland-turn markers. Uses direction-node-to-implement-axle distance for the corner steering length and CP's forced tight-turn offset calculation. |
| Headland direction-switch controls | `CourseTurn:changeDirectionWhenAligned()`, `changeToFwdWhenWaypointReached()` | Now represented: switch to forward when the arc target is ahead of the reversing tractor, and switch back when the implement is within CP's five-degree alignment threshold. Still uses the bench's pursuit/progress controller, not CP's PPC. |
| Ending a turn in reverse | `CourseTurn:endTurn()`, `WorkStartHandler` | Reverse lowering was incorrectly called as forward lowering. Now passes the reverse flag and resumes the outgoing course when lowering is requested, rather than driving the entire generated reverse buffer. |
| Finishing work before a headland corner | `AITurn:finishRow()`, `TurnContext:createFinishingRowCourse()`, `WorkEndHandler` | The single rear-implement adapter now follows CP’s straight finishing course and polls the production WorkEndHandler against the simulated front/rear marker. On the raise request it generates the corner from the live simulated tractor pose, rather than the preceding course waypoint or the end of a fixed buffer. CP’s corner-angle overshoot shifts both work boundaries. **Still incomplete:** multiple/chained/front implements, exact live AI markers and controller events. |
| Headland loop option / front-mounted harvesters / chained implements | `CourseTurn:generateCalculatedTurn()`, `CombineHeadlandTurn` | **Incomplete.** Full-field sharp corners currently use the rear-implement reverse manoeuvre. The isolated loop test is not a full implementation of CP's headland-loop setting, combine logic or chained implements. |
| Row turns | `DubinsTurnManeuver`, `ReedsSheppTurnManeuver`, `TurnContext` | Production analytic solvers run, but the bench supplies a simplified turn context and synthetic straight continuation. Its explicit selection does not reproduce CP's full K-turn/pathfinder/analytic decision tree. |
| Headland-to-centre and block transfers | `CourseTurn:startTurn()`, `PathfinderUtil` | The adapter now targets the first working row after the complete connecting section, using CP’s goal/alignment offset and ordinary fieldwork trailer correction. Trailed implements cannot reverse during pathfinding, independently of straight analytic-turn fallback. The previous intermediate-waypoint goal caused an unnecessary loop. **Still approximate:** the CP analytic solver runs without the full hybrid-A* search, preferred-path penalties or live obstacle checks. |
| Pursuit, speed, reverse driving | CP PPC, `AIReverseDriver`, fieldwork strategy | CP trailer correction is called. The wrong lateral-offset sign has been corrected against Waypoint:getOffsetPosition, and forward progress/lookahead now use offset waypoint positions consistently. CP steering length now includes hitch setback, while physical trailer integration retains hitch-to-axle length. Vehicle pursuit, speed and integration remain bench code. Live proximity handling, slipping, suspension, steering modes, articulation stops and blocked-vehicle recovery are not reproduced. Reaching the last waypoint is not proof of safe or accurate driving. |
| Implement geometry | GIANTS nodes, joints, work areas; `AIUtil` | **Estimated:** one passive trailer, simple tractor body, rectangular working footprint. Raised/folded physical envelopes, plough turnover and offset/non-rectangular work areas are not modelled. A working-area rectangle is not a measured collision body. |
| Configuration overrides | `VehicleConfigurations`, `ImplementProfile` | Catalogue applies width, turn radius, correction distance and raise/lower overrides only. Configuration-dependent node selection, geometry, runtime implement profiles and the remaining XML options are not automatically applied. |
| Boundary checking | Field probes and runtime collision/proximity/pathfinding | **Not CP's rule:** bench tests estimated bodies against the cropped-field polygon with an additional 0.5 m reserve. A working swath at the outer field edge can therefore fail even when positioned exactly on its generated headland. A crop boundary is not necessarily the physical hedge/collision boundary. No minimum headland requirement can be inferred from this deficit. |
| Islands | `Island.lua`, production generator | Generation runs directly against synthetic circular islands. No GIANTS obstacle discovery, terrain or runtime island pathfinding. |
| Multiple vehicles | `FieldworkCourseMultiVehicle.lua` | Production course generation and individual simulated playback; no inter-vehicle traffic coordination or collision avoidance. |
| Coverage / raise-lower timing | `WorkStartHandler`, `WorkEndHandler`, bench raster | Production marker decisions are used in supported turn paths. Hydraulics/controller events are timed approximations. Coverage is sampled in the isolated/selected-pass tests, not verified over a complete field. Entry metrics now require an actual inbound crossing, avoiding false 90°/180° readings on the outgoing turn leg. |

## Concrete PW reproduction

The 220 × 240 m rectangle, PW 100-12 preset, nine headlands, zero rounded
headlands and automatic row angle was reproduced. The original 159 m excursion
was a missed headland-to-centre reversal. After the connector and corner changes,
playback reaches the end and executes the corner reverse/forward/reverse legs.
However, the estimated footprint check still fails, and the simulated combination can still exceed
90° articulation during a row turn. This is a failed physical validation,
not evidence that the game needs more headland. Do not use these outputs to
select a minimum headland or a safe drawbar angle.

The displayed generated course includes CP's forward/reverse buffers; runtime
controls skip part of those buffers. Boundary rejection uses sampled driven poses,
not merely the extent of those displayed helper waypoints.

## Required validation before trusting headland recommendations

1. Extend the single rear-implement headland finishing sequence to front/chained implement cases, controller events and the headland-loop option; complete the end-turn adapter.
2. Match runtime turn selection, PPC behaviour and obstacle-aware connectors; verify actual path tracking and articulation rather than completion alone.
3. Import measured tractor and implement geometry, live AI markers, selected configuration/profile and working/raised states. The existing capture mod provides a route to obtaining those observations; it has not yet been validated in game.
4. Compare the same CP-generated course and recorded turn against the bench, including request times, gear switches, tractor pose, implement pose and all relevant marker crossings.
5. Treat crop-edge coverage and physical collision clearance separately. Keep the bench's current conservative rejection visible, but do not describe its deficit as a headland increase required by CP.

This audit does not certify a safe PW headland depth or claim full CP/GIANTS parity.

## Finishing-row follow-up

The PW browser diagnostic completed 37 sharp headland turns with 37 corresponding
finishing-row raise requests. The turn is rebuilt at each request from the actual
simulated pose; CP regards “all raised” as requests issued, rather than completed
hydraulic travel. Regression checks distinguish early/front and late/rear marker
crossings, and check acute/obtuse corner work boundaries and CP's overshoot cap.
That stage did not resolve the separate connecting-turn articulation failure
or validate the model against the game; see the subsequent connector correction below.

## Connecting-section follow-up

The original PW connector peaked at approximately 106.6° articulation. The
corrected complete-section target, CP alignment offset, fieldwork trailer
correction and waypoint-offset sign reduce this to approximately 79° in the
same diagnostic case. The connector remains forward-only for the wheeled
trailed implement, matching AIDriveStrategyCourse's reverse-pathfinding gate.
The straight reverse fallback for analytic row turns remains a separate option.

Tests compare steering with production Waypoint offset coordinates in four
orientations, check mounted/trailed reverse eligibility, and verify that the PW
connection reaches the first working row without folding beyond 90°. That test
threshold is **not a physical joint limit**. The complete route still reaches
approximately 103° in a separate row turn; live joint limits, the combination's
GIANTS-selected turning radius and physical collision geometry remain unverified.
No boundary check or articulation angle has been clamped to make these tests pass.

The isolated turn simulation now defaults to a 0.025 s integration step. Its
convergence test compares this with 0.0125 s at the original 0.05 m lateral-error
and 0.5 m² coverage tolerances; the older 0.05 s step missed the lateral tolerance
after correcting steering. Entry error is interpolated at the boundary crossing,
and exported playback frames retain their 0.1 s spacing. Full-course integration
is still the separate 0.1 s model and has not acquired this accuracy guarantee.

### PW preset calibration from live debug output (13 September, 22:55–22:56)

The default PW preset now uses the logged 5.6 m width, 4.6 m front and 18.3 m
rear marker setbacks, 1.9 m hitch setback and 2.5 s lowering duration. The logged
13 m tractor-reference-to-steering-node distance maps to 11.1 m hitch-to-axle
length in the single-trailer bench. This is a calibration for the recorded
Challenger 55/PW combination, not an intrinsic dimension for every pairing.
The PW preset no longer supplies its own radius: the automatically selected
`pw10012.xml` CP configuration supplies 9 m. The 5 m course-generation radius
in the live log is separate from the logged 9 m runtime turn radius.

Evidence is retained in `out/pw10012-live-turn-2026-09-13.log`. CP's measured
lowering allowance was about 6.1 m; it starts the hydraulic operation before
front-marker crossing. These calibrated inputs do not certify the simplified
body footprint, articulation or full-field boundary feasibility.

### Course display filter

Full-course runs retain the original CP-generated waypoint polyline separately
from the compiled manoeuvres. The toolbar's Show turns filter defaults to off;
it exposes turn paths, reverse sections and rejected footprint overlays without
changing the simulation, playback eligibility or boundary verdict. Browser
checks cover rectangle/sloping PW runs, configuration defaults, filter toggling,
playback and JavaScript errors. Boundary feasibility remains unverified pending
an in-game outer-headland corner trace; the available 22:56 recording is a
central-row Dubins turn.

## Live-log calibration and current baseline status (13 September, late session)

This section supersedes the earlier boundary-rejection and missing-loop notes.

- Course-generation radius is now independent of driving radius: 5 m for the logged generator setup and 9 m from the PW runtime override. Older imported setups preserve their previous generator radius.
- Original working-course waypoints now receive production `AIUtil.calculateTightTurnOffset`, including rounded headlands. Correction is not restricted by the PW's 1 m analytic-turn override.
- The full-field **Loop turns on headland** setting defaults off, as CP does. When selected it calls `LoopTurnManeuver` instead of `HeadlandCornerTurnManeuver`; rounded corners and central-row turn selection are unaffected. Its ending straight is consumed before resuming the original course, preventing a return to an already-passed corner.
- A recorded ordinary inner sharp corner is retained in `fixtures/pw10012-inner-sharp-corner.json`. All 79 logged forward/reverse waypoints match the generated adapter path within 0.11 m using the rounded logged inputs. This validates planned geometry, not exact GIANTS physical tracking.
- The outer-corner recording at 23:19 included blocked recovery and two failed attempts; it is not a successful ordinary-corner reference. The 23:22 rounded corner was tracked directly, with smoothed correction reaching about 2.5 m. The normal inner sharp turn started at 23:27:18 with 17 m of field ahead, a 9 m radius and 13.1 m steering length.
- Full-course CP baseline playback no longer changes a completed tracking result into an execution failure solely because the approximate footprint extends beyond the field polygon. All estimates and sampled envelopes remain exported and can be shown with **Clearance details**. This does not certify containment, collision clearance, coverage or drawbar safety. Isolated/selected-pass boundary tests retain rejection.
- Browser checks cover default PW loading and override, rectangle/sloping sharp playback, rounded tracking, forward-only loops, course/turn filters and clearance details. They check actual completion and JavaScript errors, not just that Play is enabled.

The project task to make loop turns an implement-level preference is recorded in
`docs/implement-alignment-todo.md`; production setting ownership has not changed.
