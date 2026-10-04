# Unloader coordination

Courseplay coordinates available combine unloaders across all active harvesters on their detected fields. The
coordinator assigns at most one standby unloader to each harvester and one harvester to each standby, preventing
independent unloaders from clustering behind the nearest machine.

For code responsibilities, state ownership and safe extension points, see the
[maintainer guide](unloader-coordinator-maintenance.md). Current behaviour below supersedes the historical build notes.

## Coverage

- A combine receives one soft relief reservation. The reserved trailer remains in a distant field pool until its
  journey time and the predicted call time say it must start moving, then stages at a stable harvested waypoint.
- A forage harvester receives firm relief coverage. Its standby cannot be called by another harvester while the
  reservation remains valid.
- A real unload call promotes the assigned standby and uses the existing rendezvous and unloading behaviour.
- Starting a worker at or above its call setting dispatches against the combine's current position, without waiting
  for a passed waypoint or harvest-rate history. An overdue call cannot use an unknown end-of-course prediction.
- A combine at or beyond its configured call percentage replaces an en-route trailer when another eligible trailer
  can arrive at least ten seconds sooner. During an active route search, the improvement must also exceed a quarter
  of the assigned trailer's travel estimate, avoiding repeated cancellation for small gains. If the assigned trailer has remained stopped for ten seconds, the
  replacement also releases it onto a reverse escape course using normal CP proximity control.
- Unloaders beyond the active and configured standby requirements receive interruptible field-pool reservations.
  A `POOL` assignment holds the trailer where it is; a calculated pool waypoint does not authorise a journey.
  Promotion to `STANDBY`, an accepted unload call or a genuine obstruction can require movement.
- A pooled trailer inside an approaching combine's swept path moves clear before the normal blocked-vehicle timeout.
  Fruit-protected access-point waits remain stationary until the combine passes, as configured.
- A trailer waiting ahead with fruit avoidance enabled stays at its access-point pool until the harvester passes and
  a fruit-free route behind it becomes available.
- Initial calls and replacements use the same arrival score. A partial load offsets up to the 25-second local travel allowance,
  so nearby combines finish its load without preferring a distant trailer. Failed approaches have a 15-second
  cooldown; abandoned pathfinders are cancelled and obsolete callbacks cannot affect a new assignment.

Demands are ordered by predicted time until harvesting loses trailer coverage, then tank fill and predicted time until
the trailer is needed. An uncovered combine competes against the relief deadline of an already covered combine, not
that covered combine's still-full tank. This retains priority after several pass their normal call percentages. Combines use
the measured harvest rate, their normal call percentage and, while unloading, the active trailer's predicted time to
full. Forage harvesters use the active trailer's measured fill rate, with a larger safety margin because they have no
holding tank. Existing assignments receive a temporary score advantage to prevent repeated target changes. A real
combine call may take a soft reservation only when its predicted downtime is within the safety margin of the reserved
combine.

The nearest suitable trailer becomes the stable combine lead; a nearby partly filled trailer may win when its arrival
time is within ten seconds of the nearest option. Before the configured call percentage, it only advances in
deliberate staging moves to harvested positions and parks between moves. It does not actively follow the combine.
At the configured percentage, Courseplay promotes that parked lead and starts its unloading approach. Rear pool
trailers stay parked while the active grain trailer owns the nearby working corridor. Relief predictions help plan
the next reservation; they do not permit a second grain trailer to enter that occupied corridor. Future staging
points account for predicted travel along the course but must already be harvested. Departure timing allows for
closing the gap to a moving harvester. Failed staging is retried and does not count as arrival.

Nearby grain combines share a serving trailer only when its serving area and the game's fill-type compatibility
check permit it. This does not allow mixed loads. Compatibility and free space have different purposes: a full
compatible rig still protects its corridor while reversing clear. After release, actual calls require compatible
free capacity and obey the configured departure threshold, so a suitable partial trailer can serve the next combine
or a replacement can take over. Forager relief remains separate.

The configured call percentage governs normal harvesting calls. A combine already waiting for unloading, including
a finished row or course below that percentage, can always request a trailer. A queued departure can yield to a
materially quicker eligible trailer. A trailer at its configured departure fill threshold cannot accept a new call.

Disabling moving unload on the first headland prevents only alongside unloading. The normal call still promotes the
lead trailer, which follows behind at the configured distance until the combine reaches its pocket. A route being
calculated is not treated as a blockage, so Courseplay cannot repeatedly swap trailers and cancel their pathfinders.
While the combine reverses to create a pocket, the trailer remains clear and cannot copy the temporary reverse
course. It follows forward at the standby gap while the combine cuts into the pocket. Once the combine stops, the
trailer builds a fresh forward pipe approach without applying moving-unload alignment rules.
An already staged and aligned lead joins the pocket-follow course directly. A completed pocket uses the pipe approach
immediately, even if it becomes ready while a departure was queued.
The optional final alignment extension is clipped at the field boundary instead of invalidating an otherwise valid
route. At a shared field entry, subsequent active calls also queue until the departing trailer clears the combined
train and turning envelope. Calls remain assigned while queued. A nearby forward approach joins the appropriate
moving or stopped unload course without a needless global pathfinding loop.

Unloader pathfinding prefers the detected field polygon, adding a route cost outside its corridor. Analytic
shortcuts cannot bypass that preference. The polygon is not an absolute containment rule: a usable approach near
an edge is allowed, and completed routes and live driving are not cancelled by a separate boundary rollout.
The boundary recovery state machine has been removed. Normal CP collision and proximity controls remain active.
A failed exact approach falls back to a harvested point behind the combine without stopping the AI worker;
the failed-call cooldown prevents an immediate unrelated pool journey. When a full trailer reports that AutoDrive can
take control, Courseplay releases it at its current safe position so AutoDrive can join the surrounding road network
directly. The older return-to-start fallback uses the same field preference and ordinary collision checks.
After unloading, the tractor reverses by a distance derived from header width and both vehicle lengths. Fieldwork
traffic also applies the same physical turn envelope when trail-based convoy distance is unreliable during turns or
the drive back to a work-start waypoint. A combine waiting in a pocket or pull-back holds until the unloader reaches
that clearance position, subject to the existing five-second minimum pause. A separate clearance record survives
call release and AutoDrive takeover. A shortened reverse route does not reduce the required clearance.
Following-combine turn clearance scales at twice the wider header plus half of both vehicle lengths and a ten-metre
margin, with a 50-metre minimum and a further 30-metre slowdown band. This gives approximately 50 metres stopped
clearance for 15-metre headers and 56 metres for 18-metre headers.
A lead combine retains its established convoy priority throughout a corner. A following combine approaching the same
turn cannot reverse that order merely because it enters its own turn state; it stops outside the full physical turn
clearance until the lead has cleared the corner. The lead ignores the follower's stale trail position, preventing
mutual-yield deadlocks. Physical turn clearance also applies to machines using different course names; their course
trails are not used to infer convoy order. Simultaneous turns without an established order use a stable vehicle order.

After the last active worker on the served field stops, a trailer that has completed an unload and reversed clear
can deliver its remaining partial load from idle or standby. Fresh jobs, empty trailers, active calls and unfinished
obstruction clearance do not trigger that final-load departure.

## Settings

Each combine or forage harvester has an **Unloader coordination** section:

- **Nearby standby unloader** enables one additional staged or relief unloader.
- **Standby distance** selects a target distance of 30â€“80 metres behind the harvester.

