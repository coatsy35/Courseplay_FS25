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

The new feature may reserve compatible idle trailers, arrange straight queues
on harvested ground or headlands, and reposition queued trailers nearer as a
combine fills. Separate distant combines need separate lead coverage. Prepare
a successor before the serving trailer departs when more capacity is needed.

Preparation must use the combine's existing unload setting as its arrival
deadline. Allow time for travel, path calculation and the native rear approach.
Preparatory parking is not permission to unload or follow the combine.

Native CP owns crop checks, pocket creation, combine turns and work entry,
unload calls, rear entry, pipe offsets, alignment, unloading, reversing clear
and departure. Acceptance of a native unload call ends queue control of that
tractor. Rejected calls cannot bypass a crop check or create a second approach
state machine. Queue management resumes only after native CP releases control.

The feature must not change shared pathfinding, collision masks, fruit limits,
combine holds or manoeuvres. Idle queue clearance must retain ordinary CP
proximity and crop protection. Any genuine need to change native behaviour is
a separate proposal, with evidence, outside this feature.

## Implementation order

1. Establish and qualify the clean main baseline.
2. Define explicit idle queue ownership and native CP handover, initially with
   coordination disabled by default. Add reservations before movement.
3. Add harvested straight-line and headland parking, and bounded, deliberate
   repositioning. Do not continuously follow a moving combine.
4. Add deadline-based preparation and successor coverage without replacing
   native CP's unloading decisions.
5. Qualify full sequences against the baseline and run controlled in-game
   acceptance before describing the feature as working.

## Required acceptance coverage

Use real decision and strategy code, mocking only the engine boundaries needed
to control time, vehicle positions, field geometry and crop density. Compare
native decisions with coordination disabled and enabled. Component tests alone
are not evidence of successful unloading.

- Unload settings at 50%, 80% and 95%; fast fill, unknown rates and loaded saves.
- Crop on either side and both sides; rejected pockets; first headland settings.
- Full previous row, row-end waiting, reversing, turning and the next centre row.
- Multiple nearby and distant combines, mixed fill types, full and partial rigs.
- Failed or delayed searches, moving obstacles, replacement and stale callbacks.
- Safe parking, queued obstruction clearance and correct rear-entry handover.
- Successor preparation, native reverse clearance and AutoDrive departure.
- Bounded search and retry work; diagnostics distinguish search cost from FPS.

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
