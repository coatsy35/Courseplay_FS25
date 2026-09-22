# Unloader coordination

Courseplay coordinates available combine unloaders across all active harvesters on their detected fields. The
coordinator assigns at most one standby unloader to each harvester and one harvester to each standby, preventing
independent unloaders from clustering behind the nearest machine.

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
- Unloaders beyond the active and configured standby requirements receive interruptible field-pool positions. Each
  trailer enters the field and parks in a separate rear layer. When predicted demand advances materially, the next
  trailer may move to a nearer course-derived layer and park again. Pool distance accounts for time until demand,
  header width and the number of waiting trailers.
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
trailers stay parked until the active lead's measured fill rate predicts that it will need relief, or its compatible
free capacity is already smaller than the crop in the combine's tank. Relief prediction also accounts for ongoing
harvest consuming the capacity left after that tank. Future staging points account for predicted travel along the
course but must already be harvested. Departure timing allows for closing the gap to a moving harvester. A parked
lead remains still when its predicted need is distant. Failed staging is retried and does not count as arrival.

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

## Settings

Each combine or forage harvester has an **Unloader coordination** section:

- **Nearby standby unloader** enables one additional staged or relief unloader.
- **Standby distance** selects a target distance of 30–80 metres behind the harvester.

Staging pauses during turns and manoeuvres. Targets must be on fruit-free ground, remain inside the field polygon,
and retain collision avoidance. Reached pool and staging targets remain fixed until coverage or urgency changes.

## Behaviour checklist for test build 2928

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
3. Two to four mixed harvesters with fewer, equal and surplus unloaders.
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