Ordinary staging pauses during turns and manoeuvres and selects harvested targets within the field. A trailer
blocking a combine's connector has a separate clearance procedure: it first seeks a harvested holding point,
then permits a field-contained emergency route through crop if necessary. Collision checks still apply.
Finishing that escape does not permit crossing back into the connector before the combine finishes its approach.

## Behaviour checklist for test build 2928

This checklist and the 2924â€“2928 notes below record earlier development. In particular, their advancing pool
positions and capacity-based sharing rules have been superseded by the current coverage rules above.

| Requirement | Automated coverage | In-game acceptance |
| --- | --- | --- |
| Lead waits, then approaches by the configured call percentage | Moving-gap estimate, parked lead, 65%, 80% and 95% startup calls with zero harvest history | Observe one lead entering and parking before each configured threshold; start a loaded save above the setting |
| Rear trailers enter and park clear | Stable pool targets, progressive demand, four combines/five trailers | Check separate entry points and parked rigs on the harvested strip |
| Finish nearby partial loads; share trailers across combines | Partial-load arrival score, uncovered-machine priority, caller-specific fruit wait | One partial trailer serves two nearby combines without a loop |
| Pocket and first-headland unloading | Actual call dispatcher, ready-pocket promotion, reverse hold and forward approach | Lead waits clear while the pocket is cut, then unloads promptly |
| Forager relief | Firm reservations, measured trailer fill and capacity | Full trailer clears and relief takes the pipe with minimal interruption |
| Safe turns and recovery | Header-derived clearances, convoy order, blocked-call recovery | Wide headers clear corners and pocket returns without contacting following vehicles |
| Field boundary preference and AD handover | Outside-field route cost, accepted-route retention, preserved collision checks | Prefer in-field travel without repeated route cancellation; verify AD joins its network |
| Stable calls and routes | Waiting-lead priority independent of caller order, departure queue, nearer replacement, stale callbacks and long searches | Full lead receives the nearest suitable trailer; spare trailers wait clear |

These checks exercise the real Lua decision functions with engine stubs. They do not simulate GIANTS vehicle physics,
fruit maps, collision shapes or AutoDrive. Live-game acceptance remains necessary.

The 2925 log showed successful approach searches rejected by the added boundary rollout, followed by call release,
pool reassignment and repeated recovery searches. Build 2926 removes that veto as requested. Spares already parked
on harvested ground within their pool distance remain there rather than looping backwards to a more distant target.
Actual calls consider uncovered waiting harvesters before accepting a follower's request; known convoy order gives
the lead priority. Build 2927 further restricts nearby followers to sharing a serviceable active trailer; distant harvesters do
not monopolise nearby trailers.

Build 2924's captured run exposed two regressions: a worker starting at 90.5% with no fill history targeted waypoint
2434 instead of its current position, and the shared search loop applied detailed trailer constraints to coarse grid
successors. The new regression cases fail against 2924 and pass against 2925. Grid goal, successor and smoothing
checks now consistently use coarse validity; detailed driving searches retain footprint checks. Future moving
interceptions are capped by predicted tank capacity and checked again for headland/pocket restrictions.

## Further validation

The focused Lua regressions cover allocation, capacity, direct approaches, callback cancellation, failed staging,
departure queues, clearance ownership, boundary footprints, update dispatch and independent-course turn clearance.
Packaging and translation checks run before each build. These are engine-stub regressions, not an in-game simulation.
In-game validation should cover:

1. One combine with one and then two unloaders on a large field.
2. One forage harvester with an active and relief trailer, including a full-trailer handover.
3. Two to five mixed harvesters with fewer, equal and surplus unloaders.
4. Headland and 180-degree turns, pockets, reversing and blocked paths.
5. Joining and leaving jobs, manual **Drive now**, field unloading and multiplayer ownership.

## Build 2927: shared combine service

Nearby combines share the active trailer when compatible space remains after its current tank and a harvest
allowance. The short post-unload clearance reverse retains that coverage. Distant combines, insufficient capacity
and blocked rigs permit another trailer. Nearby partial loads take precedence over empty trailers, including when
an empty standby reservation already exists. Forager relief remains separate.

Combine relief stays in the rear pool while an active rig occupies the pipe, with clearance derived from work width,
urgency and queue position (at least the existing 100-metre pool baseline). It does not enter close standby early.
Relief prediction uses remaining capacity and harvested crop rate, not the much faster pipe transfer rate.

The 2926 log showed separate active trailers for both nearby combines and a third promoted into close standby as
pipe discharge accelerated the fill-rate estimate. New regression cases cover shared service, distant and capacity
exceptions, post-unload clearance, blocked rigs and rear relief positioning. In-game validation is still required.

## Build 2928: shared call and verified clearance

The 2927 saved log showed T7.300/322 called for CR11/319 at 10:09:40 and T7.300/324 called
for nearby CR11/318 at 10:10:25. The shared-coverage check used the active trailer's
estimated travel time to the second combine, so it failed while the rig was still
travelling to the first. Nearby combines now share that active rig while it has capacity
after the current tank and harvest allowance. A blocked rig, a full rig, and separated
combines allow independent coverage.

The same log shows T7.300/322 completing its 34.1-metre reverse course at 10:12:28,
while CR11/319 continued waiting for physical clearance. Reverse-course completion now
measures the rig's distance to the combine. It extends the reverse when needed and
holds the combine if clearance cannot yet be achieved. A trailer finishing an ordinary
moving-combine unload also reverses clear before rejoining the pool. A rig already parked
clear of every active harvester retains its position instead of driving farther back to
an arbitrary pool waypoint. These paths have focused Lua regressions; live-game physics
still needs acceptance testing.

## Build 2962: complete branch review

See [the branch review](unloader-coordinator-review.md) for the comparison base, reviewed areas, six corrected
lifecycle/coordination defects, refactoring, release checks and remaining in-game validation. This supersedes
the older capacity-based sharing descriptions above: an active compatible trailer retains corridor ownership
through full-trailer reverse clearance; capacity governs the replacement after it releases.

## Build 2963: maintainability

1. Split fleet rebalancing into candidate selection, reserved/pool assignment creation and complete-plan publication.
   Candidate order, scoring, timing and driver callback order are preserved.
2. Share the standby-to-active call transition and the existing departure-clearance calculation between their callers.
3. Document reservation, active-call and physical-clearance lifetimes, callback generations and connector handover
   beside the code; add a [maintainer guide](unloader-coordinator-maintenance.md) and correct outdated behaviour notes.
4. Add regression coverage for driver callbacks seeing the complete fleet plan, including an ongoing clearance.

This is a refactor with no intended driving behaviour change from build 2962. The same release gate checks source
and packaged code. Results from the ongoing 2962 in-game test remain relevant.

## Build 2964: headland travel and trailer priority

1. Give accepted long pathfinder turns travelling lookahead. Tight bends and row-entry/lowering sections retain
   precise steering and the configured turn speed. Calculated turns and chain-planned loops are unchanged.
2. Replace the failed distant-combine-turn analytical fallback with scheduled forward-only route retries to the
   original row start. The captured 2962 failure had generated a 103.7 m reverse followed by another long reverse.
3. Request parked-trailer clearance even when a searched headland hand-off fails. Refuse occupied assembled routes
   and keep the trailer yielding until the combine completes its distant turn.
4. Remove the automatic crop-avoidance override for trailer and unrelated connector failures. Only an identified
   obstructing combine authorises that override; normal crop avoidance remains CP's cost preference.
