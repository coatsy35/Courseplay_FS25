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
- A combine at or beyond its configured call percentage replaces an en-route trailer when another eligible trailer
  can arrive at least ten seconds sooner. If the assigned trailer has remained stopped for ten seconds, the
  replacement also releases it onto a boundary-contained reverse escape course.
- Unloaders beyond the active and configured standby requirements receive interruptible field-pool positions. Each
  trailer enters the field and parks in a separate rear layer. When predicted demand advances materially, the next
  trailer may move to a nearer course-derived layer and park again. Pool distance accounts for time until demand,
  header width and the number of waiting trailers.
- A pooled trailer inside an approaching combine's swept path moves clear before the normal blocked-vehicle timeout.
  Fruit-protected access-point waits remain stationary until the combine passes, as configured.
- A trailer waiting ahead with fruit avoidance enabled stays at its access-point pool until the harvester passes and
  a fruit-free route behind it becomes available.
- Initial calls and replacements use the same arrival score. A partial load offsets at most ten seconds of travel,
  so nearby combines finish its load without preferring a distant trailer. Failed approaches have a 15-second
  cooldown; abandoned pathfinders are cancelled and obsolete callbacks cannot affect a new assignment.

Demands are ordered by predicted time until harvesting stops, then tank fill and predicted time until the trailer is
needed. This retains priority between combines after several have passed their normal call percentages. Combines use
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
free capacity is already smaller than the crop in the combine's tank. Future staging points account for predicted
travel along the course but must already be harvested; an obsolete en-route lead target can be refreshed in bounded
steps. Failed staging is retried and does not count as arrival.

Disabling moving unload on the first headland prevents only alongside unloading. The normal call still promotes the
lead trailer, which follows behind at the configured distance until the combine reaches its pocket. A route being
calculated is not treated as a blockage, so Courseplay cannot repeatedly swap trailers and cancel their pathfinders.
While the combine reverses to create a pocket, the trailer remains clear and cannot copy the temporary reverse
course. It follows forward at the standby gap while the combine cuts into the pocket. Once the combine stops, the
trailer builds a fresh forward pipe approach without applying moving-unload alignment rules.
The optional final alignment extension is clipped at the field boundary instead of invalidating an otherwise valid
route. At a shared field entry, subsequent active calls also queue until the departing trailer clears the combined
train and turning envelope. Calls remain assigned while queued. A nearby forward approach joins the appropriate
moving or stopped unload course without a needless global pathfinding loop.

Coordinator pathfinding, reverse-clearance courses and live steering targets are constrained to the detected field
polygon. Pathfinding checks oriented tractor/trailer footprints and their swept segments; completed courses and live
steering also check attached bodies. Active combine approaches use the actual polygon with footprint checks rather
than a circular inset. A rejected live movement schedules an in-field recovery route instead of an indefinite stop.
A failed exact approach falls back to a
harvested point behind the combine without stopping the AI worker. When a full trailer reports that AutoDrive can
take control, Courseplay releases it at its current safe position so AutoDrive can join the surrounding road network
directly. The older return-to-start fallback is also constrained to the complete rig's field corridor; if no
contained route exists, Courseplay hands over at the last safe position. A tractor handed over just outside an
access point may only drive inwards.
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

## Validation

The focused Lua regressions cover allocation, capacity, direct approaches, callback cancellation, failed staging,
departure queues, clearance ownership, boundary footprints, update dispatch and independent-course turn clearance.
Packaging and translation checks run before each build. These are engine-stub regressions, not an in-game simulation.
In-game validation should cover:

1. One combine with one and then two unloaders on a large field.
2. One forage harvester with an active and relief trailer, including a full-trailer handover.
3. Two to four mixed harvesters with fewer, equal and surplus unloaders.
4. Headland and 180-degree turns, pockets, reversing and blocked paths.
5. Joining and leaving jobs, manual **Drive now**, field unloading and multiplayer ownership.
