# v0.24: reject late deployment before turnover

Mod version: **8.1.0.124**. Stable archive: `FS25_Courseplay_EnvelopeTurnsTest.zip`.

## Evidence

The 16 September 09:39–09:40 v0.23 log records initial arrival at
(-156.892, -141.964), tractor heading -5.521 degrees and implement heading
35.833 degrees. The retained CP approach reached the deployment straight too
late. After turnover its target changed from x=-154.860 to -156.991, with only
12.020 metres left along the row. The 96 local candidates could not meet the
entry limit; best predicted edge error was 0.419 metres. This was a geometric
search failure, not the previous one-second timeout.

## Change

The retained-route simulation now requires the measured deployment lead to
remain when the tractor reaches the final straight. That lead already includes
implement span, pike width projection, lookahead and braking allowance. If the
route fails this check, it is replaced while raised, before turnover. A working
entry correction against folded markers is no longer used for that failure.

The recovery seed draws forwards by the larger of the turning radius and the
axle's lateral displacement implied by the hitch angle, then checks a compact
return. Existing curvature, footprint, joint and live working-entry tests still
apply. No model name, fixed headland count or extra planning timeout is added.
Actual deployed geometry is still measured and checked before lowering.

Transport preparation leaves a GIANTS-completed folded position alone, instead
of sending a further centring event. Active animations still block movement.
With transport folding disabled, existing centring behaviour is retained.
GIANTS may require a side rotation as part of its own fold animation; this change
does not override its hydraulic interlocks.

## Verification and limits

**97 regression tests and all 32 packaged execution cases pass.** The archive's
245 Lua files match the tested source. SHA-256:
`d711afbe1fdf90d29ae63e029cb27682826c7c0680167e9a69604eae1ad0da8e`.

The new case uses the logged arrival and working geometry, a reconstructed stock
approach line, the saved outer-headland centreline as a conservative field proxy,
and the earlier observed 12.3-degree deployment-frame change as a synthetic
hydraulic assumption. It reproduces failure with the v0.23 modules and reaches
eight metres of subsequent fieldwork with v0.24, including a steering-lag variant.
One nominal replay planned the raised manoeuvre in 0.30 seconds and the working
correction in 0.20 seconds, entering at 0.019 m edge error and 0.08 degrees.

These are offline planar tests, not measurements of GIANTS collision, terrain or
the new physical deployment. The first in-game v0.24 run remains necessary.
Transcripts: `out/v024-regressions.txt`, `out/v024-build.txt`.