5. Add regressions for synchronous failure/braking, timed retries, original row targets, rejected routes, steering
   transitions, trailer clearance and the crop exception. Includes the 2963 maintainability changes above.

The source and packaged-runtime release checks must pass before publication. Steering behaviour, alternative
headland joins and trailer clearance still require the matching in-game run.

## Build 2965: earlier trailer clearance and shorter connector searches

The 2964 log records 34.3 seconds between CR11/319 starting its connector search and accepting a route
(19:58:39.934 to 19:59:14.260 on 27 September). A remote trailer extended the first search to a much later
rejoin; the resulting route was rejected and searched again after a five-second pause. Later, T7.300/325's
clearance was replaced by a request from the other combine, then incorrectly ended when the requesting
combine changed its PPC course. Its next 20 m reverse took 24.4 seconds; commanded speed was not logged.

1. Scout 90 m along an accepted connector for the complete tractor/trailer rig. Ask an idle rig to clear early;
   hold the combine within its braking horizon (at least 45 m) while the rig carries out its accepted escape.
2. Preserve an unfinished escape when another combine requests clearance. A combine changing its course no
   longer counts as physical clearance; measure the whole rig against the last relevant corridor.
3. Keep the combine's accepted route while its trailer yields. If an assigned or unavailable rig cannot accept
   clearance, allow five seconds before checked local recovery, retaining ordinary crop avoidance.
4. Keep a local combine detour local: remote trailers in the generated remainder use the advance clearance
   checks instead of extending the first search across the field. Another obstructing combine permits a crop
   detour on the first search, subject to the existing nearby turning priority, field and collision checks.
5. Add regressions for early notice, whole-trailer obstruction, between-scan braking, immediate release,
   unavailable unloaders, competing clearance requests and course replacement during an escape.

Reverse speed continues to use the CP setting and normal collision/proximity limits. Release checks cover source
and packaged code; the timing improvement and header clearance still need the same scenario tested in game.

## Build 2966: clear-route departure and blocked escape recovery

The 2965 log accepted CR11/319's route at 21:03:36.646 on 27 September, then immediately held it for T7.300/322.
At the 21:04:20 screenshot it had waited 43 seconds with no proximity obstruction reported. The added live check
still used a five-metre trailer margin and a circular header-width envelope behind the departure point. Later,
T7.300/323 stopped halfway through its clearance route facing the combine; the request-retention guard also
prevented recovery from that sustained physical blockage.

1. Check live trailer obstructions using the separate oriented footprints of the combine, header, tractor and
   attached trailers. Include offsets and the space swept on bends; remove the unrelated staging margin.
2. Start the scan at the combine's current pose on PPC's relevant segment. A trailer safely beside or behind a
   clear route causes neither a stop nor a clearance request; genuine obstacles on later bends still count.
3. Retain early clearance requests and braking for an actual obstruction. Log its identity and distance along
   the route to distinguish a request made in advance from a near obstruction requiring a stop.
4. Recover a clearance manoeuvre that proximity sensors confirm is physically blocked. Preserve harvester
   priority, use the existing checked reverse when possible, otherwise hold and search another target. Retain
   the recovery throttle across replacement target searches and never reverse towards a rear blocker.
5. Add footprint, attachment, offset, curve, sparse-waypoint and recovery lifecycle regressions to release checks.

There is no added departure timer after an accepted clear route. Reverse speed remains the CP setting. Physics,
header clearance and simultaneous traffic still require the matching in-game test.

## Build 2967: correct search margins and individual vehicle footprints

In the 27 September 2966 log, CR11/319's first search began at 21:36:23.818 and exhausted 40,000 iterations
at 21:37:24.910. Retrying the same target with vehicle-width clearance succeeded at 21:37:26.715, about 1.8 seconds
later. The accepted route then immediately reported T7.300/322 as an obstruction at 0.0 m. Code review found that
the initial field margin and the newly separated body footprints still used attachment-inclusive AI dimensions.
These size expressions predated the maintainer refactor; the refactor preserved them.

1. Begin combine connector searches with the existing body-width field corridor, avoiding the oversized first
   attempt. Keep normal vehicle/header collision checks, crop policy, route validation and other implement margins.
2. Capture each physical body once using its own dimensions and offsets, retaining deployed marker extents.
   Do not place the entire header/trailer envelope over the tractor or combine chassis.
3. Preserve lateral offsets and shifted/reversed AI nodes by transforming every box corner. Retain separate
   attachments, articulated movement, real initial overlaps and obstacles across later bends or reverse sections.
4. Replace the misleading size-function stub with production AI utilities in the regression fixture. Check the
   search context, accepted result and first movement scan together, plus real header obstruction and release.
5. Complete two independent reviews, add their missing initial-overlap and reversed-node attachment cases, and
   run the full source and packaged-runtime release gate before publishing.

The original size regression was reproduced before the correction. The tests verify decisions and geometry;
the same saved-game run is still needed to confirm actual search time, clearance and driving physics.

## Build 2968: false trailer hold at row entry

The 2967 log has CR11/318 approaching its row at 22:14:20 on 27 September, then repeatedly detecting T7.300/325
at 0.0 m and accepting another short recovery route. This leaves the combine at the row start rather than
cutting; the other combine's waiting turn is a subsequent obstruction. The screenshot shows the trailer clear.

1. Capture each body's heading from its world forward vector using the existing `CpMathUtil` helper. Euler Y
   alone is not a heading: a 171-degree bearing can be represented by X/Z = 180 degrees and Y = 9 degrees.
   Combining that folded heading with the actual hitch offsets displaced the header by 8.44 m in a predicted
   0.25 m step, inflating the swept box and creating a false zero-distance trailer obstruction.
2. Reproduce that failure using the logged combine bearing and real CR11/FD250/NC dimensions, with an approximate
   nearby-clear trailer pose. The old heading fails this regression; the correction clears it, including through
   the live movement gate. This is a geometry reproduction, not an exact replay of all game vehicle transforms.
3. Test equivalent Euler representations at 25 bearings, straight and curved forward/reverse travel, rigid header
   continuity, articulated hitch continuity, real initial header overlap and release after an obstruction clears.
   Earlier engine fixtures always returned heading as Euler Y, so they could not expose this case.
4. When a live trailer hold begins or the conflicting body pair changes, log both body indices/nodes, box centres,
   dimensions, headings, swept-motion padding and route distance. Repeated scans of the same hold do not repeat
   the geometry detail. Existing collision decisions, clearance priority and pathfinding policy remain in effect.

The full source and packaged-runtime release gate is required. In-game validation must confirm CR11/318 now
enters the clear row and the following combine can complete its turn; those physics are not simulated by the tests.

## Build 2969: start the generated connector and clear trailers before row end

The 27 September 2968 log records CR11/318 finishing its row at 23:50:58.413. The initial connector check waits
for T7.300/322, then T7.300/323 about 270 m away. At 23:51:25.340 it abandons that wait and starts a search to
the far work point: 26.927 seconds after row completion. The coarse search is still running at 23:53:26.807,
121.467 seconds later. A 211-waypoint, 709.1 m generated connector was already available throughout.

Historical comparison against pre-refactor `604246d4`, refactor commits `1430b334`/`84883707`, and build 2968
finds that the initial broad trailer wait and full-route dispatch survived the helper extraction. Replaying both
historical dispatch functions in the same regression harness reproduces the unnecessary wait. JPS and its search
constraints were not replaced by the refactor. The later live physical checks did not repair this earlier gate.

