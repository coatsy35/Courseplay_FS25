# Courseplay Turn Bench

A local visual test harness for trailed-implement row exit, turns and entry. It does not modify the mod,
install a game ZIP, create GitHub Actions or require Farming Simulator to be running.

See [the CP parity audit](CP_PARITY_AUDIT.md) for verified source mappings and outstanding runtime gaps.

## Experimental aligned entries

Open `http://127.0.0.1:56514/?mode=aligned` when using that server port, or choose
**Field & pattern → Run mode → Aligned entry comparison**. Set configuration,
then start playback. The original CP baseline remains a separate tab.

- Rectangle tests ordinary row entries; sloping tests pikes.
- **Rows across to next pass** tests short-to-long row transitions. For example,
  twelve PW widths at 25 degrees places the next entry 31.3 m farther out.
- More headland rows allow the planner to place the turn farther out when useful.
- Reversing enabled also tests K-type candidates. An unsuitable reversing turn
  is rejected rather than assumed feasible because the tractor alone fits.

The steering-led prototype uses the whole working envelope and a curved pull-in;
it does not require a fixed 20 m straight. See
[the planner notes](../../docs/envelope-turn-planner.md) for measured examples,
model limits and the remaining in-game integration.

## Run

Keep the bench on its own `codex/turnbench` checkout. A server keeps Python modules
in memory but reads Lua and model files from disk: switching its checkout to another
branch while it runs can mix versions or remove required files. The server prints
its model source directory at startup and reports missing source files explicitly.

This workspace uses `out/turnbench` as the dedicated checkout, with the existing
Python environment in `out/turnbench-venv`. From the main repository directory:

```powershell
./out/turnbench-venv/Scripts/python.exe -u out/turnbench/tools/turnbench/server.py --port 56514
```

Open `http://127.0.0.1:56514`. Keep this checkout on the bench branch and restart
the server after model-code updates. The live session's logs are in
`out/turnbench/out/server.stdout.log` and `out/turnbench/out/server.stderr.log`;
the command above writes logs to its terminal unless redirected.

Requires Python 3.10+ with a Lupa wheel available for that Python/platform. From the repository root:

```powershell
python -m venv out/turnbench-venv
./out/turnbench-venv/Scripts/python.exe -m pip install -r tools/turnbench/requirements.txt
./out/turnbench-venv/Scripts/python.exe tools/turnbench/server.py --port 8765
```

Open `http://127.0.0.1:8765`. Use `--port 0` for an available port, printed at startup.
After installation, the test bench works offline. The server binds only to loopback,
serves an allowlist of static files and has no file-write or shell API.

Settings are grouped into an accordion, with one main section open at a time. **Set configuration** stays at the
bottom of the panel and calculates the selected setup without starting playback.
Use **Start run** beneath the field to play it. Editing settings pauses playback;
apply them with **Set configuration** before running again. The default PW 100-12
configuration is prepared on opening the bench in **Full field / all rows and headlands** mode.
This follows every CP-generated row and section, without a pass count. Choose headland first
or centre first, and **Start point** or **End point / reverse course**. Reversing preserves
the exact generated route, reversing its row and pathfinder markers as CP does; this also
reverses the work order. **Selected passes / turn test** remains available for isolated checks.
**Number of round corners** defaults to zero; **Sharpen headland corners** stays enabled, as in CP.
New browser setups use CP’s 7% headland overlap, automatic row angle and two racetrack circles.
The PW preset retains nine headlands; selecting the sloping-side test deliberately selects
vertical rows (CP 0°). Saved setups retain their own values and older API fixtures retain their legacy defaults.
The irregular field defaults to a 36% left inset, adjustable between 10% and 55%.
Choose **CP Course Generator / layout only** for a static preview.

### Reading coverage and gaps

