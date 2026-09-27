# Unloader coordinator maintainer guide

This guide covers the coordinator additions to `codex/unloader-coordinator`, including their integration into
Courseplay's existing driving strategies. Read [current behaviour](unloader-coordinator.md) first.
The [2962 branch review](unloader-coordinator-review.md) records the comparison base, corrected defects and limits
of automated verification. Build 2963 reorganises assignment planning and documents its contracts; it introduces
no intended change to allocation, speed, clearance, pathfinding or crop-handling rules.

## Where responsibilities live

Paths below are relative to the repository root. Search for the named functions rather than relying on line numbers.

| File | Responsibility and entry points |
| --- | --- |
| `scripts/ai/UnloaderCoordinator.lua` | Fleet demand, call priority, shared corridor coverage, provisional reservations and physical reverse-clearance records. Start at `rebalance`, `shouldServeHarvesterFirst`, `getSharedUnloader` and `isStillClearingHarvester`. |
| `scripts/ai/strategies/AIDriveStrategyUnloadCombine.lua` | One tractor/trailer rig: eligibility, call promotion, departure queues, standby travel, unloading, reversing, obstruction clearance and final delivery. Start at `getDriveData`, `beginCombineCall`, `setStandbyAssignment` and `startConnectorClearance`. |
| `scripts/ai/strategies/AIDriveStrategyCombineCourse.lua` | Harvesting demand, unloader registration, pockets and the return to cutting. The `WAITING_FOR_UNLOADER_TO_LEAVE` branch requires both its minimum pause and physical trailer clearance. |
| `scripts/ai/strategies/AIDriveStrategyFieldWorkCourse.lua` | Shared fieldwork connector search, blocked-route recovery and aligned row entry. Follow `startConnectingPath`, `prepareConnectingPathResult`, `startCourseToWorkStart` and `resumeFieldworkAfterTurn`. |
| `scripts/ai/FieldWorkerProximityController.lua` | Nearby worker order, turn/row-entry priority and speed limits. `getPhysicalTurnDecision` gives one consistent priority/yield decision per worker; `isWorkerClearOfRemainingCourse` checks the route still ahead. |
| `scripts/ai/PathfinderController.lua` | Shared search lifecycle, retries, cancellation and completion callbacks. It does not own trailer reservations. |
| `scripts/ai/util/FieldworkBoundary.lua` | Boundary geometry used by route and manoeuvre checks. A route preference and a hard corridor check are different constraints; inspect the caller's context. |

Keep fleet allocation in the coordinator and manoeuvre execution in the relevant strategy. Generic steering,
collision handling and search code serve other CP jobs too; scope changes there to the intended caller.

## Three ownership lifetimes

These are deliberately separate. Clearing one must not silently clear the others.

| Ownership | Created/held by | Released when |
| --- | --- | --- |
| Provisional reservation | `UnloaderCoordinator.assignments[unloader]`; mirrored by `standbyAssignment` | Rebalancing removes it, `release` promotes/releases it, or `unregister` removes the driver. |
| Accepted unload call | `combineToUnload` and the combine's active-unloader registration | `releaseCombine` invalidates callbacks and deregisters the active call. A queued departure still owns its accepted call. |
| Physical reverse clearance | `clearingUnloaders[vehicle]`, holding the harvester and required distance | The rig is measured clear, or either vehicle no longer exists. Reservation release, driver stop and AutoDrive takeover alone do not prove clearance. |

The physical record is keyed by vehicle rather than strategy so a restarted driver cannot bypass it.
Departure checks exclude that vehicle's own old record to avoid waiting on itself; other trailers and the combine
still see it. Do not replace the physical check with a timer or a reverse-course completion event.

`reserved` identifies the next trailer; `role` controls provisional staging. A reserved trailer may still have
role `POOL`. `POOL` holds in place, while `STANDBY` permits a staging approach subject to the strategy's checks.
Neither is an active unload call. `isFirm` protects forage relief against calls from a different harvester.

## Assignment planning and publication

`rebalance` runs at the existing interval unless forced. It builds a complete new plan before handing it to drivers:

1. Collect eligible unloaders and urgency-ordered demands. Existing reservations remain visible during planning.
2. `selectReservedUnloaderIndex` retains a serviceable lead or scores eligible alternatives. Strict comparisons
   keep the first candidate on equal scores. A demand covered by a shared active rig consumes no extra lead.
3. Remove the selected rig from the candidate list and build its reservation with `createReservedAssignment`.
   Removal guarantees it cannot become two harvesters' reserved trailer in the same pass.
4. `createPoolAssignment` handles remaining rigs, retaining suitable pool ownership. Reserved planning uses
   layer one; surplus planning starts at layer two. These waypoints are planning data, not movement commands.
5. `applyAssignments` retains unfinished connector-clearance assignments, calls obsolete reservations' release
   callbacks against the old map, publishes the complete new map, then notifies its drivers.

Driver callbacks may query the coordinator. Publishing one assignment at a time would expose an incomplete fleet
plan. Preserve callback order when changing allocation; `UnloaderCoordinatorTest` covers the public handover.

A demand distinguishes `secondsUntilNeeded` (call or relief prediction) from `secondsUntilDowntime` (loss of
harvesting coverage). An active trailer's relief deadline must not be replaced by the combine's still-full tank.
Grain relief prediction accounts for crop still being harvested; rapid pipe transfer alone is not harvest demand.

## Calls, compatibility and cancellation

Actual calls first pass eligibility checks, including compatible free capacity and the configured departure
threshold. `beginCombineCall` is the common standby-to-active transition for ordinary and pocket calls. It releases
the provisional reservation, advances the assignment generation, cancels the old search and sets the active owner
before departure queuing. Pocket calls validate their staging waypoint before making this transition.