1. Select a long, field-contained generated connector before applying broad staging-trailer waits. Full-route
   field-worker crossings still require checked detours. Install the route, then immediately run the physical
   trailer scout/braking check before permitting movement; a genuine nearby obstruction still holds the combine.
   Distant trailers are handled as the combine approaches, without replacing the route with a whole-field search.
2. Request eligible standby-trailer clearance while harvesting when the connector comes within the 90 m scout
   horizon. Keep the harvesting course, turn context and speed/state unchanged; an intervening turn keeps ownership
   of its manoeuvre. Clear obsolete detour targets and retry timers when accepting a usable generated connector.
3. Prevent a temporary connector's last waypoint from completing the job during a pending search or retry.
   CR11/319's one-waypoint recovery exhausted at 23:52:21.960 after synchronous goal rejection and incorrectly
   reported WORK_FINISHED. The pending join now retains ownership; normal replacement-route and field-end callbacks work.
4. Preserve the user's crop-avoidance setting on retries. Disabling avoidance explicitly remains effective;
   with avoidance enabled, only another obstructing combine authorises the established crop-detour exception.
5. Add integrated dispatch, early harvesting-clearance, immediate header braking/release, actual combine-crossing,
   synchronous failed-recovery and callback tests. Replay the saved connector and preceding work points with the
   map's static field outline and logged rig positions. Dispatch measured about 0.44 seconds with zero pathfinder
   searches in the local harness; the nearby rig still causes a physical hold, and receives notice before row end.

The geometry fixture reconstructs drawbars and uses the static map outline because CP's detected live polygon is
not persisted. Timing is from the local Lua harness, not the game. Full source and packaged-runtime release checks
are required; actual trailer movement, collision shapes and row-entry physics still need the matching in-game run.

## Build 2970: apply the accepted turn corridor while searching

The 28 September 2969 log records CR11/319 reaching row end 1019 at 09:55:57.884. Its next row is 45.6 m away.
The searched final turn section repeatedly exhausts 10,000 iterations, beginning at 09:56:12.814, and cycles through
the five distant-turn retries. CR11/318 subsequently waits under its 75 m convoy spacing. This is a failed turn
search, separate from the initial connector/trailer hold repaired in 2969.

`CourseTurn` already accepts raised-header centre turns within the vehicle-width field corridor, but its search
still required the full cutting-width corridor. For the CR11 those margins are 1.975 m and 7.6 m respectively.
The constrained approach target leaves insufficient room under the latter rule. Changing headland joins retains
the same target and corridor, so it does not resolve the mismatch.

1. Share the existing raised-header corridor selection between turn search and acceptance. Keep full working-width
   clearance for headland corners and tractors. This does not narrow the pathfinder's physical obstacle envelope,
   which still includes attached implements, or alter the row target, forward-only travel or crop policy.
2. Exercise the actual Hybrid A* and pathfinder constraints at the logged final hand-off, including eight rotated
   and mirrored variants, blocked goals and the unchanged corner/tractor restrictions.
3. Reconstruct the exact 17-point, 53.4 m saved headland section and run the complete staged solver: departure,
   joining, smoothing, the real ending-course callback and the appended lowering approach. The corrected turn
   returns 117 searched points after 1,558 iterations, then appends the lowering approach and activates PPC;
   the complete replay takes approximately 1.8 seconds in the local harness.
   Replaying the previous dispatch method fails the same fixture.

These fixtures use the map's static field outline; CP's detected polygon is not saved. The old replay therefore
fails earlier than the live log, and the timing is not an in-game guarantee. Source and packaged-runtime checks
must pass before release. Actual terrain, collision shapes and following-worker movement still need in-game validation.

## Build 2972: resolve opposing standby traffic before it blocks a combine

The 28 September 2971 log shows T7.300/323 and /325 stopping nose-to-nose at 12:04:03, then both
holding and retrying forward-only standby searches. Later /323 barely advances on a clearance route;
by 12:14:34 it is waiting beside /325. CR11/318 reaches it at 12:15:20 (1.5 m proximity stop), and its
row-1003 turn repeatedly fails against the tractor/trailer occupying the starting space. This is a
physical traffic deadlock, not a reason to ignore that trailer in collision checking.

- Scan the next local standby approach against complete vehicle footprints while travelling. Elect
  one yielder; prioritise a rig clearing a harvester, then a parked rig, then a stable vehicle tie-break.
- Hold its partner while the yielder searches for a holding place outside the reserved passage.
  Reuse clearance goal ranking so an arbitrary final heading does not add unnecessary loops.
- If forward search fails, try a checked straight reverse, shortest first (6, 12, 20 m). Check the
  complete articulated sweep against vehicles and the field. A third rig queues; if it obstructs
  the elected reverse, swap once only when the other participant can start a verified reverse.
- Retain physical escape ownership through standby allocation changes. Release after the whole
  trailer clears, or on a real job change; stop obsolete courses before replanning. Traffic escape
  can finish using its own field context after its original harvester's job has ended.
- A worker on a distant part of a long generated combine connector no longer prevents a clear
  departure. Keep whole-route field containment and check the first 90 m against workers; the
  existing live scout, braking and local detour checks continue during travel.

The same log shows CR11/319's riverside turn finding a recovery path at 12:19:21 and returning to
fieldwork at 12:19:45. That transient recovery is separate from /318's persistent obstruction.

`UnloaderStandbyTrafficTest` exercises the real strategy callbacks, goal ranking and articulated
footprints with engine adapters. Its head-on fixture reproduces the mutual wait in build 2971.
Coverage includes third-rig recovery, assignment changes, ended jobs, complete-trailer release,
parked/harvester priority, rear obstacles and field edges. The connector regression checks both
prompt departure with a worker 300 m away and subsequent braking/local recovery when it approaches.
These tests do not simulate GIANTS terrain or vehicle physics; the same in-game routes still need validation.

## Build 2973: parked trailers, immediate reverse clearance and moving-obstacle refresh

The 28 September log shows CR11/319 searching from 14:43:24.454 until 14:44:52.995 without a route.
Its retry to the same rejoin succeeds in 1,625 ms. Both attempts already use the same body-width field
corridor and crop policy; the retry label did not describe a newly relaxed margin. The first coarse search
retains explored cells while the blocking combine moves. Refresh only that active coarse connector search
when the blocker moves at least 0.5 m, checked every two seconds. Keep the search algorithm, detailed
steering phase, goal, collision checks and accepted-route validation unchanged. This addresses stale
moving-obstacle searches; under-five-second timing still requires the actual in-game replay.

T7.300/322 starts a clearance search at 14:45:28.442, drives towards the combine and later fails reverse
recovery because an obstacle lacks `getAIDirectionNode`. Use an obstacle's root node when it has no AI
direction-node API, retaining its footprint. Clearance now uses the same physical body/header sweep as
the combine, so broad staging margins cannot move a safely parked trailer. Try checked straight reverses
of 6, 12 and 20 m before seeking a forward holding route; rear vehicles and field containment remain checked.

Predictive advance staging remains: the lead approaches as the combine fills, and successive pool trailers
can leave the AD entry for their existing progressively nearer waiting points. Only one staging departure
uses a shared entry at a time, with the reserved lead ahead of its pool; separate clusters can stage independently.
New staging departures wait near any combine turning, searching or travelling on a connector, including a previous
combine after reassignment. An existing checked staging move retains its progress. Physical obstruction clearance
and actual unloading calls remain independent.
Regression coverage includes staged departures, held/reassigned trailers, real-call acceptance, non-AI
obstacles, physical clearance and moving-blocker search refresh.

