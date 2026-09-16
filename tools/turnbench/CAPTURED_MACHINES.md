# Captured machines, 16 September 2026

Open `/captures` on the turn-bench server. This is recorded playback for
calibration and regression evidence, not prediction of a new course.

Imported 34 independent dimension snapshots (16 machine identities) and all
11 completed recordings. Seven observed combinations are selectable:

| Tractor | Working implement | Width | Rear cart | Recordings |
|---|---|---:|---|---:|
| Steiger 715 Quadtrac | Seed Hawk 84 | 25.6 m | PD 1000 | 1 |
| John Deere 9R 640 | 4905 Blue Drive | 18 m | — | 2 |
| John Deere 8RT 410 | AQUILA DRIVE 400 | 4 m | — | 2 |
| Big Roy 1080 | Avatar 12.25 SD | 12 m | — | 2 |
| T8.350 GENESIS | Citan 15001-C | 15 m | — | 2 |
| Fastrac 4220 | ESPRO 6000 RC | 6 m | — | 1 |
| 1156 | 3420-100 Paralink Hoe Drill | 30.5 m | 71300 Air Cart | 1 |

## What is reproduced

Every sample retains each machine's world pose, input coupling, steering axle,
AI markers, working-area corners and operating state. Parent instance links
preserve tractor → drill → cart. The two carts are not collapsed into the drill.
Work-area transforms use the captured three-dimensional root basis before
projection to the display plane. Declared-size body rectangles are approximate;
they are not reconstructed meshes or collision envelopes.

The catalogue retains every original geometry snapshot, optional labels and
source checksum. Recording files are converted to compact visual fixtures.
Raw recordings remain in the game folder and a separate local archive so wheel
and control observations remain available for later physics calibration.

To import another completed capture batch:

```powershell
python tools/turnbench/captured.py "C:/Users/danco/Documents/My Games/FarmingSimulator2025/modSettings/VehicleGeometryCapture"
```

The importer rejects incomplete recordings, missing parents/profiles, missing
samples and non-monotonic time. Playback includes every sample and supports
scrubbing, restart, pause and 1/4/16/64× speed.

## Gaps in capture coverage

- No lift/lower transition in these eleven runs. Nine remain raised; both 9R
  planter recordings remain lowered. Dimensions and turning motion are useful,
  but lowering delay, exit lift and entry coverage are not established.
- No cart-first chain (tractor → cart → tool), and no PW plough in this batch.
  Earlier PW logs remain separate evidence, not a complete geometry capture here.
- A mounted working implement is not established by the labels. Labels describe
  the tractor as `trailed` while the implements are generally unspecified; they
  cannot be treated as verified attachment types.
- The 9R is labelled twin-track despite being described as wheeled in the test
  request. The 8RT predates the skid label. Fastrac is labelled front-wheel-steer;
  a four-wheel-steering-mode test is not confirmed. Preserve raw labels rather
  than silently using these annotations to select physics.
- Maximum safe drawbar angles/collision meshes were not captured. Joint travel
  limits alone do not establish clearance. Neither extreme steering travel nor
  equivalent left/right raised/lowered tests is guaranteed by a short recording.
- No field boundary, intended course or actual worked-soil map accompanies these
  files. Green playback shading is a lowered-tool sweep, not proof of coverage.

## Gaps in the predictive bench

The current turn solver and desktop runtime driver model one trailer yaw state.
They do not yet execute the complete multi-trailer chain or calibrated articulated
tractor/skid-steering physics. These fixtures make those shortcomings testable;
they do not make those simulations valid automatically. Substituting one long
trailer for the cart combinations would hide the behaviour we need to test.

Next useful recordings are a straight section, left and right turns, then a
lift/turn/lower/straight-entry sequence; also the alternate cart-first chain and
one confirmed mounted implement. There is no need to repeat every dimension save.

Validation: seven importer/server tests pass; all eleven recordings loaded in
the browser. Play-to-completion and timeline scrubbing were checked, including
the 30.5 m drill/cart display. Existing unrelated UI edits are retained.