`getSharedUnloader` prevents a nearby compatible grain combine from dispatching another rig into the serving
corridor. Its fill-type check delegates to the game's existing fill-unit compatibility rules; it does not permit
mixing crops. Free capacity is deliberately separate: a full compatible rig retains corridor ownership during its
reverse clearance. After release, the next actual call can reuse a suitable partial trailer or choose a replacement.
The serving-area, distance and blocked-rig checks still apply; forage relief uses its separate continuous-feed policy.

`registerCombinePathfinderListeners` protects active and standby searches with two generations:

- `combineRequestGeneration` invalidates results from a released or replaced assignment.
- `pathfinderRequestGeneration` invalidates an older search within that assignment.

The callback also checks the combine identity. A same-state replacement still needs generation protection.
`cancelStandbyPathfinding` invalidates its generation before cancelling. Preserve that ordering and use the guarded
listener registration for new unloader search paths. Search completion can synchronously trigger another search;
cleanup after the callback must not erase the new request.

## Standby, yielding and final delivery

A pool rig waits where it is unless promoted, called or genuinely obstructing another vehicle. A computed waypoint
farther back is not by itself a reason to turn round. `getUnloaderDepartureClearance` supplies the same train/turning
envelope to departure detection and immediate standby holds.

Connector obstruction has two distinct conditions:

- `connectorClearance` describes an unfinished escape. It survives removal of its standby reservation and prevents
  a new unload call until the whole rig clears the relevant route.
- `standbyYieldingToHarvester` prevents returning across that route while the combine is still in its connector
  search/approach states, even after the rig is physically clear.

`startConnectorClearance` tries harvested holding places first, then permits an emergency route through crop
within the field corridor. Ordinary staging keeps its harvested-target rules. Keep collision and route validation
on both paths; permitting crop traversal is not permission to ignore another machine.

After a completed unload and measured reverse clearance, `postUnloadClearanceHarvester` records that this rig has
served the field. `shouldDeliverFinalLoad` permits a partial delivery from idle/standby only after the previous
harvester and all other relevant workers stop. Fresh jobs, empty rigs, active calls and pending obstruction
clearance do not qualify. Do not infer field completion from one combine ending its own course.

## Combine connector and row-entry lifecycle

A connector is the temporary journey from fieldwork to the next work start. Its indices belong to different courses:

| Value | Meaning |
| --- | --- |
| `connectingPathStartIx` | Last working waypoint before the connector in `fieldWorkCourse`. |
| `activeConnectingPathCourse` | Accepted temporary approach, saved before the row starter appends its entry section. |
| `connectorRecoveryResumeIx` | Progress within that accepted temporary approach. |
| `workStarterCourse` / `connectingPathRejoinIx` | Current recovery/search target course and optional join index within it. |

`WAITING_FOR_PATHFINDER` also represents timed obstacle waits; it does not guarantee a running search coroutine.
Retry decisions must inspect the relevant timer and controller state. A temporary wait must retain its stop across
frames between obstacle scans.

A pathfinder result is not yet a successful handover to cutting. The connector result, entry section and join must
remain valid; the work-start handler then verifies alignment or requests recovery. `clearConnectingPath` belongs
only to the accepted fieldwork/turn handover. Calling it unconditionally after a last-waypoint callback can erase
recovery that the callback has just started.

Worker turn/entry priority is local and geometry-dependent. A stale trail position must not hold a follower after
the leader clears its remaining route. Conversely, a nearby leader still turning into its row needs clearance.
Inspect the aggregate minimum speed across all workers; a later non-blocking worker must not cancel an earlier hold.
Existing tests cover all 120 iteration orders for five combines, not a live physics simulation.

## Units and verification

Geometry and route distances use metres. CP speed values use the game's internal km/h convention; mph is a display
choice. Use the existing settings and conversion boundaries rather than applying a second conversion or multiplier.
Mission timestamps and retry intervals are milliseconds; ETE and demand predictions are seconds. Fill percentages
are 0–100; compatible capacity and grain tank contents are litres.

| Contract | Focused regression under `scripts/test` |
| --- | --- |
| Fleet allocation, sharing, capacity and plan publication | `UnloaderCoordinatorTest.lua` |
| Calls, generation guards, restart, release and final partial delivery | `UnloaderLifecycleTest.lua` |
| Standby obstruction, whole-rig clearance and crop fallback | `UnloaderConnectorClearanceTest.lua` |
| Connector retry, alignment recovery, callback handover and travel | `FieldworkConnectingPathTest.lua` |
| Nearby turn order, row entry and five-worker aggregation | `FieldWorkerTurnClearanceTest.lua` |
| Reverse/recovery and route constraints | `UnloaderRecoveryTest.lua`, `UnloaderGridRoutingTest.lua`, `FieldworkBoundarySegmentTest.lua` |
| Pocket planning and independent state properties | `PocketCoursePlanningTest.lua`, `CpUtilStateIsolationTest.lua` |

From the unloader branch worktree, run `py -3.14 tools/unloader-coordinator/build_test.py <build-number>`.
The gate checks source and the actual packaged runtime, including Lua 5.1 compilation, the focused suites, profile
regressions, turn/entry suites, XML and archive contents. It replaces the stable test ZIP only after every check passes.
Keep the test identity `FS25_Courseplay_UnloaderCoordinatorTest.zip` and the live mod separate.

These checks cannot establish GIANTS collision shapes, terrain, vehicle physics or AutoDrive behaviour in game.
Retain live tests for multiple combines, mixed crops on adjacent fields, wide headers, pockets, restart during
clearance, final partial delivery, forager relief and multiplayer. Behaviour changes need a regression tied to the
observed failure and a matching live test; a refactor must preserve established scenarios.