## Build 2974: no-headland clearance and checked pocket joins

The saved 28 September log shows a parked T7.300/322 blocking CR11/318's departure at 15:50:23.
No headland path was generated, so the old failed-turn callback had no course on which to request clearance.
Distant turns now check the actual body/header footprint over the first 0.5 m before starting a search.
An eligible parked rig receives the existing checked reverse-clearance request immediately. The combine
rechecks after 500 ms without consuming a headland alternative; safely adjacent rigs and active calls retain
their existing behaviour. The search algorithm and its collision constraints remain unchanged.

At 15:55:36 the same tractor switched from a searched approach onto CR11/319's pocket-follow course at
waypoint 1851. It subsequently reported 14.2 m cross-track error and stopped off course at 15:56:09.
Pocket handovers now locate a normal travelled segment at the tractor's actual position. A misaligned tractor
pathfinds to a normal harvested waypoint behind the configured standby gap before following. These joins check
the served combine as an obstacle and retain the searched endpoint without the ordinary pipe-approach extension.
An exact waypoint arrival selects the aligned following segment instead of repeatedly searching the same endpoint.
No safe segment releases the call while retaining the running job; a pocket becoming ready uses the pipe approach.

`UnloaderPocketJoinTest`, `PathfinderTurnTravelTest` and `VehicleRouteConflictTest` cover both recorded failure
paths, endpoint handovers, opposite-facing approaches and preserved ordinary pipe behaviour. Build 2974 includes
the advance-staging and clearance fixes from 2973. Game physics and under-five-second timing still require replay;
already stopped tractors need their CP jobs restarted after loading the new build.


## Build 2975: deliberate whole-rig parking and checked short approaches

Waiting positions now have an orientation and enough harvested space for the complete tractor/trailer train,
a straight run-in and a 12 m forward exit. On a harvested headland the allocator prefers parallel side bays;
within the field it can reserve straight bays on the worked row or an adjacent harvested strip. The reserved
lead is allocated first, then following pool trailers receive separate bays. Reservations include the full
alignment/exit lane, not just a distance between tractor centres. Field edges, islands, standing crop,
current vehicle footprints, imminent combine/unloader routes and physical world shapes remain obstacles.
An aligned straight lane is checked as the exact union of elongated body rectangles, avoiding repeated
quarter-metre density/shape probes during each fleet rebalance.

Advance staging still uses the existing fill prediction, deployment threshold and progressive pool layers.
A safely parked trailer retains its bay and reserved exit space; a freshly created current-position waypoint does not make it follow
the combine or repeatedly move by the offset between its root and AI direction node. Existing approaches
retain their destination, and unfinished clearance destinations are reserved before new bays are selected.
A real unloading call can interrupt staging through the existing call/ownership contract.

For short journeys, the existing Dubins solver generates a forward, cross-row or U-turn approach to the bay's
run-in. The whole articulated route and final alignment are checked before driving. Rejected short routes
use the existing pathfinder with an accurate heading at the run-in; the served combine is not ignored.
The completed search is checked again against current occupancy before driving the alignment. Arrival
requires each physical body to be within 2 m and 12 degrees of the intended pose, rather than accepting
a tractor centre within 8 m while its trailer is skewed. The actual arrival pose must also remain clear of
other vehicles, moving routes and world shapes. Failed searches/alignment request another bay.
AD entry may start outside the field only while protrusion decreases; a fully entered rig cannot leave again.

This is the first parking/manoeuvre layer. The reserved exit is a checked 12 m straight departure, not a
promise of a complete route to any future unloading point. Actual calls still plan their complete approach,
and physical obstruction clearance retains the checked reverse escapes from 2973/2974. No shared combine
search algorithm has been changed in this build. Terrain, steering physics, busy-field timing and behaviour
with the saved multiple-combine scenarios still need in-game validation.

`UnloaderParkingPlannerTest` exercises full articulated geometry, native oriented density queries, disjoint
queue lanes, current/future traffic, paused clearance, offset AI nodes, stable holds, actual Dubins straight/
cross-row/U-turn generation, strategy fallback/callback/arrival and monotonic AD field entry. Release gates
run this alongside the existing lifecycle, clearance, pocket and course-generation suites against source
and the packaged runtime.


## Build 2976: repair the parking terrain-transform call

The live 30 September log exposes a build 2975 integration error: parking shape checks call
`PathfinderUtil.setWorldPositionAndRotationOnTerrain` without its required fifth `yOffset` argument.
The helper then adds nil to terrain height, aborting unloader planning repeatedly. Supply zero at this
caller. The shared terrain helper and pathfinding algorithms retain their existing behaviour.

The regression reproduces the omitted-argument failure before the fix. Its engine adapter now requires
the complete signature, and the strategy/Dubins integration portion executes the production terrain
transform with native terrain/node adapters instead of replacing the helper. It also verifies a non-zero
height offset and heading, preventing this integration gap from being hidden by the fixture again.

The same log gives separate explanations for the two stopped combines. At 21:16:38.887 CR11/319's
next-row turn search reaches its iteration limit after repeated collision reports against map shape
117282 near the final approach to x 44.30, z -341.62. It repeats headland joins and a free search; no
field-boundary or accepted-route rejection is recorded. The exact map object's geometry/name cannot
be identified from the log alone. CR11/318 then yields to that turning combine: the log records 49.7 m
along-course separation against a 75 m convoy setting, plus 57.3 m physical separation against 54.3 m
turn clearance. The physical slowdown caps speed at about 1 km/h, which the existing controller rounds
to zero. Lowering the convoy setting alone does not remove that physical turn hold.

This build repairs the independently confirmed parking exception. It does not claim to resolve the
front combine's map-collision route failure or change the user's convoy setting/turn-clearance rules.
Those require the recorded approach geometry to be checked in game; collision detection stays enabled.


## Build 2977: restore searched reversing for harvester transfers

The earlier distant-turn protection changed two independent behaviours: it removed the unchecked
calculated fallback, and also forced every distant search and accepted course to be forward-only.
The latter overrode the vehicle's existing reversing permission and selected Dubins instead of the
original forward-ending Reeds–Shepp solver. An adjacent row with a staggered end can meet the
'distant' threshold, so the restriction also affected ordinary harvester manoeuvres.

Restore the strategy's reversing permission on every turn-search attempt and accept searched reverse
segments when that strategy permits them. The shared solver selection continues to respect that
permission, including the existing chopper-with-unloader and user/implement restrictions. Failed
distant searches still cannot use the unchecked calculated fallback. The target, field corridor,
physical collision checks, departure clearance and final worker-route checks retain their behaviour.

The real search replay of the saved CR11/319 headland-to-row geometry uses 138 iterations with the
restored permission, versus 1,368 with the forward-only restriction, including real joined-course
acceptance and the lowering approach. Rotated/reflected cases also pass; a completely obstructed
scene still rejects the route. Regression coverage retains forbidden-reverse rejection and all retry
checks. These are planar engine adapters, not a reconstruction of map shape 117282 or a guarantee
of game wall-clock timing. Replay the front combine in game to confirm its specific map approach
and the requested under-five-second response. The following combine should then lose its existing
turn-clearance hold as the front combine moves away; convoy settings have not been changed.