Full-field mode calculates coverage from the lowered working envelope at every
0.1 s simulation step. Green shows work completed by the current playback time;
**Final missed coverage** shows the pink areas left after all simulated passes.
Use **Show result** to see the completed field and **Missed area / whole field**
for its total. A gap filled by a later row or headland is not a final missed area.
For multiple vehicles, coverage combines their routes without double-counting.

Coverage normally uses 0.25 m cells inside the field boundary, excluding islands.
Large fields use a coarser grid to bound memory; the metric's tooltip reports the
resolution. Deliberately unworked field margins are included in the missed total.
These are modelled gaps from the current rectangular work envelope and simulated
lift/lower state, not measured FS soil coverage. The full-field baseline still
uses its existing CP movement model, not the newer in-game envelope test strategy.

## Tests

```powershell
./out/turnbench-venv/Scripts/python.exe -m unittest discover -s tools/turnbench -p "test_*.py" -v
```

The browser checks use Playwright (see `browser-test.cjs`). Pass the running server URL
and optionally the absolute path to a Playwright installation using `PLAYWRIGHT_MODULE`.
Screenshots are written to the ignored `out` directory.
`field-controls-test.cjs` accepts the same arguments and exercises rectangular/irregular fields,
all implement presets, mounted/trailed Custom setups, up/down, lands and racetrack,
pass-count changes, playback and comparison controls, and configuration-error recovery.
`complete-course-test.cjs` covers headland playback, elapsed-time speed, fleet selection,
saved setups, island routes, spirals and skipped rows. `test_full_course.py` also checks
all four patterns on sloping and irregular fields, reverse cusps and island clearances.

## What is real and what is mocked?

`bridge.lua` loads these **working-tree production functions under Lua 5.2**:

- `DubinsTurnManeuver`, including analytic path generation and correction flags.
- `ReedsSheppTurnManeuver` and `LoopTurnManeuver` for driven turn tests.
- `AIReverseDriver:calculateHitchCorrectionAngle` for trailed-implement reverse steering.
- `TurnContext:getTurnEndNodeAndOffsets` and `appendEndingTurnCourse`.
- `CourseTurn:onWaypointChange` and `AIUtil.calculateTightTurnOffsetForTurnManeuver`.
- `WorkStartHandler:shouldLowerThisImplement`.
- `WorkEndHandler:shouldRaiseThisImplement`, including front/rear marker selection by `raiseLate`.
- `State3D:getNextTrailerHeading` for single-trailer heading integration.

Planar node transformations and supplied vehicle/configuration data replace GIANTS accessors.
The path solver is the repository's existing Dubins implementation, not a second implementation.
Each API run loads fresh Lua state and source; Lua changes need a new run, not a server restart.
Restart the server after changing Python code, and refresh the browser after frontend changes.
Exports include the scenario, paths, frames, events, measurements and source hashes.
Use the folder button to load an exported setup. Its geometry is re-run against the current
working-tree Lua; old frames are not mistaken for new results. Treat this as an offline
configuration notebook, not an automatic writer of validated vehicle configuration entries.

**Not executed:** the entire CP strategy/PPC state machine, automatic turn-style selection,
GIANTS steering/physics, plough turnover, hydraulic animation and collision detection. The Python driver
uses bounded-curvature pursuit, a rigid hitch setback, one passive trailer and timed lowering/raising.
Drills pause during the model's lowering interval. The working area is a rectangular envelope,
not a reconstruction of GIANTS work-area triangles. A synthetic straight continuation is appended
after a single generated turn. With **Allow analytic reverse fallback** enabled,
CP receives the available headland depth and can shift its analytic turn and insert reverse
sections. The driver changes its controlled reference from tractor to trailer axle when reversing,
uses CP's hitch correction, and preserves the tractor/trailer pose through each gear change.
Reeds–Shepp turns are also driven. Reverse speed is independently configurable.

