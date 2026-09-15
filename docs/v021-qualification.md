# v0.21 qualification: offline checks passed

Test title: **CoursePlay - Envelope Turns Test v0.21**. Numeric mod version:
**8.1.0.121**. Filename: `FS25_Courseplay_EnvelopeTurnsTest.zip`.

## Changes and observed results

The v0.20 deployment target did not reserve the distance consumed by PPC
lookahead and braking. A rig which straightened at a different rate could
therefore deploy too near the working boundary to make the necessary steering
correction. The target now includes one measured lookahead distance plus the
stopping distance at the existing 8 km/h approach cap and conservative 1 m/s²
deceleration. This is an upstream deployment allowance, not a prescribed straight
run: the subsequent measured working-envelope correction may be curved.

The trailer-response estimate previously required eight half-metre samples.
It can now use three samples only if every sample agrees within 2% of their
median. The longer window retains its existing robust dispersion check. Physical
axle/pivot/work-marker geometry is unchanged, and noisy early samples are rejected.

The bounded local search now interleaves pairs of pull-in tangents with straight
lengths. Previously the 96-trial budget could expire before trying a shorter
run-in. This fixed a steep-pike regression exposed during this change, without
increasing the budget or relaxing working admission.

| Previously failing response | Initial loop candidates | First local correction | Tracking correction | Outcome |
| --- | ---: | ---: | ---: | --- |
| 10.4 m, right / left | 11 / 12 | 7 / 7 | 16 / 15 | Both enter and work 8 m |
| 11.6 m, right / left | 11 / 12 | 4 / 4 | 1 / 1 | Both enter and work 8 m |

Both cases turn the plough over once and lower once through the turn handler.
The response lengths above are independent synthetic dynamics parameters, not
new machine dimensions or XML overrides. CP's ordinary fieldwork handover can
also issue its normal lowering command. No second recovery loop is permitted.

## Verification

- 81 existing regression checks pass, plus two new tests covering the formerly
  failing responses in both directions and rejection of noisy early estimates:
  **83 distinct regression checks**.
- **22 of 22 execution cases pass using the packaged experimental modules**.
  Every one of the 245 packaged Lua sources matches the tested working tree.
- Execution covers both turn directions, 30/60 Hz and variable frame intervals,
  braking variation, steering lag up to one second, faster/slower trailer
  response, positive/negative pikes up to 41.5°, and 5 cm marker shifts during
  lowering. Regression coverage also includes mounted and trailed drills.
- Passing execution requires production turnover/entry/handover logic and
  continued alignment for eight metres of fieldwork, not merely a found path.
- The package gate still refuses to replace the test ZIP if any case fails or
  qualification is interrupted. Live Courseplay and implement-directory builds
  remain separate.

The adjacent ZIP `.qualification.json` contains per-case transitions, the
archive checksum, candidate counts and results. Test transcripts are retained
locally in `out/v021-regressions.txt`, `out/v021-added-tests.txt` and
`out/v021-package-audit.txt`.

## Limits

This qualifies v0.21 for another in-game test; it does not establish that all
GIANTS combinations work. The replay uses recorded PW geometry and the recorded
CP offset change, but synthetic field geometry, planar vehicle physics and a
synthetic deployment transform. Terrain, drawbar collisions, hydraulic motion,
and every live automatic-offset update are not reproduced. Low-level actuation
and unrelated game services remain mocked. The separate desktop bench has not
been updated or represented as runtime parity by this change.
