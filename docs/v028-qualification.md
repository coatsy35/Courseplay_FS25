# v0.28 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.128`.

## Evidence and changes

The preserved v0.27 log contains 14 successful working entries, then a stopped
search timeout at 15:33:05, waypoints 135 -> 136. Three seconds elapsed without a
result; this did not establish that no feasible path existed.

- Removed the elapsed-time rejection. Searches remain finite and time-sliced;
  exhaustion, invalid geometry and physical-animation failures still stop safely.
- Keep a validated existing route, then compare shorter stock-Dubins alternatives
  with independently varied outgoing distance, incoming distance, lateral bias,
  and radius, retaining the full deployment reserve. Rank by full route length.
  Reject longer routes and nominal paths outside the field before full simulation.
  This permits asymmetric connections and retains the established double loop.
- Continue speculative preparation during the centring animation. Only a shape
  hint survives: the actual stationary, raised geometry is validated again.
- Restore stock CP K-turn eligibility for supported combinations. A small adapter
  retains the stock manoeuvre and delegates the final entry to the common guard.
  It stops before measurement and restores the strategy's pursuit listeners.
- CP field, turn and reverse speeds remain in charge. No new fixed travel speeds,
  relaxed clearance rules or per-machine configuration exceptions were added.

## Validation

- All 109 regression tests pass, including Lua 5.1 syntax checks.
- All 48 packaged execution cases pass using the exact packaged Lua.
- Each packaged case reaches handover and at least 8 m of fieldwork.
- The latest recorded exit passes with default CP speeds and steering lag.
- All four long/narrow angled-field cases pass.
- ZIP integrity and every packaged Lua/source comparison pass.

ZIP SHA-256: `ad514a5804ed0d4f8efcb9d4942d7f6f54d3d9eb49f366fef42a9e4d70607423`.

The latest recorded geometry previously selected a 200 m route. The initial
short-route comparison selected 129 m (36% less), including the same continuation
into the row. The final packaged replay and timings are recorded in the adjacent
qualification JSON. This is shortest-first selection from a bounded catalogue,
not a claim of globally optimal travel time or arbitrary-shape planning.

Synthetic long-field cases use a 140 m wide parallelogram with a 1 km working
length and ends at -60, -25, +25 and +60 degrees. These execute entry and at least
8 m of subsequent fieldwork; they do not simulate harvesting an entire field.
The user does not need to find a map with that shape for these checks.

## Limits

Tests execute production Lua with planar tractor/trailer dynamics, not GIANTS
terrain, tyres or joint physics. The latest raised snapshot is recorded; its
later working shape and hydraulic movement use the preceding measured PW proxy.
The recorded-field boundary is a conservative outer-headland centreline proxy.
The synthetic field cases are explicitly constructed geometry.

K-turn tests cover stationary final-entry transfer, no premature lowering and
subsequent fieldwork. They do not replace in-game validation of stock reversing.
Articulated/multiple-trailer combinations retain the existing stock fallback.
Initial working-offset measurement remains a follow-up; the initial debug lines
can still shift when the working offset becomes known.
