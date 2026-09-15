# Vehicle Geometry Capture

Standalone FS25 development mod. Captures independent, reusable machine geometry and optional
movement recordings. Works from loaded vehicles, including built-in machines. Courseplay is
optional; when accessible, its effective radius and per-machine override are included as contextual
observations. Version **0.2.0.0** adds a native button menu and restores actions whenever
FS25 rebuilds its player controls. Menu rendering still needs an in-game smoke test;
offline tests exercise button behaviour and input registration, not GIANTS rendering.

## Install and first PW 100-12 capture

1. Copy `dist/geometry-capture/FS25_VehicleGeometryCapture.zip` into your FS25 mods folder.
   Keep the ZIP intact. Enable **Vehicle Geometry Capture** on the save selection screen.
   It is a separate mod, with no replacement of the Courseplay test or live ZIP.
2. Enter your tractor with the PW 100-12 attached. Unfold and straighten on reasonably level ground.
3. Use **Capture: show panel** in Controls, or console command `vgcPanel`, to open the menu.
   New installations default to **left Ctrl + left Shift + G** to avoid Google Drive.
   Existing custom bindings are retained (including Ctrl + [).
4. Select the PW 100-12 with the **Machine** selector. This selects the capture target only.
5. Choose **long-narrow-trailed** in **Machine category**.
6. Set the actual plough state yourself. Select `plough-A-raised` in **State / manoeuvre label**,
   then click **Save geometry**. Repeat for A lowered, B raised and B lowered.
   A/B are your labels for the two working orientations; wait for each animation to finish.
7. Select the tractor and its steering category and capture it separately, straight and stationary.
8. For a movement test, choose its label and click **Start recording**, then **Back to driving**.
   Drive normally or let CP perform the turn. Reopen the menu and click **Stop recording**.
   Starting a recording saves separate geometry files for all attached machines automatically.

Use an ordinary CP turn for the first recording. There is no need to force the tractor into a drawbar
collision or hold it against a joint stop. The recorder does not operate the machine for you.

All shortcuts are listed as **Capture:** actions in the game's Controls settings and can be rebound.
Shortcuts are optional; all operations are available from the menu. Console alternatives:
`vgcPanel`, `vgcNext`, `vgcClass`, `vgcLabel`, `vgcCapture`, `vgcRecord`.

## Files

Files are written below the game's user profile:

`modSettings/VehicleGeometryCapture/`

Each `.json` is one machine, selected configuration and labelled state. File names include model,
identity hash, state label, timestamp and a collision-checked suffix. Captures are never overwritten.
The identity excludes the tractor/implement pairing. Positions and directions use the machine's
own root node as reference, with metres and radians. Root axes are not assumed to match AI direction.

Each `.jsonl` contains a header, time-stamped movement samples and a final status record. Starting
a recording also writes independent geometry files for every participating machine. Instance IDs
distinguish identical machines. Parent references describe the observed test only; they do not turn
the independent machine profiles into permanent combination profiles.

Recording samples at up to 10 Hz, flushes every 50 samples, and stops on vehicle exit/change,
attachment/joint change, write failure, map closure or ten minutes. Real elapsed times are retained;
it does not invent samples when the game runs slowly. A missing final record indicates interruption.

The regular FS25 `log.txt` only receives confirmations and errors. Share the geometry files and the
movement `.jsonl`, including the associated profiles, for bench calibration.

## What is captured

- Model, configurations and manual steering/implement category.
- Declared dimensions, individual component poses and component joints.
- Input couplings, output hitches, active coupling and declared rotation limits/scales.
- AI direction/steering nodes, implement steering axle and wheel geometry/steering information.
- AI markers and every declared work area, without collapsing a diagonal plough to one rectangle.
- Lift/work-position/turned-on state where exposed, fold/plough animation position and steering mode.
- Articulation pivot, declared articulation limits and current articulation.
- GIANTS implement turning-radius inputs and optional current GIANTS/CP radius observations.
- During recording: world poses, relative headings, wheels, work markers, work areas and state.
- When CP is driving: strategy state, waypoint, active planning radius and its available work-start/
  work-end reference nodes, for comparing front-edge crossings against lift/lower timing.

Missing/unavailable values are JSON `null`; absent data is not replaced with guessed dimensions.
Declared body size is not a collision mesh. Work-area nodes describe geometry; they do not prove
that soil or crop was being processed at a given instant. Labels do not operate hydraulics.

## CP's turning restriction

The production `AIUtil.getTurningRadius` takes the maximum of the tractor requirement and the
attached implements' requirements, respecting CP configuration overrides. GIANTS `getMaxToolRadius`
uses the effective pivot, wheel positions, hitch/component rotation limits, joint scaling and
implement steering axles. In particular it uses the active tractor hitch's limits when the implement
pivot is an input coupling. The capture retains both sides of that interface, so other compatible
tractor/implement pairings can later be calculated without a dedicated stored route for each pair.

The current CP/GIANTS radius is stored in `observedAttachmentContext`, not as an intrinsic implement
radius: GIANTS can include limits from other attached tools. Observed maximum articulation is also
not automatically a safe angle. Collision clearance, dynamics and any additional margin still need
validation. No new path planner or automatic bench-profile conversion is installed by this mod.

References checked against the FS25 documentation:
- [GIANTS AIVehicleUtil](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=91&class=881&version=script)
- [GIANTS ArticulatedAxis](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=78&class=627&version=script)
- [GIANTS AIImplement](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=78&class=621&version=script)
- Working-tree `scripts/ai/util/AIUtil.lua`, `scripts/ai/util/WorkWidthUtil.lua`.

## Build and test

From the project root, using the bench's existing Python/Lupa environment:

```powershell
./out/turnbench-venv/Scripts/python.exe -m unittest discover -s tools/geometrycapture -p "test_*.py" -v
./out/turnbench-venv/Scripts/python.exe tools/geometrycapture/build.py
```

The reproducible ZIP includes only the capture scripts, descriptor, this guide and the existing
Courseplay icon. The build writes source/archive hashes beside it. No game files are installed or
modified. This initial diagnostic is single-player only.
