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
| `scripts/ai/util/VehicleRouteConflict.lua` | Oriented whole-rig occupancy along a live connector. Reuses captured rig poses/articulation from `FieldworkBoundary`; separate bodies avoid circular header-width exclusion zones behind the combine. |
| `scripts/ai/turns/AITurn.lua` | `CourseTurn` owns turn-course PPC callbacks, including long journeys on a headland. `updatePathfinderTurnTravel` pairs speed with lookahead; distant combine transfers use `WAITING_FOR_TURN_PATH` after a failed search. |
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

An escape already driving or searching retains its original requester when another combine asks it to move.
The other combine's occupancy scan repeats the request after that escape clears. For a live PPC route,
`getConnectorClearanceRange` saves the relevant index range; a PPC course replacement freezes that range rather
than declaring the rig clear. Only measured whole-rig clearance or the requester's job ending releases it.

Request retention does not suppress a sustained physical stop on the escape itself. The proximity controller's
seven-second blocking callback enters `recoverBlockedConnectorClearance`: retain ownership, try the checked
reverse or schedule another target when reversing is unsafe. The ten-second recovery throttle survives target
replacement for the same owner; otherwise a rapid search result can restart recovery on every blocked update.

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

### Connector lookahead and local detours (2965)

`checkWorkerOnConnectingPath` scans at least 90 m of the accepted route once per second, requesting clearance from
staging rigs before reaching them. The stopping horizon is separate: at least 45 m, or three work widths. A pending
escape holds the combine on its accepted route, including frames between scans. An assigned/unavailable rig gets
a five-second grace period, then checked local recovery; it must not produce an indefinite hold outside the
proximity sensors' reach. Removing the entire rig from the corridor releases the hold on the next scan.

`getClearConnectingPathRejoinIx` clears field-worker crossings in the generated remainder without extending the
search to remote trailers; those use the live clearance scan. The detour and join keep their collision/field checks.
`isConnectingPathCombineDetour` permits the crop exception on the first local search as well as retries, only for
an identified obstructing combine after the nearby turn-priority decision. Other obstructions retain the configured
crop preference. A distant trailer must not turn a local combine detour into a duplicate whole-field search.

Build 2966 scopes physical geometry to the live unloader check. `VehicleRouteConflict` rolls captured bodies
along the remaining course in quarter-metre steps and checks oriented rectangle overlap, allowing for motion
between samples. The capture includes attached bodies, their actual heading and length offsets. Begin at the
current pose towards the end of PPC's relevant segment, not by rolling backwards to its already-passed start.
Check later segments too: a vehicle behind the combine can still obstruct an upcoming hairpin. Reuse the sweep
for all unloaders in a scan. The broader initial staging and field-worker priority checks retain their roles;
do not use their spare parking margin to stop a collision-checked live route.

Build 2967 corrects the size contract at capture: `AIUtil.getWidth/getLength` can describe the entire AI agent,
including attachments. Never assign those aggregate dimensions to every separate body. Prefer each object's
`size.width/length` and matching width/length offsets, expanded by that object's deployed AI markers. Transform
all four corners into the relevant node's frame. Aggregate dimensions remain a conservative fallback for missing
body dimensions. The normal pathfinder collision detector is unchanged.

Build 2968 captures planar heading through `CpMathUtil.getNodeDirection`, projecting the node's forward vector
onto the ground plane. Never substitute the Y component of `getWorldRotation`: equivalent Euler decompositions
can fold a 171-degree heading to 9 degrees. Hitch offsets still come from actual node transforms, so that mixture
makes an attached header jump on the first predicted step and inflates the between-sample motion allowance.
Regression engine fixtures must include folded Euler representations, not assume Euler Y is always the bearing.
The route-conflict suite checks every quadrant, curves, reversing and attachment continuity, including a clear
trailer that the old capture incorrectly reported at 0.0 m. A real header overlap must continue to hold.

`VehicleRouteConflict.findConflict` returns the earliest sample plus optional body-pair geometry for diagnostics.
Do not mutate the shared sweep while identifying obstacles. A new live hold or a change of conflicting bodies
logs node identities, predicted/parked box centres, headings, full padded dimensions and per-side sweep padding;
repeated scans of the same hold do not repeat those details. These measurements distinguish an oversized or
misoriented prediction from a real obstruction without bypassing collision checks.

Travelling combines now start with the same body-width field corridor used by the existing successful retry.
Do not reinstate header width plus an extra four metres as a hard centreline margin: a legal headland join can
be excluded, and a start outside that inflated margin switches the search to a soft boundary across the map.
Other fieldwork rigs retain their existing corridor. Crop exceptions still require another obstructing combine.
`VehicleRouteConflictTest` loads the real AI size functions and checks context creation, result acceptance and
the first live movement check together. It covers actual initial overlaps as well as harmless neighbouring rigs;
it does not simulate GIANTS physics or measure in-game pathfinder time.

Build 2969 separates **route selection** from **permission to move**. `tryStartGeneratedConnectingPath` accepts
only a long connector passing the existing field corridor and full-route field-worker checks. Trailer occupancy
is then assessed on the installed route by the physical live scan, synchronously before returning drive speed.
Do not restore the full-course staging-trailer veto here: a rig hundreds of metres away caused a 27-second wait
followed by a two-minute global search despite the existing 709 m route. Short joins, recovery routes, invalid
field corridors and other combine crossings retain checked planning. Do not omit the immediate physical scan
or inherit its old throttle when installing a route; that would create one update of unsafe movement.