Complete-course playback uses the production CP polygon generator, including headland/centre
ordering, up/down with skipped rows, lands, racetrack, spirals (direction and inside/outside),
two-sided headlands, islands and one to five vehicle courses. It inserts CP analytic row turns
and resolves connector direction reversals with that solver. It follows the generated headland
geometry with the planar driver. **This is not the complete in-game runtime:** dynamic hybrid
pathfinding, live obstacles, traffic coordination, automatic turn-style choice and GIANTS physics
are not executed. Each fleet member runs independently; their playback shares one clock.
Boundary checks include each vehicle's modelled envelope and island interiors. Complete-course
coverage totals are left blank because the central-row coverage sampler does not measure a
whole field. A tracking failure or boundary rejection remains visible; neither is an in-game
feasibility verdict.

Steering profiles are **illustrative radius/hitch proxies**, not calibrated tractor models.
The articulated profiles also exercise CP's different correction-smoothing factor, but do not
simulate a chassis articulation joint. Tight-radius runs may exceed practical articulation limits;
there is no jackknife avoidance or collision guarantee. Geometry must be validated against the
specific vehicle before a result can inform a headland recommendation.

## Scenarios and comparison

The **Complete course / headlands and centre** and **Course layout / no motion** views run
CP's production polygon, headland, centre, block and row-pattern generator. Choose a rectangle,
an irregular outline with a tapered side and inward notch, or **Sloping side / angled row ends**.
Choose the left or right side. The slope defaults to 25° from vertical and accepts 5–45°.
Selecting this shape sets vertical rows (CP 0°). Use **Rotate rows 90°** for horizontal
rows (CP 90°). Automatic direction runs CP’s own row/block scoring; the boundary
baseline override follows the edge nearest the start position. Older sloping setups
without a side selection import as a left slope with horizontal rows.
Field width is the horizontal extent; length × tan(side angle) is the sideways
inset at the top of the sloping side. Impossible outlines are rejected rather than silently scaled.

Field length/width, working width,
headland count, row angle, overlap, rounded headlands, headland-first and clockwise
settings feed that generator. The visible **Work order** selector chooses headland
first or centre/up-and-down rows first, mapping directly to CP's `startOnHeadland`.
It orders both full playback and the static layout. Central-pass tests deliberately isolate the
requested rows. Up/down, skipped rows, lands, racetrack and spiral ordering all use CP algorithms.
The generator controls also expose field margin, automatic/manual row angle, baseline selection,
even row distribution, corner sharpening, start location, two-sided headlands and rounding.
The bench retains its existing 5% overlap default; CP's game settings default to 7%.

**Vehicles & islands** selects one to five vehicles and the vehicle whose telemetry is displayed.
Other vehicle routes and rigs remain visible. Headland counts follow CP's multiplication by the
number of vehicles. One to three circular island fixtures provide repeatable bypass tests; island
size, bypass, island headland count and direction are configurable. Invalid overlapping fixtures
are rejected. Two-sided headlands require one vehicle, headland-first and at least one headland,
matching CP's constraints. Generator warnings are displayed above the field.

The **Central passes / turn test** view runs 1–32 working rows, with
headlands at both ends. One pass means one row: four passes produce three turns.
Choose the total field length and headland row count; depth at each end is row
count × working width. The outer boundaries remain fixed and the central working
rows shorten as the headlands grow. At least 40 m of central row is required for
the two 20 m coverage samples. Row ordering comes from CP's up/down, lands or
racetrack classes. Field width is editable in both field views. Movement mode runs
the requested number of passes inside that width; it does not automatically fill
additional space with more passes. Width must accommodate those passes and both
side headlands.

