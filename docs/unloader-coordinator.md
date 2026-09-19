# Unloader coordination

Courseplay coordinates available combine unloaders across all active harvesters on their detected fields. The
coordinator assigns at most one standby unloader to each harvester and one harvester to each standby, preventing
independent unloaders from clustering behind the nearest machine.

## Coverage

- A combine receives soft staging coverage. Its standby drives towards an already travelled waypoint behind the
  combine and remains available for a more urgent real unload call.
- A forage harvester receives firm relief coverage. Its standby cannot be called by another harvester while the
  reservation remains valid.
- A real unload call promotes the assigned standby and uses the existing rendezvous and unloading behaviour.
- Unloaders beyond the active and configured standby requirements receive interruptible shared-pool positions,
  distributed progressively further back along the harvesters' already worked routes.

Demands are ordered by predicted time until the trailer is needed. Combines use the measured harvest rate, their
normal call percentage and, while unloading, the active trailer's predicted time to full. Forage harvesters use the
active trailer's measured fill rate, with a safety margin because they have no holding tank. Existing assignments
receive a temporary score advantage to prevent repeated target changes.

## Settings

Each combine or forage harvester has an **Unloader coordination** section:

- **Nearby standby unloader** enables one additional staged or relief unloader.
- **Standby distance** selects a target distance of 30–80 metres behind the harvester.

Staging pauses during turns and manoeuvres. The target must be on fruit-free ground, and the normal field pathfinder
retains fruit avoidance, collision avoidance and field-boundary constraints.

## Validation

`scripts/test/UnloaderCoordinatorTest.lua` covers global one-to-one allocation, firm forage reservations, soft
combine staging and surplus-unloader behaviour. In-game validation should cover:

1. One combine with one and then two unloaders on a large field.
2. One forage harvester with an active and relief trailer, including a full-trailer handover.
3. Two to four mixed harvesters with fewer, equal and surplus unloaders.
4. Headland and 180-degree turns, pockets, reversing and blocked paths.
5. Joining and leaving jobs, manual **Drive now**, field unloading and multiplayer ownership.
