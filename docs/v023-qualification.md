# v0.23: first-row exit and initial preparation

Title: **CoursePlay - Envelope Turns Test v0.23**. Mod version **8.1.0.123**.
Filename: `FS25_Courseplay_EnvelopeTurnsTest.zip`.

## Live evidence

The 16 September 08:49–08:50 v0.22 run entered work at 08:50:30.547 with
0.053 m edge error and 0.24 degrees of implement error. Its two raised local
corrections took 0.40 and 0.47 seconds. These changed the approach to the same
original row; the log does not show the course selecting different working rows.
Initial GIANTS preparation still ran before the envelope starter took control,
and the subsequent working-side offset change altered the alignment target.

At that entry handover the tractor had already reached the end marker of the
3.09 m row, so the preserved turn started immediately. CP was still in its
one-cycle lowering state. Its normal plough-side offset code therefore reported
`working: false` and omitted the twice-current-offset correction. The implement
then continued working until its rear marker crossed the exit, raised normally,
and centred for approximately seven seconds. Planning stopped at 08:50:48.887
on the one-second budget. It had not lost the generated next row.

## Corrections

- Mark the immediate short-row turn while constructing its context so CP uses
  its ordinary plough-side offset. Clear the mark immediately afterwards; do
  not skip the lowering state or alter headland-corner offset behaviour.
- Defer the initial `prepareForFieldWork` event for supported envelope plough
  entries. The envelope guard sends it once, only after validating a path and
  reaching its final straight. Wait stationary for physical unfolding and
  rotation permission before sending the working-side turnover command.
- For a raised row-to-row reversal, validate arrival of the tractor on the
  deployment straight rather than demanding that folded soil markers satisfy
  working alignment. Retain the normally settled candidate when it fits;
  after a boundary rejection, try compact bulbs with zero/left/right steering
  leads before exhausting the longer search. Initial same-direction recoveries retain their
  existing stronger settling target. Neither stage authorises lowering: the
  deployed geometry still undergoes a separate prediction and live entry check.
- Transform all footprint samples using shared sine/cosine values per pose.
  Use numeric clearance-grid keys instead of constructing a string at every
  point. Preserve all samples, polygon checks, joint limits and the reserve.
- Try a balanced local correction first when the tractor is already aligned;
  retain the established asymmetric priority when it is still pointing across
  the row. Preserve the stronger margin for previously marginal cached entries.

The one-second stopped calculation budget and 0.1 m / two-degree live working
limits are unchanged. Physical animations remain outside the calculation budget.

## Verification scope

**96 regression tests and all 30 packaged execution cases pass.** The 245
packaged Lua files match the tested source. Qualified archive SHA-256:
`a537b6860a9eafe5aa861055f8f16178865fae03cd5bd663345462f7ca57bd08`.
Local transcripts: `out/v023-regressions.txt` and `out/v023-build.txt`.

The new first-exit fixture starts from the measured 08:50:47 pose, pivot/axle
dimensions, centred markers, width and turning radius. Its target applies the
omitted CP offset, inferred from the logged target and saved next-row coordinate.
The field uses the same conservative outer-headland-centreline proxy as v0.22.
Three cases vary the later working offset by 0 and ±0.5 m, and must continue
eight metres into the next working row after turnover, lowering and CP handover.

The subsequent working transform uses the earlier measured geometry/frame change
as a **synthetic assumption**: v0.22 stopped before that turnover, so its actual
next-side geometry is not recorded. Exploratory tests with different assumed
rotation transforms did not all succeed. These tests therefore establish the
recorded start-to-entry replay under the stated assumptions, not universal
physical success for every hydraulic transform or attachment.

Additional regressions exercise the actual fieldwork preparation call site,
deferred preparation/rotation permission, the short-row offset state and exact
equivalence of the optimised footprint transform. The existing packaged cases
cover initial entries, signed pikes, response/steering/braking variation and
working handover. The qualification report beside the ZIP identifies the exact
archive checksum and every execution result; a failed case blocks packaging.

This is still an offline planar model, not GIANTS collision/terrain execution.
The physical preparation sequence, next-side geometry and subsequent turns need
the first v0.23 in-game run. The desktop bench remains on its separate branch.
