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
- **Standby distance** selects a target distance of 30–80 metres behind the harvester.

Ordinary staging pauses during turns and manoeuvres and selects harvested targets within the field. A trailer
blocking a combine's connector has a separate clearance procedure: it first seeks a harvested holding point,
then permits a field-contained emergency route through crop if necessary. Collision checks still apply.
Finishing that escape does not permit crossing back into the connector before the combine finishes its approach.

## Behaviour checklist for test build 2928

This checklist and the 2924–2928 notes below record earlier development. In particular, their advancing pool
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