## Build 2978: prevent parking validation from blocking the game loop

The live build 2977 log records repeated 2.2–3.3 second stalls within a single game loop during
standby route completion. Emergency garbage collection coincides with memory spikes to 743–919 MB.
The physical rectangle checker allocated an axis array plus four axis tables for every body pair,
multiplied across every sampled parking route and each moving vehicle's sampled future route.

Keep the same four-axis separating test with scalar arguments and a conservative world-axis rejection.
The regression allocates 89.1 KiB for 100 sampled-route scans versus 4,126.6 KiB with the old checker,
with garbage collection paused. Existing rotated, articulated, header, clearance and approach geometry
regressions retain their results. No obstacle footprint or collision mask is reduced.

Short parking manoeuvres and completed parking searches now validate incrementally while the rig
remains in the stopped waiting state. All parking jobs share a 3 ms allowance per game frame, with
256 checkpoints as a second limit. A native probe can finish before the next checkpoint yields;
this is a cooperative budget, not a promise to pre-empt a native game call. Terrain/crop queries,
articulated boundary checks, world shapes, moving routes and bay reservations remain active.
The actual departure and complete parking lane retain native occupancy checks. An immutable spatial
index lets the final handover check the whole intermediate route against current physical rigs,
imminent moving routes and reserved lanes without repeating the expensive native route validation.
That final live geometry check is atomic; the frame allowance applies to the preceding incremental
work and cannot pre-empt an individual native probe or the final handover.
Real unloading calls, changed bays and cancellation discard paused work without driving stale results.
Normal pathfinding and emergency reverse clearance keep their existing dispatch.

Repeated parked-status queries check physical position and heading instead of reconstructing the
entire fleet's moving-route plan. Actual arrival, allocation and ongoing standby traffic clearance
still check occupancy. Fleet bay allocation also shares the incremental budget. The previous published reservations remain
intact until the complete replacement is checked, then publication and driver notifications are atomic.
Releases/active calls invalidate unfinished plans. Candidate poses are sorted by their existing cost and stable tie order;
full geometry is checked only until the first feasible candidate is found, preserving the selected
minimum-cost bay. Rejected routes now log the failed boundary, crop, occupancy or alignment check.

Regression coverage runs the production incremental strategy path with simulated native-probe costs,
shared frame budgeting, interruption by an active call, newly occupied departure/middle sections,
atomic fleet publication and plan invalidation. Indexed conflicts are compared against the original
linear exact test for rotated bodies across negative/positive grid cells and touching edges. All release
gates run against source and packaged runtime. Busy-field frame times and staging success still
need confirmation in game with build 2978; the log alone cannot attribute every stall to this subsystem.

### Build 2979: stopped-combine approach handover

A called tractor finishing a harvested recovery route must not jump directly from another row onto the stopped combine's pipe-side course. The final handover now checks the actual pipe corridor and retains the existing bounded forward-correction option. If neither applies, it retains the combine call and calculates a collision-checked approach to the pipe. The moving-unload tolerance alone no longer authorises a cross-row stopped approach. Rotated geometry regressions exercise the real recovery completion and alignment predicates, including an opposite-facing tractor and the existing immediate forward approach. Trailer staging, parked holds and the 2978 parking scheduler remain intact. First-centre-row combine alignment is still under investigation.

If the checked final pipe approach is still blocked, release the call once and use the existing failed-approach hold/cooldown instead of cycling back to the same harvested recovery point. Auto-aim harvesters keep their original approach; a pulled-back combine keeps its existing target further behind the header. Regression coverage includes the failed callback and call release.


### Build 2980: restore stock unloading entry and clear row-end deadlocks

The ordinary entry/alignment functions, pipe-side stopped course, moving follow course, course-copy setup and pipe/course offsets now match the checked-out upstream CP source exactly. Remove the coordinator's direct stopped-approach shortcut: an unaligned call uses the stock rear target and normal pathfinder. CP's willWaitForUnloadToFinish predicate again chooses stopped versus moving unloading; the coordinator does not override this with isWaitingForUnload. A completed coordinator harvested/pocket approach is not a pipe approach: it explicitly hands back to the normal rear search if it is outside the actual pipe lane. This preserves the single harvested recovery and bounded final-failure cooldown.

At an actual row-end turn, a fixed-pipe combine with grain remaining but no discharge or fruit processing previously left its tractor in UNLOADING_MOVING_COMBINE indefinitely. Reverse using the established clearance primitive and hold/reserve the full turn clearance until the rig clears. Continue actual discharge and row finishing; retain the original auto-aim/chopper handling and do not trigger on isAboutToTurn alone. Regression tests cover these exclusions and both choices of stopForUnload.

FS25's Luau environment has no standard coroutine library. Replace the 2978 scheduler's coroutine.create/resume/yield with explicit step jobs for fleet snapshots, sampled forecasts, native crop/shape probes, ordered bay allocation and articulated route validation. All jobs share the existing 3 ms/256-step cooperative frame allowance. Tests explicitly remove coroutine before running the production scheduler, including interrupted calls and atomic fleet publication. Keep the final whole-route live occupancy check atomic, so an obstacle entering the middle after a paused check still rejects handover.

A truly straight translation with unchanged body headings uses the union of each body's elongated rectangle instead of hundreds of sampled poses. Skewed attachments, steering and direction changes retain the complete rollout. Rotated forward/reverse tests verify that every padded sampled-body corner is covered by the compact union. On a local headless fixture of four straight moving 60 m tractor/trailer routes, snapshot median was 0.163 ms versus 11.346 ms sampled; this is not an in-game frame-time guarantee. The final atomic handover and an individual native call cannot be pre-empted by the cooperative allowance.

Evidence distinction: the supplied saved log is the complete 28 September session. It records T7.300/322 joining waypoint 1851, 14.2 m cross-track error, and an off-course stop at 15:56:09 before the later 17:02 blockage. The separate current 1 October log records T7.300/324 waiting beside turning CR11/319 with no discharge, plus repeated coroutine.create update failures. These are separate incidents/files. First-centre-row combine overshoot remains a separate unresolved issue; this build does not change shared implement entry. In-game entry, row-end reverse and busy-field performance still require validation.


### Build 2981: predictive staging and controlled field departures

The current 1 October log records standby approaches rejected for standing crop, followed by T7.300/322 travelling a long distance to CR11/319, missing the rendezvous, and the combine waiting at 99 percent. Staging now takes actual offset course positions rather than the raw shared centreline. Deliberate bay searches reject crop under the tractor and towed body during calculation, with complete articulated/native validation retained before movement; standard CP unloading entry keeps its existing policy. Transient shared pipe occupancy no longer erases the next combine's predictive deadline or lead reservation. Predicted relief may move to a checked waiting bay while the active trailer finishes. Pipe-entry/call ownership, clearance holds, physical/moving traffic and disjoint bay reservations remain enforced.

The same session records CP releasing full T7.300/325 to AD after reverse clearance at 16:26:39, followed by CR11/318 reporting it blocking the header at 16:27:00. Full trailers now retain CP control through checked legs down the actual harvested working row and around its headland to the configured access. Each leg intersects a bounded travel corridor with the field polygon and a narrow access gate. The start marker is extended along its outward heading until the complete aligned train clears the field; a recorded CP entry pose is the fallback access reference. No callback failure or AD-readiness change permits an early handover. Failed or newly occupied routes remain braked for replanning. Upcoming traffic scans and native/articulated validation share the existing cooperative frame allowance; collision warning and proximity remain enabled. AD receives control only after actual whole-train position, alignment and live occupancy are checked outside the working field.