`scoutUpcomingConnectingPath` runs from working waypoint changes to request parked-rig clearance before row end.
It may issue a standby clearance request but must not replace the harvesting PPC course, turn context or speed.
It stops looking through an intervening turn. A new clear generated departure clears old detour targets/timers;
the normal live scan handles approaching, braking, release and bounded recovery for an unavailable nearby unloader.

The final-waypoint callback must not finish fieldwork while `WAITING_FOR_PATHFINDER` owns a connector. PPC can
exhaust a one-point temporary course in the same update as a synchronously rejected search; retain its retry.
The replacement approach and actual fieldwork end still receive their normal callbacks. Crop-avoidance retries
use the configured setting plus the authorised combine-detour exception, rather than silently re-enabling avoidance.

`VehicleRouteConflictTest` exercises dispatch through physical braking and early clearance, including the saved
211-point connector, logged combine/trailer positions and static field outline. Its timing excludes GIANTS physics;
drawbar poses are approximations. Historical dispatch functions from pre-refactor `604246d4` and build 2968 fail
the new clear-departure regression. That comparison isolates the departure decision, not an entire historical game run.

### Distant headland turns (2964)

A long `CourseTurn` is not a fieldwork connector state: the turn owns waypoint callbacks. Its accepted pathfinder
course uses travelling lookahead in the forward middle, returning to short lookahead and configured turn speed
before tight bends, reverse sections and implement lowering. Calculated turns and chain-planned loops retain
their existing policy. Never make a shared PPC change to compensate for the wrong caller's lookahead.

Only combines' distant pathfinder turns use the new retry policy. A failed search does not enter the local
analytical generator: translating a hundreds-of-metres route to fit the departure edge caused the recorded
103.7 m reverse. Four headland hand-offs (the normal four-turning-radius range, then 20/40/60 m farther along)
are tried, followed by a free forward search to the same row target. Each failure schedules a later update;
after the five-candidate batch, wait five seconds. Synchronous solver failure must never recurse or leave one
frame of non-zero driving speed. The source row target and lowering approach are preserved on every attempt.

`PathfinderUtil.findPathForTurn` optionally preserves `turnHeadlandCourse` for clearance requests when a searched
hand-off fails. It is an intended corridor, not permission to drive the solver's unvalidated middle section.
Acceptance checks the assembled course's forward gear, field corridor and other workers/trailer occupancy.
A parked rig receives the normal clearance request; both classes of vehicle obstruction prevent acceptance.
Once clear, that rig continues yielding while the combine's distant turn searches or travels.

`CourseTurn:getRaisedHeaderTurnBoundary()` selects the existing body-width field corridor for raised-header centre
turns only. Both search and final acceptance use it: applying the cutting-width corridor only during search can
reject every approach to an otherwise acceptable row target. Headland corners and non-harvesters retain the full
working width. Obstacle collision geometry is independent of this field margin and must continue to include the
header/implements. Keep the normal straight-entry target and forward-only distant-turn rule.
`tools/straight-entry/turn-pathfinder-fixture.lua` covers the recorded failed hand-off and complete joined turn,
including smoothing, the appended lowering approach and PPC activation through the actual completion callback.

Connector retries disable crop avoidance only when the obstructing field worker is another combine. A trailer
obstruction waits for clearance instead. CP's ordinary crop avoidance remains a pathfinding cost preference,
not a guarantee that every raised-header footprint stays outside crop; field and collision checks remain active.

## Clearance goal selection and pending searches (2971)

The 28 September log records T7.300/325 waiting from 11:21:47.812 to 11:22:34.940 for a
165-waypoint clearance route. The old selector took the first valid holding point, up to 97.6 m
sideways, and used unary Lua 5.1 `math.atan` as though it accepted two coordinates. Its incorrect
arrival direction could force unnecessary turns. `getConnectorClearanceGoal` now ranks the available
positions and useful arrival headings by a Dubins length estimate, including a straight departure.
An aligned train's front and rear must fit outside the combine corridor at the target. This is a
ranking filter, not collision approval: the usual pathfinder and live whole-rig checks still own
obstacle avoidance and permission to move. Harvested targets remain preferred; existing checked
reverse recovery and emergency crop fallback remain available. Do not replace the live articulated
clearance check with the aligned endpoint estimate, or require an arbitrary parking heading again.

CR11/318 also remained in a long connector search after its staging wait expired. While that search
is active, `tryResumeGeneratedConnectingPath` rechecks the existing generated route every two seconds.
It retains the field and other-worker checks, cancels the old search before installing an accepted
route, and immediately performs the normal live trailer scan. Cancellation must precede that scan:
the scan can start a new recovery request. Local recovery and short/invalid connectors are excluded.

The same log contains two divide-by-zero errors at 11:23:58 when `setAITarget` normalised a missing
direction on a one-point hold course. Such courses now use the vehicle's forward direction. The
regressions exercise real Dubins costs at twelve rotated/mirrored departures, short versus distant
parking choices, trailer rear clearance, search cancellation/handover and missing/zero AI directions.
Build 2970 fails the new straight-departure and zero-direction tests; current source passes them.

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
| Live route footprints, header offsets, sparse curves and trailers behind/beside the departure | `VehicleRouteConflictTest.lua` |
| Long-turn steering, distant-transfer retries, forward-only acceptance and hand-off ranges | `PathfinderTurnTravelTest.lua` |
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
