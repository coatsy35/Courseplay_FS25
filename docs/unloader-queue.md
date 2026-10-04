# Unloader queue restart

The former implementation is preserved on
`codex/archive-unloader-coordinator-2026-10-04`, commit `4ffccfab`.
Its checkout and numbered builds through 8.1.0.2989 remain available.

`codex/unloader-queue` starts from main commit
`8b707fa907c236b9b1b98a5608267975c3c764d3`. No former coordinator runtime,
settings, strategy changes or pathfinder changes are carried into this branch.
Build 8.1.0.2990 is a **main baseline**, without the queue feature. Its only
runtime differences from main are the packaged test title and version.

## Scope contract

All available CP trailers must leave the AD start/return area, including its
turning space, for straight queues on harvested ground or suitable headlands.
Departures are ordered so tractors do not all attempt the same gap together.
Lead trailers follow the harvested route with a lag and progressively close
as a combine fills. Separate distant combines need separate lead coverage.
Prepare a successor before the serving trailer departs when more capacity is
needed. Unassigned trailers remain in the queue further back.

Preparation must use the combine's existing unload setting as its arrival
deadline. Allow time for travel, path calculation and the native rear approach.
Native CP already calls ahead using estimated arrival time. Preparation must
precede that call, leaving room for CP's native rear approach. The configured
fill level is an arrival target, not the point to begin travelling. Lagged
preparation is allowed; starting native pipe-following without a call is not.

Prefer topping up compatible part-loaded trailers when they can arrive in
time. A trailer currently receiving grain may reserve one specific nearby
combine if its expected remaining capacity and finish/clear/travel/approach
time cover that combine's demand. Do not dispatch a duplicate while this
reservation remains feasible. Revalidate transfer progress, capacity, distance
and deadline; a distant combine must receive another trailer. A reservation
does not confer native ownership of two combines.

Native CP owns crop checks, pocket creation, combine turns and work entry,
unload calls, rear entry, pipe offsets, alignment, unloading, reversing clear
and departure. Acceptance of a native unload call ends queue control of that
tractor. Rejected calls cannot bypass a crop check or create a second approach
state machine. Queue management resumes only after native CP releases control.

Combines have priority over every CP-controlled trailer operation. Clearance
must consider the entire attached train. Compare safe forward, lateral and
reverse options by time to clear the combine's corridor; head-on encounters
must not automatically choose reverse. Resume or replan the interrupted task
only after clearance, with exactly one controller owning the tractor.

Do not change shared pathfinding, collision masks, crop limits or combine
manoeuvres. Queue routes require their own strict crop, field/island and full
rig checks. Native CP's existing crop/readiness exceptions remain exactly as
main; the queue may neither add exceptions nor reinterpret a rejected pocket.

This mod does not control AutoDrive. CP must retain ownership while the loaded
trailer travels back along the harvested centre-row corridor, clear of crop,
to a safe headland handover area. Avoid vehicles throughout this exit. A short
safe detour is allowed; a diagonal shortcut across the field is not.

Only hand over when the whole attached train has reached the harvested
headland and a suitable AD connection is available. That connection may be
the field's configured start/return point or a valid connected perimeter
route. Mere proximity to an arbitrary AD node is insufficient. Do not inject,
pause or replace AD tasks or control the vehicle after handover.

**Authorised departure exception to native parity:** current CP can finish
immediately when the return marker is missing or its return path fails. Both
fallbacks must be intercepted by the operational feature: retain CP ownership,
retry a safe row/headland exit, or wait safely with a clear reason. A timeout,
failed search, removed marker or missing AD network never grants permission to
hand over in the middle of the field. This exception does not change native
crop protection, combine turns, unloading entry or pipe alignment.

## Implementation order

1. Establish and qualify the clean main baseline.
2. Define explicit idle queue ownership and native CP handover, initially with
   coordination disabled by default. Add reservations before movement.