Irregular movement uses actual CP-generated row endpoints and headlands. It selects
the requested number of consecutive usable rows (the group with the longest minimum
row length), then applies the chosen CP row pattern. Each turn targets the next
row's individual endpoint; tractor and trailer poses remain continuous. Row angle
and CP field-generation options are available for irregular movement. Short rows
under 40 m are excluded; insufficient usable rows produce an explicit error.
Connections needing a block-transfer manoeuvre are rejected, not invented.
If CP cannot generate all requested headlands, movement preparation stops with an
explanation. In particular, the 4 m drill on the tested notched field needs rounded
headlands set to 0; the rounded first headland otherwise prevents subsequent offsets.

The first row starts aligned and working. Subsequent rows carry the actual modelled
tractor and trailer pose through each turn and row, with alternating left/right
turns at the north/south ends. The final row finishes with raising. Headland rows
are drawn as bands in central-pass tests. Lightbulb turns can include CP's reverse
fallback. Complete-course playback also drives the headland passes.

Field measurements show worst entry angle/lateral error and summed missed coverage
in the sampled 20 m entry/exit zones. They do not claim whole-field coverage.
Exports retain per-turn measurements, end names, pass numbers and continuous frames.
Boundary rejection is enabled in the UI by default. CP receives the available
forward space; the bench preflights sampled tractor and implement footprints
against the rectangular or concave polygon boundary with a 0.5 m clearance reserve.
Polygon checks also test implement/tractor edges and the hitch-to-axle segment.
Unsafe runs show a static amber rejected route and sampled envelope, with the worst
sampled clearance deficit. They have no unsafe playback or coverage result. This is not CP's
reversing fallback or a collision guarantee, and no turning radius is scaled.
Disable rejection only to inspect an out-of-bounds diagnostic experiment. This
does not disable CP's analytic reverse fallback when reversing is allowed.
Automatic turn-style selection and optimising a turn for implement alignment
remain separate from the selected CP manoeuvre and its modelled clearance check.

In the historical selected-pass fixtures (not full-field playback), the approximate PW 100-12
geometry with nine headlands in a 220 × 240 m field passes the rectangular central-pass check. The irregular and sloping fixtures still require
about 3.7 m and 3.6 m additional modelled clearance respectively, even with the reverse
fallback enabled. This is a calibration/runtime-parity limitation, not proof that the
same setup cannot work in game. The boundary reserve has not been weakened to accept it.

Implement choices include the PW 100-12 at 5.6 m and generic 4/6/12 m drills.
PW 100-12 is the default. Custom scenarios accept a working width and a rigid
mounted or passive trailed attachment. Mounted tools use zero towing length in
CP's turn geometry and keep their work markers rigidly attached to the tractor;
the trailer axle length is unused. Both types still use approximate flat-ground
motion. The configuration picker is sorted by name and has search inside its popup.
The catalogue endpoint reads every vehicle entry from `VehicleConfigurations.xml`,
preserving attributes and configuration variants. Selection applies available width,
radius, tight-turn distance and raise/lower overrides only. The file does not supply
complete dimensions: missing values remain explicitly labelled test geometry.
Variant selection and unsupported overrides are not silently simulated.

`WorkEndHandler:shouldRaiseThisImplement` chooses front/rear markers for early/late
raising at the inner row-end boundary. `WorkStartHandler:shouldLowerThisImplement`
chooses front/rear markers and a lowering-time allowance at the inner row-start
boundary. The bench executes these Lua predicates; it does not substitute the
outer field boundary. Failed requests clear old results instead of displaying a
previous run under new settings.

- Trailed drill: generic geometry, useful for regression comparisons.
- PW 100-12 envelope: approximate geometry partly informed by the supplied log's 5.6 m width,
  14.3 m tractor-to-axle distance, 5.9/19.6 m marker setbacks and 9 m radius. Hitch geometry,
  work-area shape and animation are not calibrated. This does **not** reproduce the exact game rig.
- 45-degree drill entry: controlled counterexample, tractor on line and implement front 0.3 m
  before the work boundary. Demonstrates the production lowering predicate accepting a badly
  angled implement. It is not a replay of the supplied game log.