Regression coverage includes offset lanes, retained predictive deadlines, successor staging during active unloading, crop under the towed body, headland traversal tangents, bounded row corridors, complete gate crossings, a field edge through the middle of a trailer, obstacles in the alignment tail, stale callbacks, traffic holds, and deferred/idempotent handover. The nine ordinary base CP entry/alignment functions remain identical to upstream. Build 2981 passes the full source and extracted-runtime release gates; actual staging lead time and departure behaviour require the next in-game run.


### Build 2982: departure checkpoint and parked-call deadlocks

The complete 2981 session shows T7.300/323 and /324 full but unable to plan a departure because the invented forward access extension could not leave the field. T7.300/325 reached exit checkpoint 4/7, then repeatedly searched to a point only 0.017 m away with an 11-degree heading difference. CR11/318 needed unloading while CR11/319 stopped behind it at 43% fill. Return to the configured, already validated CP marker without changing its position or demanding an outward heading. Intermediate checkpoints require position rather than a final parking heading and are consumed before another search. The final alignment run-in belongs to the travel corridor and access gate; actual whole-train alignment, crop, native obstacles and current vehicle occupancy still gate AD handover. Row and headland routes remain mandatory.

A separate reproducible coordinator fault made a parked tractor ahead of a stopped requesting combine wait for that combine to pass. Preserve this hold for speculative staging, but let a stopped/threshold/forage demand accept an ordinary CP call and use the unchanged normal approach. Firm forage reservations, capacity checks, connector clearance and active pipe ownership retain priority. The session's generic rejection message does not prove which gate rejected T7.300/322; new diagnostics report the reason, strategy state and fill level rather than calling every rejected rig busy.

Regression coverage reproduces the near-coincident checkpoint and checks inside-field and parallel access markers, normal marker offsets outside the 40 m validation range, final run-in containment, trailer alignment, final occupancy/crop rejection, preserved early parked holds and real calls from stopped or 80% combines. Full source and extracted-runtime release checks precede publishing build 2982. In-game departure and resumed unloading still require validation.


### Build 2983: shared background search scheduling and uncovered combine demand

The 3 October session has overlapping standby searches while CR11/318 enters its first centre row. The parking allocator's 3 ms cooperative allowance does not include ordinary pathfinder starts/resumes. Those controllers previously each used the default 20 ms search slice, and JPS expansions or initial analytic validation can individually overrun it. Queue only hard-crop staging/departure contexts through a shared FIFO: at most one background start or continuation runs per game frame, with a nominal 4 ms Hybrid/JPS slice. Include initial start calls, retain generation-safe cancellation/retry and rotate fairly. Ordinary combine turn/entry searches and actual unloading approaches retain their normal immediate start and defaults. Log an inclusive background advance over 16 ms at most once per controller every five seconds. A single native probe, jump or initial candidate still cannot be pre-empted; this is not a hard in-game frame-time guarantee.

At 13:04:58 CR11/319 rejects three empty standby tractors as shared-corridor/priority while T7.300/325 is travelling to CR11/318, initially 239 m away and later missing its rendezvous. Same-course proximity alone is not sufficient to cover another combine's tank. Preserve active pipe transfer and measured reverse-clearance ownership. For an en-route rig, check a minimum travel estimate to the first combine and then the caller against its remaining tank time, with the existing safety margin; a stopped requesting combine requires immediate service. When known, subtract the first tank from the compatible free capacity before treating the second as covered. An uncovered combine can use the existing call scorer and checked base CP approach to select its own available trailer. No ordinary unloading alignment or combine turn geometry is changed.

Regression tests exercise four background starts/continuations under a shared frame grant, FIFO fairness, cancellation, callback replacement and unaffected real calls. Demand tests distinguish a genuinely covered later tank from an urgent/stopped or capacity-uncovered caller, retaining transfer and reverse-clearance exclusions. The full source/extracted-runtime release checks precede publishing 2983. Actual frame time and earlier unloading arrival remain in-game validation.

The final 2983 review also preserves recorded reverse ownership when a full tractor has released its combine, projects the first tank to its arrival and reserves capacity for the caller's full tank, and tightens the lead's parked-position movement band before the call when its preparation window reaches the remaining travel/safety margin. Tests retain the wider early hold while checking advance before the configured call percentage.

## Test build 2984 - pocket staging heading

The live 2982 session reported native setRotation errors at 13:29:44 and 13:30:23 on 3 October. Offset staging points supplied angle in degrees but omitted yRot in radians, which the existing getTargetNode check requires. Staging now supplies both from the same course heading, retaining the actual lane position and forward direction. Base CP entry, pipe spacing and unloading checks are unchanged. Regression coverage exercises the real staging producer and pocket call through the native target-node adapter, at four headings, with distant, aligned nearby and opposite-facing nearby tractors. Build 2984 includes the previously released 2983 scheduling and preparation changes. In-game arrival timing and frame-rate still require validation.

## Test build 2985 - conservative exit refinement and straight resumption

The 2982 live session repeatedly rejected successful full-exit routes for tractors 324 and 325 after pathfinding. The log did not identify the failed sample; tractor 325 subsequently began a different checked route, while tractor 324 remained on leg 1. A regression reproduces a validator false positive: a physically contained edge-parallel train is rejected because the half-metre swept collision padding protrudes sideways. Validation now retries the interval at half its length, with at most six refinements per segment under the existing shared job allowance. Every accepted conservative envelope must fit within the previous raw boundary distance; the field, harvested corridor, surveyed access, crop, shapes and vehicle checks remain enforced. Exhausted boundary rejections report segment, position, raw/swept protrusion and step length. Tests cover forward/reverse edge travel, actual crossings, narrow corridor and access gates, native crop/shape/vehicle rejection and bounded incremental work. This corrects the demonstrated false positive, but does not establish that every logged route was physically valid.

During a held reverse after unloading, the tractor may stop renewing the combine hold once all its attachments clear the combine/header six-metre straight-forward envelope plus a two-metre margin. This applies only to aligned centre-row fieldwork, away from the next turn, with no discharge. It does not shorten the trailer reverse, release shared corridor ownership, alter ordinary unloading entry, or bypass pocket/pullback/next-row waits. Physical/header/attachment, rotated-heading and actual hold-renewal regressions cover the new behaviour.

The early straight-release guard additionally requires every unloader body to face within 15 degrees of the harvester working direction: opposite-facing reverse movement or a skewed trailer retains the hold. Dedicated regressions reproduce both cases.

Straight resumption also checks actual course segments covering the next six metres, not just the current bearing or turn markers. A curved work row, lateral misalignment, or insufficient known forward course retains the hold; an unmarked bend regression covers this condition.

## Test build 2986: checked exit endpoint recovery

The next live-log check still showed build 2982. Tractor 322 repeatedly failed
the first of 17 exit legs from 13:58:35 through 14:30 because the native goal
was invalid; its precise crop/boundary cause was not recorded. Tractor 325
reached its final leg at 14:14:24, but the fixed run-in point collided with a
physical shape at x=110.9, z=-338.5 and was still being retried at 14:30.
Tractor 323 continued along its checked route; this was not recovery of 322 or
325. All four trailers subsequently being full explained the lack of supply
for the waiting combine and the convoy hold behind it. There were no new Lua
errors or actual FPS samples in the inspected interval.

