# Captured vehicle library

18 machines, 40 state-specific geometry profiles and 8 combinations, imported from the geometry capture mod on 16 September 2026. The 12 recordings are retained losslessly as gzip JSONL.

This is a reusable data library, not a claim that the current planar simulator supports every machine. No game mod was changed.

## Machines

| Machine | Profiles |
| --- | ---: |
| 3420-100 Paralink Hoe Drill | 1 |
| 71300 Air Cart | 1 |
| PD 1000 | 1 |
| AQUILA DRIVE 400 | 2 |
| Avatar 12.25 SD | 2 |
| Big Roy 1080 | 4 |
| Citan 15001-C | 2 |
| ESPRO 6000 RC | 1 |
| Fastrac 4220 | 2 |
| 4905 Blue Drive | 2 |
| PW 100 - 12 | 1 |
| Steiger 715 Quadtrac | 3 |
| 8RT 410 | 3 |
| 9R 640 | 4 |
| T7.300 | 5 |
| T8.350 GENESIS | 3 |
| Seed Hawk 84 | 1 |
| 1156 | 2 |

## Observed combinations

| Combination | Recordings |
| --- | ---: |
| 1156 + 3420-100 Paralink Hoe Drill + 71300 Air Cart | 1 |
| 8RT 410 + AQUILA DRIVE 400 | 2 |
| 9R 640 + 4905 Blue Drive | 2 |
| Big Roy 1080 + Avatar 12.25 SD | 2 |
| Fastrac 4220 + ESPRO 6000 RC | 1 |
| Steiger 715 Quadtrac + Seed Hawk 84 + PD 1000 | 1 |
| T7.300 + PW 100 - 12 | 1 |
| T8.350 GENESIS + Citan 15001-C | 2 |

## Use

From `tools/turnbench`:

```python
from captured_geometry import load_vehicle, load_combination, read_json, LIBRARY

t7 = load_vehicle("t7_3a9ea847")
pw = load_vehicle("pw10012_7c87ec16")
catalogue = read_json(LIBRARY / "catalogue.json")
pair = next(c for c in catalogue["combinations"] if "PW 100" in c["name"])
combination = load_combination(pair["id"])
```

`load_vehicle` defaults to the latest snapshot. Pass a catalogue profile path to select another state. `load_combination` uses the exact profiles referenced by its recording, not each vehicle's latest unrelated snapshot. Members retain instance IDs, parent IDs and attachment-joint indices; the initial sample supplies world poses and relative attachment transforms.

Dimensions, components, joint poses and limits, couplings, steering, wheel geometry, work areas, markers and physical states are retained verbatim. Positions remain in the documented machine-root frame; use direction vectors when transforming them. No declared box is substituted for an actual collision scan.

The latest T7/PW combination uses the 21:14:57 profiles. The PW internal yaw pivot is component joint 2, joining components 2 and 3, with a declared 90-degree yaw limit. The tractor coupling has zero yaw scale. These remain separate joints.

## Known gaps

- Collision envelopes and safe drawbar clearance were not measured by the capture mod.
- Field polygons and terrain dynamics are absent; this library does not reproduce the v0.29 live turn failure.
- Only observed physical states are available. Do not infer a folded shape from an unfolded snapshot.
- Optional labels are preserved as annotations, including unspecified or conflicting values. The 8RT steering annotation says `not-applicable`; it must not be treated as evidence of front-wheel steering.
- Some implement AI direction frames are absent. Preserve their root, wheel and component frames until a validated simulator adapter is available.
- Articulated and multi-trailer combinations retain their full graphs; they must not be flattened into the current single-passive-trailer model.

Re-import additional captures with `python captured_geometry.py <capture-folder>`. Source files are never deleted. SHA-256 checks protect profile and decompressed recording content.