3. Add harvested straight-line and headland parking, followed by deliberate
   lagged preparation with hysteresis and bounded route work.
4. Add deadline-based preparation and successor coverage without replacing
   native CP's unloading decisions.
5. Add whole-train priority clearance and the CP-owned row-to-headland exit,
   including safe retention of control when an exit search fails.
6. Qualify full sequences against the baseline and run controlled in-game
   acceptance before describing the feature as working.

## Required acceptance coverage

Use real decision and strategy code, mocking only the engine boundaries needed
to control time, vehicle positions, field geometry and crop density. Compare
native decisions with coordination disabled and enabled. Component tests alone
are not evidence of successful unloading.

- Every actual CP unload setting (60–90%, step 5), every trailer departure
  setting (40–100%, step 5), fast fill, unknown rates and 95–100% loaded saves.
- Crop on either side and both sides; rejected pockets; first headland settings.
- Full previous row, row-end waiting, reversing, turning and the next centre row.
- Multiple nearby and distant combines, mixed fill types, full and partial rigs.
- Failed or delayed searches, moving obstacles, replacement and stale callbacks.
- Safe parking, queued obstruction clearance and correct rear-entry handover.
- Successor preparation, native reverse clearance and AutoDrive departure.
- Full trailer midway along a centre row; whole-train headland arrival; missing
  return marker; failed/cancelled exit search; blocked headland; crop beside
  the row; disconnected perimeter route; absent AD network; stale arrival
  callback. Assert CP retains ownership until the safe handover conditions hold.
- Bounded search and retry work; diagnostics distinguish search cost from FPS.

## Qualification status

The first implementation increment provides pure reservation and clearance
geometry components and executable tests. They are **not connected to vehicle
control** or loaded by modDesc yet. It is not an operational queue release.
All existing main runtime files remain byte-for-byte unchanged. This prevents
component-test success from being mistaken for a working in-game feature.

`tools/unloader-queue/test_policy.py` executes the actual policy with fresh
snapshots, deterministic fleet permutations, 1,000 generated cases, a measured
transfer sequence and fault injection. Mutation checks deliberately break
partial-trailer priority, deadline rejection, idle ownership and single-future
reservation; the behavioural assertions must catch each mutation.

`test_geometry.py` covers rotated/mirrored footprints, concave field crossings,
contained islands, full-train clearance, re-entry into a protected corridor,
and forward versus reverse time to clear. Supplied route-validity flags are
explicit inputs; these tests do not establish engine crop or collision safety.

`test_native_contract.py` executes real native readiness, entry, call and
departure methods with engine boundary mocks. It checks the native 25 m call
admission and rear target, crop/turn rejection, existing native exceptions,
reverse-clearance ownership and start-marker/AD/GIANTS handover boundaries.
The two tests named `baseline_gap` deliberately record native missing-marker
and failed-return-path behaviour. They document the authorised departure
changes still needed; they are not operational acceptance tests. Geometry
tests require the entire train inside a clear headland before handover.

Still required before an operational queue build: engine fleet snapshots,
ownership/cancellation hooks, crop queries for growing and ripe crops, route
validation for every attachment, straight parking and lag movement, safe
priority manoeuvres, native-call integration, full harvesting simulations,
bounded-work measurements, and controlled in-game acceptance. No component
test substitutes for those checks.

Assert safe geometry and actual transfer progress, not merely state names.
Where native crop or turn restrictions prevent unloading at the configured
level, the queue must keep the trailer near the legal entry and preserve the
restriction. Report the constraint rather than forcing an unsafe approach.

## Packaging

Retain `FS25_Courseplay_UnloaderCoordinatorTest.zip` and
`CoursePlay - Unloader Coordinator Test` so existing settings and mod identity
remain stable. Never replace the live `FS25_Courseplay.zip` or the installed mod
as part of building. Keep numbered history and a receipt identifying the
source revision, baseline, feature stage and checksum.