Departure searches now record the actual requested native endpoint rejection
as crop, rig-boundary protrusion or physical shape. An analytic-only invalid
flag, an intermediate search goal or a general failed route does not trigger
endpoint recovery. A confirmed invalid navigation checkpoint can try six
nearby poses within the original harvested corridor. The next leg retains the
original nearby route corner; the checkpoint is consumed only after arrival.
The final marker and heading never move: its default run-in can try four
shorter lengths. Each route still passes native pathfinding, standing-crop,
whole-rig swept boundary, shape, vehicle, traffic and reservation validation.
Before driving a final approach, the complete articulated simulation must
reach the marker within the same heading limits as live handover. Actual
arrival and occupancy checks remain mandatory.

Recovery requests are deferred to the next update and existing shared
background scheduler. Each round is finite; exhaustion retains CP control and
the existing five-second hold. A final alignment failure can try another
run-in, but an obstruction elsewhere on the route retains its normal hold
without cycling endpoints. No extra native probes or per-node closures were
added to goal diagnostics. Base CP unloading entry, combine call threshold,
parking ownership and reverse-pathfinding settings remain unchanged.

Regressions exercise real native trailer-crop, goal-boundary and physical-shape
rejections; scoped endpoint diagnostics; deferred finite retries and holds;
immutable navigation/marker poses; checkpoint arrival; articulated final
alignment; and shape rejection across the completed route. Whether these
alternatives clear the recorded vehicles requires the next in-game run; a
genuinely blocked access still holds safely.

The final follow-up inspection reached 14:55:10 without log replacement or
new Lua errors. Tractor 323 progressed to its final leg at 14:46:00, then
repeatedly exhausted the native search after the analytic endpoint check
failed. Its initial goal check passed; the old log cannot discriminate the
analytic scalar fruit sample, trailer footprint or boundary reason. The
departure diagnostics therefore also retain reasons from the explicit native
analytic check of the requested endpoint. A bare analytic-invalid flag without
an endpoint reason still does not cycle candidates. No analytic fruit,
collision, trailer or boundary rejection was relaxed. Regression fixtures
prove scalar analytic fruit and physical trailer-goal rejection are diagnosed
even when the first goal-shape check passes. Search elapsed time of about four
seconds in the old log is not an FPS or frame-advance measurement.


### Test build 8.1.0.2987 - stalled pipe approach recovery

The 3 October 2986 run recorded tractor 324 starting a clearance reverse at 15:37:46 and cancelling it 65 ms later because its existing tractor-centre separation already met the threshold. At 15:38:47 it entered moving unload for combine 319; the combine stopped full on-field at 15:38:55, but no discharge or recovery followed through 15:46.

Rendezvous route completion now checks the unchanged native CP entry predicate before entering the copied working course. A fixed-pipe follower serving a combine in the exact WAITING_FOR_UNLOAD_ON_FIELD state retries after five seconds without movement or grain transfer. It retains its call, reverses with native proximity control, holds the combine, then forces the existing checked rear pipe approach. Two failed rear approaches are bounded: clear before releasing for another eligible trailer. Discharge, actual approach movement, processing, pipe unfolding, turns, pockets and auto-aim harvesters are protected.

Reverse completion now requires initial reverse travel and whole-rig physical clearance, including the header and every attachment; existing radial separation alone cannot cancel the new reverse. Clearance ownership survives release and expires physically after the rig leaves. Straight-row early harvester resumption remains unchanged.

The nine native unloading entry and offset functions, combine fieldwork strategy and pathfinder scheduling are unchanged from 2986. Regression coverage includes timeout/progress guards, bounded retries, reverse ownership and proximity braking, premature endpoint entry, forced final alignment and trailer/header occupancy. In-game validation of the reported articulated approach remains required. This build does not claim to resolve the separate slow pre-positioning search.


### Test build 8.1.0.2988 - arrive at the configured unloading level

The coordinator had suppressed CP's predictive active call below callUnloaderPercent, then forced a call as soon as that level was reached. That made the configured arrival level a departure trigger. In the 2986 run, tractor 324 was still roughly 270 m away at its 15:35:33 call and missed two rendezvous before reaching combine 319 during its 97% row-end turn. Long background staging searches did not excuse this dispatch gate.

Normal CP course-based prediction now triggers departure before the setting is reached. Coordinated unloaders retain a 25-second approach reserve for starting, leaving the bay, checked routing and alignment; disabling nearby standby preserves CP's five-second reserve. A nearby trailer stays parked while ample time remains. Unknown harvest-rate predictions do not create speculative active calls; already-due saved workers and stopped combines dispatch immediately. First-headland/pipe-in-crop restrictions prepare the lead behind the combine and preserve CP's pocket/turn safety rather than forcing parallel unloading in an unsafe position. Late fallback targets are rechecked against native unloading restrictions and bounded by remaining tank-full time.

Ahead-of-combine crop-protected parking now permits an actual predictive call when travel and approach consume the predicted time to the setting. The normal checked rear target remains compulsory. An en-route trailer is no longer treated as guaranteed coverage for another combine: travel-only estimates omitted the first transfer, reverse clearance and second approach. Pipe/reverse exclusivity is local and scales with the actual rig/header clearance; separated combines on the same course can prepare independent compatible leads. Existing successor preparation, partial-load preference, firm forage relief and native proximity/pathfinder checks remain intact.

Closer-trailer recovery retains the current call until its replacement accepts and still owns its call, including synchronous pathfinder failure. The replacement is registered before old deregistration, so releasing the old owner cannot cancel the accepted new rendezvous. Transfers are excluded from switching as before.

The nine native unloading entry and offset functions match both the local upstream/main and origin/main source exactly. No entry geometry, pipe spacing, parking bay manoeuvre, crop/shape rejection or pathfinder scheduling was changed. Regression coverage includes near/far travel deadlines, different settings, parked holds, unknown rates, saved starts, invalid speeds, pockets, row ends, late invalid targets, distinct current/future ETEs, ownership handover, compatible fleet shortages, successive trailers and multiple/shared/separated combines. Full source and packaged release gates run before publication. Actual arrival under live traffic still needs the next in-game run; insufficient compatible vehicles or a physically blocked approach cannot be made safe by bypassing base CP restrictions.


### Test build 8.1.0.2989 - called preparation clears another combine

The 4 October 2988 session showed CR11/319 requesting clearance from T7.300/325 at 16:18:45.573, 90 m ahead on its connector. The tractor followed CR11/318 to a pocket at 16:18:46.500, so the staging-only caller excluded it. It moved only after the proximity timeout at 16:19:04.147, clearing at 16:19:25.966.

A pocket follower or waiting rendezvous can now release preparation when another active combine has a confirmed physical header/train conflict. The existing full-rig checked reverse is tried first; obstacle-aware clearance routing remains the fallback. Release invalidates approach callbacks and deregisters the old owner before escape. The combine retains its checked connector while the trailer clears, and the trailer becomes available for a fresh normal CP approach afterwards. Active pipe approaches, grain transfers, continuous forage service, and native turn/reverse clearance remain protected. Safely parked trailers beside the real header sweep retain their calls and positions.

The end-to-end regression runs the production live scan, physical sweep, request and ownership release. It covers early warning before braking, repeated requests, retained connector holds until clearance, safe-side parking, protected transfers/forage and native approach states. Release gates and base-CP entry parity are checked before packaging. In-game clearance timing still requires validation.