Dubins runs now start working 20 m before the exit boundary. The real raise predicate chooses
the front or rear marker. After its raise request, the entire rectangular working envelope stays
active for the selected raising time. The test driver continues straight until that timer expires
and minimum exit clearance is reached, then generates the turn at that actual pose. This is an
approximate timer model, not CP's complete turn state machine or progressive share lifting.
Early raising need not produce an exit gap with a full-width rectangular working envelope;
individual diagonal plough work areas must be calibrated before that result is meaningful.

Extra clearance increases the minimum exit distance; lifting may already need a greater distance.
The whole departure is animated and included in elapsed time. It tests additional settling space,
**not an implemented fix or an optimised turn**.
The comparison may improve or worsen an individual run; no optimisation is implied.

The turn selector offers driven Dubins row turns, Reeds–Shepp three-point turns and a
90-degree headland-loop test. The latter uses a synthetic target pose. Special-turn tests
animate raising/lowering and reversing, but do not report coverage or envelope-depth totals.
The synthetic 45-degree entry case has no exit or selectable turn.

Coverage is measured by 0.25 m cell centres over the first 20 m of the incoming working strip
and last 20 m of the outgoing strip. Exit working overshoot is the maximum active front-edge
distance beyond the work boundary, not overlap area or lift completion position.
Only active work envelopes and their swept front edge count. Pink cells show **final** missed
coverage, even during earlier playback; green coverage is animated. No overlap-area total is
claimed. Envelope depth includes a fixed approximate 3 m wide tractor extending 4 m forwards
and 2 m backwards from the reference point, plus the implement envelope. It is a run-specific
extent, not the minimum required headland. Empty entry metrics and `complete: false` mean the
run did not finish in the bounded 240-second horizon.

For the long-pike drill fixture, open
`http://127.0.0.1:56514/?mode=aligned&case=long-pike-12m`: 500 × 400 m field,
12 m drill, 25° pike and six skipped rows (84 m between driven rows).
Use **Whole field** to see the entire outline, or clear it to inspect the turn.
Field length remains editable. This mode plays the row-end experiment only.
Enable **Complete skipped-row block** to drive all 14 rows in CP's skip-six
order and fill the intervening rows. This checks coverage across the whole
working block, with green worked area and pink gaps; headland work is separate.
Use **Show result** for the finished coverage or playback up to **64×**.
`coverage-gallery.cjs` captures eight angles/directions for each of the PW,
6 m drill and 12 m drill. `build-coverage-gallery.py` builds their local gallery.
Complete-block links add `&block=1`; `&implement=plough` or `&implement=drill`
selects the PW or 6 m drill, and `&angle=45&direction=long` starts on the long side.
The browser regression `long-pike-angles-test.cjs` covers 10–45° short-to-long
and a 45° long-to-short control; results are recorded in
`docs/envelope-turn-planner.md`.

## Next validation steps

Retain this as a permanent development/configuration tool. Planned extensions, not yet implemented:

1. Calibrated work-area shapes and progressive lifting, rather than a rectangular exit envelope.
2. Calibrated trailed-implement K-shaped candidates and automatic turn-style selection.
3. Full runtime hybrid pathfinding and coordinated obstacle/traffic handling.
4. Calibrated conventional, four-wheel-steer, twin-track and articulated tractor/implement models.
5. Compare candidate vehicle-configuration values against measured game traces before exporting
   configuration profiles; retain saved scenarios and source fingerprints as regression fixtures.

Record time-stamped tractor reference, hitch, axle and work-area marker poses plus speed,
steering mode, lower/raise state and plough animation state from the game. Use those traces
to calibrate the movement model and replace approximate envelopes with measured geometry.
Add full PPC/state-machine integration and multi-joint vehicle models
before judging new manoeuvre selection. A passed offline test never replaces final in-game checks.

Vendored icons: Lucide 1.8.0, ISC licence in `web/LUCIDE-LICENSE`.
