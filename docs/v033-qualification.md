# v0.33 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.133`.

## Live failure

The monitored v0.32 T7.300/PW100 run stopped at 23:01:01 on 16 September,
turning from waypoint 269 to 270. The monitor was paused immediately on detection,
and the complete log preserved at `out/v032-live-failure.log`.

The raised planner selected an 11.67 m deployment lead in 1.60 seconds. After
turnover, the tractor was at (-280.162, -165.065), heading 0.722 degrees, with
the working implement at -11.376 degrees. The work-start target was
(-280.128, -156.450). The local approach exhausted 96 trials with best predicted
edge error 0.680 m. This was a working-position alignment failure, not another
slow outer-turn search or a centimetre-level boundary rejection.

An offline replay of that working snapshot still failed after removing the
96-trial limit (4,140 candidates). Expanding turn catalogues, intermediate
straight lengths and a stock Hybrid A* prototype did not produce a verified
solution. Those exploratory changes are not in the shipped runtime.

## Change

Remember the measured geometry and deployment heading change separately for
each working side, checking object identity and width before reuse. Before a
later folded turn, preview the working correction at the compact arrival distance,
including one tracking lookahead for stopping/settling. The candidate staging
lines are the current row and offsets derived from the deployed work-marker
imbalance; there are no tractor/plough names or fixed metre offsets.

A verified preview can select a lateral raised-arrival offset. The ordinary
folded planner must still verify the entire turn. The real course work-start node
is unchanged. After unfolding, the live working geometry is measured again and
the actual approach must pass the existing alignment, joint and boundary checks.
The remembered state is a planning aid, not permission to lower. With no usable
remembered side, normal planning remains available. No initial calibration cycle
or fixed travel-speed cap is introduced. Preview trackers are cleaned up on
cancellation.

## Replay and limits

`configureV032Exit` contains the logged folded/working dimensions and pivots,
detected polygon, saved CP speeds (20/27 km/h), and measured steering response.
It seeds the remembered working-side model from the recorded working geometry.
The animation heading change is reconstructed as 9.5 degrees from the nearby
folded/working observations; this is not a frame-exact animation replay or proof
that every earlier cached state was identical. Additional qualification uses
0.5 s synthetic steering lag. Both cases must deploy once, resume fieldwork,
retain the original working-row position and travel at least 8 m in work.

Terrain, tyres, animation and passive-trailer physics remain approximations.
In-game confirmation is required. The installed game ZIP was not modified,
and monitoring will not resume without another user request.

Results are in `out/v033-regressions.txt`, `out/v033-package.txt` and the
qualification JSON beside the delivered ZIP.

All 104 regression tests and 50 packaged driving cases passed. Two final
targeted checks also passed for preview cancellation, equipment identity and
protecting the deployment transform from later steering corrections. ZIP
integrity, all packaged Lua/source pairs and stock transport-start parity
were verified.

ZIP SHA-256: `c8d487bdb4ba4a4516774b9d6bc74cd9d221fd01a0750fcaa79371aafd2ac62a`.
