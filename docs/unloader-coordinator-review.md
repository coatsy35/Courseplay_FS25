# Unloader coordinator branch review — build 2962

Reviewed on 27 September 2026 using Astra, with independent lead-agent integration and regression checks.

## Scope

The comparison is the complete feature-branch delta from `8b707fa907c236b9b1b98a5608267975c3c764d3`
to `604246d4`, followed by the changes in this build. That base is the branch's common ancestor with
`origin/main`; it isolates the coordinator work from the other custom features already on main.
The common ancestor with official Courseplay's `upstream/main` is `150dcd51f8a108ffc86e95df3e3e240bcc80b6df`.
The feature comparison covers 59 files, including tests, settings and translation entries.

| Area | Review coverage |
| --- | --- |
| Allocation | Shared grain trailers, lead-combine priority, compatible capacity, reservations, forage relief and separate fields |
| Unloader lifecycle | Call/release/delete, stale callbacks, departure queues, reverse clearance, standby, final loads and AutoDrive handover |
| Combine behaviour | Pocket planning, return clearance, moving/stopped unloading, call replacement and end-of-field work |
| Worker coordination | Convoy order, nearby turn/row-entry priority, moving obstacles, local detours, retry and handover state |
| Shared pathfinding | Controller cancellation/re-entrant completion, coarse versus detailed search, smoothing and boundary constraints |
| Integration | State-property isolation, turn/start-row boundary checks, settings visibility, translations, manifest loading and packaging |

This is a code and regression review. It does not establish that every possible map, implement or live-game
collision behaves correctly. Earlier screenshots inform the intended behaviour; they are not evidence that these
particular failures occurred in every reported incident.

## Confirmed issues corrected

1. **Movement between obstacle scans.** A moving-worker hold applied only on the once-per-second scan frame;
   the normal per-frame speed reset allowed movement between scans. The stop now persists until a clear scan
   or a recovery transition. A regression checks detection, an intermediate frame, release and renewed obstruction.
2. **Recovery erased at row entry.** The final-waypoint callback cleared connector state after the work-start
   handler had started an alignment recovery. Cleanup now belongs to an accepted fieldwork/corner handover.
   The callback regression covers the complete outer call and early successful entry also clears stale travel limits.
3. **Trailer waiting on itself after restart.** A physical clearance record correctly survived stopping the driver,
   but then blocked that same vehicle's next departure. Departure checks exclude only their own vehicle's record;
   the combine and other trailers still see the physical clearance restriction.
4. **Deleted combine strategy called during reverse.** Stopping a combine during a held reverse could leave no
   drive strategy to receive `hold()`. Clearance continues and only an available strategy receives the hold.
5. **Incompatible shared coverage.** A trailer serving another crop or field suppressed suitable local calls.
   Sharing now checks the serving area and accepted fill type. Compatibility is deliberately independent of
   remaining capacity: a full compatible rig retains corridor ownership until it has reversed clear and released.
6. **Parked final partial load never delivered.** Completion handling previously required an assigned combine.
   A trailer that has already served and cleared the field now also delivers from idle/standby when no worker
   remains. Empty trailers, fresh jobs, active calls and pending obstruction clearance are excluded.

## Refactor

- One turn-priority decision supplies both yield and priority results; each speed check updates a worker's
  reservation once.
- Connector context creation, retry waiting, search dispatch, suffix/join validation and successful cleanup
  have explicit shared helpers.
- The test builder validates source and packaged runtime before replacing the installable ZIP. A failed check
  leaves the previous ZIP available.

No speed multiplier or new reverse-distance adjustment is introduced. CP's configured reverse speed,
the existing shortened post-unload clearance, crop fallback and collision checks remain in effect.

## Release checks and remaining validation

The build gate runs Python catalogue/packaging tests; Lua 5.1 compilation; ten coordinator, lifecycle, connector,
boundary, pocket and state-isolation suites against both source and ZIP; implement-profile regressions;
and headland-loop, pocket-turn, straight-entry and multi-pivot tests against the extracted ZIP.
ZIP integrity, XML parsing, runtime-file scope and source-byte identity are checked before publication.

The proximity regression now exercises all 120 vehicle iteration orders for five combines, including local
row-entry hold/release with distant waiting workers. This verifies aggregation, not live five-combine physics.

In game, validate the previous crossing/row-entry case, stop/restart during clearance, a full-trailer handover,
mixed crops on adjacent fields and the last partial load after all combines finish. Also retain the existing
forage-harvester and multiplayer checks; neither has been exercised in the game during this review.
