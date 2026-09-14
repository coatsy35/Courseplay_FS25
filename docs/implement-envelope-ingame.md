# In-game envelope turn test

Branch: `codex/implement-envelope-ingame`, based on `codex/implement-envelope-turns`.
The implement-directory changes are maintained separately and are not included.

Current test: **v0.3**, packaged mod version **8.1.0.103**. The ZIP filename
remains stable; the in-game title and `[CP envelope] v0.3` records identify it.
The earlier unnumbered builds used 8.1.0.3. This revision fixes their live
`coroutine.create/resume` crash: FS25 does not expose that library. The search
and simulation now retain explicit state between updates. All integration
tests run with `coroutine=nil`, including the complete startup path.

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
The new strategy stops, places a reversible plough on the next working side
while raised, and measures that position. This intentionally checks the larger
working-side footprint instead of assuming a narrow, centred plough body.

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
between batches with a 4 ms update budget; individual engine calls can exceed
that budget. Actual equipment scanning happens once per turn.

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
3. Generate a course on the current field, initially with nine headlands and
   adjacent up/down rows. The adapter needs that field's detected polygon.
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

Run from the checkout with the bench Python environment:

```powershell
python -m unittest discover -s tools/turnbench -p test_ingame_envelope.py -v
python -m unittest discover -s .github/scripts -p test_build_mod.py -v
python tools/turnbench/build_ingame_test.py
```

These are offline checks, **not an in-game physics or collision certification**.
The first live run is still needed. Field-density data does not describe every
hedge/obstacle; CP's normal proximity controller remains active. A stopped job
does not imply that a different family of turn could never fit that headland.

Supported prediction is currently a rigid tractor with direct mounted implements
or one passive rear trailer. Articulated tractors/implements, attachment chains,
multiple wheeled tools and actively steered trailers retain normal CP, with a
log explanation. This integration adds forward steering-led turns; it does not
yet integrate the bench's experimental reversing K candidates.

The maximum articulation uses the smaller of the exposed raised-joint yaw limit
and an 85-degree numerical ceiling. Missing joint data does not prove clearance
between the drawbar and tyres; body-to-body interference and extra internal
implement joints still need a richer model. The 0.1 m/2-degree thresholds and
0.5 m reserve are test parameters, not agricultural or regulatory standards.

Future work: calibrate against recorded live tracking, add joint/body collision
constraints and chained/steered models, integrate checked compact reversing
alternatives, then remove unnecessary hydraulic stops where feedback permits.
