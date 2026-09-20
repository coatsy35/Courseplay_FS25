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
- Unloaders beyond the active and configured standby requirements receive interruptible field-pool positions. The
  distance starts at roughly 100 metres and grows with time until demand, header width and the number of pool
  trailers. A safe position reached from an AutoDrive field access point is held rather than continually moved.
- A pooled trailer inside an approaching combine's swept path moves clear before the normal blocked-vehicle timeout.
  Fruit-protected access-point waits remain stationary until the combine passes, as configured.
- A trailer waiting ahead with fruit avoidance enabled stays at its access-point pool until the harvester passes and
  a fruit-free route behind it becomes available.
- A partly filled trailer receives the normal Courseplay distance-weighted preference, so nearby combines finish its
  load before introducing an empty trailer. Distance eventually outweighs the partial load, and soft combine
  reservations do not prevent another combine making that choice.

Demands are ordered by predicted time until the trailer is needed. Combines use the measured harvest rate, their
normal call percentage and, while unloading, the active trailer's predicted time to full. Forage harvesters use the
active trailer's measured fill rate, with a larger safety margin because they have no holding tank. Existing
assignments receive a temporary score advantage to prevent repeated target changes.

Coordinator pathfinding, reverse-clearance courses and live steering targets are constrained to the detected field
polygon. Courseplay stops at the last safe position when no contained route exists; leaving the field remains the
AutoDrive handover. A tractor handed over just outside an access point may only drive inwards.
After unloading, the tractor reverses by a distance derived from header width and both vehicle lengths. Fieldwork
traffic also applies the same physical turn envelope when trail-based convoy distance is unreliable during turns or
the drive back to a work-start waypoint. A combine waiting in a pocket or pull-back holds until the unloader reaches
that clearance position and deregisters, subject to the existing five-second minimum pause.
Following-combine turn clearance scales at twice the wider header plus half of both vehicle lengths and a ten-metre
margin, with a 50-metre minimum and a further 30-metre slowdown band. This gives approximately 50 metres stopped
clearance for 15-metre headers and 56 metres for 18-metre headers.

## Settings

Each combine or forage harvester has an **Unloader coordination** section:

- **Nearby standby unloader** enables one additional staged or relief unloader.
- **Standby distance** selects a target distance of 30–80 metres behind the harvester.

Staging pauses during turns and manoeuvres. Targets must be on fruit-free ground, remain inside the field polygon,
and retain collision avoidance. Reached pool and staging targets remain fixed until coverage or urgency changes.

## Validation

`scripts/test/UnloaderCoordinatorTest.lua` covers global one-to-one allocation, firm forage reservations, soft
combine staging and surplus-unloader behaviour. In-game validation should cover:

1. One combine with one and then two unloaders on a large field.
2. One forage harvester with an active and relief trailer, including a full-trailer handover.
3. Two to four mixed harvesters with fewer, equal and surplus unloaders.
4. Headland and 180-degree turns, pockets, reversing and blocked paths.
5. Joining and leaving jobs, manual **Drive now**, field unloading and multiplayer ownership.
