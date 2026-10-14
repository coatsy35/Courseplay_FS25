## Build 3036 - crop-permitted final parking with checked turn-away routes

The 14 October 3035 run reached the final unload. At 14:26:34 combine 319
checked its 22 m forward clearance, rejected a CANOLA density rectangle with
368 positive samples and 367 recognised cut-state samples, then finished and
folded in place. The single unrecognised sample does not establish visible
standing crop. Tractor 324 subsequently reached combine 318 but was repeatedly
blocked by parked 319 at 1.4–1.5 m. Evidence is retained locally in
out/incident-3035-final-clearance/.

The user explicitly authorises crossing crop during this final parking move.
Grant that exception only to the owned clearance world of an empty,
self-propelled harvester at the original course end. Ordinary harvesting,
unloading, preparation and yielding keep their crop checks. A new load revokes
parking and returns to final unloading. Boundaries, islands, vehicle/obstacle
checks, unsupported steering exclusions and native proximity remain active.

Try the original 20–25 m straight clearance first, then forward 45/90 degree
turns in either direction at the actual turning radius, with a straight exit.
Check each mounted component, including the header, at no more than 0.5 m
corner travel between samples. Drive the same sampled points; recheck the
live curved sweep and changed implement geometry. Candidate collision checks
remain sliced to eight poses or two milliseconds per update. Existing elapsed
planning/progress limits remain safety bounds, not frame-cost measurements.

Before parking, reserve the neighbouring worker's body/header and pipe lane
using actual local unloader dimensions and configured pipe offsets, including
rear entry and native reverse clearance. Recheck the destination against live
neighbours on arrival. Missing unloading geometry cannot validate a parking
position. Wait for the assigned unloader to release before moving. If every
checked route is obstructed, stop safely and record the reason; there is no
promise of escaping a physically boxed-in position.

Regression coverage includes residual/standing crop permission, ordinary crop
rejection, revoked ownership/refill, field/island/header obstacles, blocked
straight routes with a valid turn, wide-header sampling, live curved-route
obstacles, terminal pipe/reverse access and changed neighbours. Source and
extracted-ZIP qualification also retain the 3035 milestone unloading contracts.
Engine adapters cannot validate physical steering or unattended completion;
the final move and remaining unload still need in-game testing. Keep the 3031
milestone unchanged and scheduled monitoring paused.

## Build 3035 - restore milestone unloading during ordinary harvesting

The 13 October 3034 run failed in an ordinary unloading pocket, before course
completion. Tractor 322 exhausted the added 90-second rear-entry timer at
23:17:57 while native pathfinding was still active. Tractor 325 reached the
new rear goal, then stopped when the added run-in destination check rejected
a vehicle or obstacle. Tractors 324 and 323 subsequently failed at the occupied
rear goal; 323 explicitly detected 325. All four jobs stopped within ten
seconds. The full combine then had no idle unloader and the following combine
remained under native convoy spacing. The first approach's exact admission
rejection and 325's precise obstruction are not identified by the log.
Evidence is retained in local out/incident-3034-milestone-regression/.

Build 3033 broadened the extra alignment, rear-entry and recovery rules from
end-of-course work to all stationary grain-combine waits. This was a regression
against the accepted 3031 whole-field behaviour. Require actual end-of-course
waiting for those extra rules. Ordinary pockets, full-tank waits, pulled-back
waits and next-row waits again use native admission, target offsets, loading
mode, retries and endpoint handling. They acquire no added approach timer or
moving-unload stall watcher. Native terminal path failures still report errors;
this change does not suppress them or weaken crop/collision protection.

Keep the final parking footprints, remaining-load recovery, finished-combine
release, configured departure threshold and native AD handover. Also retain
the independently evidenced resumable AD-arrival searches and yield ownership
fixes. Final recovery callbacks and speed overrides cannot impose a new
ordinary approach after the end-of-course condition disappears.

New regressions compare ordinary admission, pathfinding decisions and loading
mode with methods from the pinned 3031 milestone. They exercise the logged
12.2/-8.4 pocket target, searches lasting beyond 90 seconds, native callbacks,
endpoint admission, ordinary stationary/moving waits, unloading progress and
availability of the other three tractor jobs. The tests reject the previous
3034 runtime. Existing checked-entry tests now explicitly use an end-of-course
combine; final geometry, backup, departure and collision tests remain required.
Engine and asynchronous pathfinding interfaces are adapters, not a physical
replay of the four-vehicle incident. Source and extracted-package release
checks must pass; unattended whole-field completion and the final unload still
require in-game validation. The 3031 milestone ZIP/tag remain unchanged and
scheduled monitoring remains paused.

## Build 3034 - yield handover and recovery lifecycle audit

The retained 13 October build-3032 trace shows tractor 325 accepting queue
yield at 20:42:50 after mutual proximity stops with combine 319. Its first
whole-rig check rejected the starting footprint as a vehicle or obstacle;
the same yield persisted through 21:45 without useful progress. Tractor 324
also lost a native move-away manoeuvre to queue yield at 20:04:13, followed
by repeated start-crop rejection. These classifications do not prove physical
overlap or crop underneath the rig. Evidence is retained locally in
out/incident-3032-yield-blockage/. Build 3033's rear-entry correction did not
address this yield ownership failure.

Before taking clearance control, check the actual complete rig in every
combine state, including straight fieldwork. If the start cannot be validated,
retain native clearance and its proximity protection. Do not interrupt native
move-away, backing-up or headland-turn clearance. Retire a superseded native
search only after native control accepts the move-away; a held/no-op callback
retains its search. This prevents stale callbacks installing a different course
or reporting failure against the new state. Auger-wagon, field-unload and
GIANTS-unload modes retain their original native blocking callback.

A queue yield with failed searches and no actual movement for 15 seconds
hands clearance back to native CP. A search which cannot advance or obtain a
usable clearance envelope has a 60-second no-movement bound. Actual movement
resets the watchdog; deliberate native holds are respected. A 15-second
handover cooldown prevents immediate queue takeover. These are elapsed
recovery limits, not computation or frame-rate measurements. Native proximity,
crop controls and checked queue routes remain active; a handback does not
promise that a physically boxed-in vehicle can escape.

The wider audit found and corrects three related lifecycle faults:

- Bind frozen turn clearance to its requesting turn/context. After that turn
  ends or is replaced, use live clearance and its two-second clear interval;
  retain independent requests from other combines.
- Retain an accepted manual departure request while a checked/native reverse
  completes, even after the native one-second button flag expires. Preserve
  the intent if the target finishes, is cancelled or stops with an error.
- Bind stopped/final approach recovery to the original pathfinder controller
  and context through native obstacle-at-start reversing. Preserve checked
  rear entry, attempt counts and timeout. A finished/cancelled target retires
  its pending retry and assignment; successful completion first lets an
  already-running native reverse reach its endpoint.

Audit coverage and remaining limits:

| Interaction | Result |
| --- | --- |
| Queue yield/native clearance/search callbacks | Confirmed ownership faults fixed; no further concrete cycle found in targeted review. |
| Multiple blockers and crossing combine turns | Keep independent requests and stable priority; remove stale turn identity only. Existing order/whole-header regressions remain required. |
| Approach/reverse/combine completion | Context-bound recovery, finite attempts/timeouts and target-loss cleanup covered. |
| Reservations, replacement trailers and partial loads | No additional concrete ownership fault established; retain valid reservations and partial-load priority. |
| AD arrival/search scheduling | Retain 3033's resumable candidate work and foreground precedence; no new arrival defect established by this audit. |
| Configured cutoff, native departure and AD handover | Retain existing threshold and native departure suites; no threshold or AD setting changes. |

The bypass fixtures now provide actual single-trailer geometry and engine-boundary
crop/collision data for takeover preflight, rather than omitting those inputs.
Regression coverage also exercises native callbacks, held searches, remaining
requesters, foreground starvation, stale turns, expiring manual requests,
unrelated backup contexts and target cancellation. Full source and extracted
package release checks are required. This is a code and regression audit,
not proof that every possible multi-vehicle/map/physics deadlock is eliminated.
The next unattended field run must validate live clearance, arrival staging,
final unloading and AD departure together. Previous fixes and the unchanged
3031 milestone remain preserved. Scheduled monitoring stays paused.

## Build 3033 - stopped-combine rear entry and resumable arrival searches

The 13 October 3032 incident left CR11/318 at 99.52% with tractor 322
assigned. The native moving-unload mode persisted after the combine stopped;
the screenshot showed an angled trailer ahead of the pipe and a negative
forward-speed correction clamped to zero. The user confirms the combine had
been stopped well before the trailer physically arrived. A mode transition
in the log does not establish the time of physical arrival or alignment.

Stationary grain-combine admission now checks the complete rig's heading,
tractor lateral alignment and actual fill-node position (allowing the native
0.5 m alignment tolerance). A nearby wrong-angle rig must still replan.
Native pathfinding targets farther behind the pipe, reserving three measured
trailer steering lengths, with a 12 m minimum, for straightening. At that
point, the queue validates a complete articulated route to the rear entry,
retaining every checked sample in the driven course. Native pathfinding,
crop checks, collision/proximity controls and the combine assignment remain.
Live checks cover the whole train and a seven-metre stopping horizon. A
blocked, deviating or stalled route fails safely; no collision bypass is used.

Actual stationary waiting, including full-tank waits with stop-for-unload off,
starts the native stopped pipe approach. Once the combine resumes, an aligned
rig returns to native moving follow. A moving rendezvous which has become a
stationary wait with neither movement nor grain transfer for 12 seconds gets
up to two rear-entry replans while retaining its assignment. Existing final
reverse recovery, configured full/manual departure and native AD handover
remain in place. Forage and auto-aim service retain native admission.

Tractor 324 repeatedly discarded unfinished arrival route candidates after
50/100 ms of computation. Each arrival candidate now retains sampled edges
and its open search list across fair scheduling quanta. A rejected direct
candidate continues into obstacle search without replaying the same direct
path. Native foreground delays pause the search instead of discarding it at
20 seconds elapsed. The shared 2 ms update allowance and 1,000 ms measured
work ceiling remain; failed complete attempts still try alternative slots.
These are computation limits, not frame-rate measurements.

The manual straightening report has a separate explanation: 322's job stopped
at 19:57:26.914; 318 assigned 325 at 19:57:28.383; 322 restarted at 19:57:39.
Its 66% load was below the 85% departure threshold, but the combine was already
reserved. After 325 released, 322 was called at 19:58:23.193 and resumed grain
transfer before departing at its cutoff at 19:59:14.759. The fix does not steal
another tractor's valid reservation based solely on distance. Evidence is in
local out/incident-3032-unload-arrival/; monitoring stays paused.

Regression coverage includes physically articulated entry, fill-node overshoot,
manual alignment, close-range replan, checked course fidelity, live obstacles,
stationary/moving transitions, full/manual departure, assignment cleanup and
finite costly arrival fallback through the real scheduler. Timing is injected
in tests; engine transforms, density and collision queries are adapters.
Source and extracted-package release checks are required. Real steering,
arrival clearance and uninterrupted whole-field completion still need the
user's in-game test; retain the 3031 milestone and all previous releases.

## Build 3032 - final clearance geometry and stalled final unloading

Follow-up to the preserved 3031 whole-field milestone. The 13 October log
proved a final parking rejection and a prolonged final pipe approach, but did
not identify the crop sample or prove which body caused the obstruction.

Final parking now sweeps the combine and mounted header as separate rigid
footprints, preserving each component's position and heading. Use the chassis
dimensions and retain unfolded marker extents on mounted parts. This removes
the header-width rectangle along the entire chassis, including work markers
forwarded through the parent vehicle.
Changing component geometry restarts initial validation; live checks, native
proximity braking, field boundaries and crop protection remain in force.
Invalid or inconsistent density readings are reported separately from standing
crop, with crop name, positive/cut counts, component and sample coordinates.
Unknown readings still prevent movement.

Preserve the first native final approach. Only a stationary end-of-course
unload with grain remaining gets a watchdog: actual movement above 0.5 m or a
source-tank reduction above 1 litre resets its 12-second no-progress timer.
A stalled attempt checks a 15 m straight reverse for the complete rig before
moving, then asks native pathfinding for a longer run-in behind the pipe.
The re-approach checks the complete articulated rig before native pipe
following resumes. Searches advance in bounded slices; native proximity and
live reverse checks remain active. Keep the existing assignment throughout.

Limit recovery to two attempts with different run-in distances. An unsupported
reverse, blocked sweep, deviation, prolonged stop or timeout stops safely with
the native no-path message; there is no unchecked escape. Full/manual departure
and a combine that empties during recovery retain native completion and AD
handover. Normal harvesting, ordinary unloading and arrival preparation retain
the 3031 behaviour. Scheduled monitoring stays paused.

Regression coverage includes crop beside the chassis outside the real sweep,
cut canola, invalid readings, rotated/asymmetric and changing component poses,
real header obstructions, motion/transfer progress, complete-trailer reverse
tracking, late obstacles, bounded retries, cancellation and native departure.
Automated checks do not establish in-game acceptance: repeat the successful
course and inspect the final clearance and final load on build 3032.

## Completed milestone - whole-field harvesting in build 3031

On 13 October 2026 the user confirmed that the current release completed the
entire field and requested that it be committed, pushed and preserved as a
completed milestone. Build **8.1.0.3031** is now the baseline for subsequent fixes.

- Release commit: `03a903c11b0ae39cdf7b2bad228ed792c3df6e12`.
- Branch: `codex/unloader-queue`.
- Annotated release tag: `unloader-queue-3031-field-complete`, pointing to the
  release commit, not the later documentation commit recording this milestone.
- Preserved ZIP: `dist/unloader-coordinator/history/03a903c11b0ae39cdf7b2bad228ed792c3df6e12/FS25_Courseplay_UnloaderCoordinatorTest.zip`
  in the repository root, alongside its original `build.json` receipt.
- ZIP SHA-256: `cc51b821985100221a3f008ce22be48adecb5a1690424d6e72b2a62073611706`.

The log confirms 3031 loaded at 10:54:38. Both CR11s reached their course ends:
319 at 12:50:06 and 318 at 12:51:34. Source and extracted-package release checks
passed before publication. The milestone audit rechecked the ZIP checksum and
all 261 packaged Lua files against the release source, with no discrepancies.
This record changes no runtime code and does not rebuild or renumber the ZIP.

Final parking clearance and the remaining unload are separate, open follow-up
issues. At 12:51:31, 319's attempted 22 m clearance was rejected as `standing crop`
and it completed its job in place. The user confirms there was no crop ahead.
Tractor 323 released and reversed normally, then switched to the final pipe
approach for 318 at 12:52:01. That final unload had not completed by 13:05:53.
The rejection log lacks the crop/sample detail needed to establish its exact
cause; it must not be described as proof of actual crop ahead. Follow-up work
must preserve the successful harvesting, native release and previous fixes.

Local evidence is retained in `out/incident-3031-finish/`, including
`log-20261013-130553.txt` and `diagnosis.json`; the original release-check record
is `out/release-3031-checks.txt`. These local evidence files are not tracked.
Scheduled monitoring remains paused. Build 3020 remains preserved as an older
baseline. The release-time validation notes below are retained as history.

## Build 3031 - clear actual arrivals and make room after final unloading

The 3030 log records tractor 324 returning from AD at 21:46:44 on 12 October,
then selecting an ordinary 80.5 m preparation target at 21:46:47 without an
arrival flag. It had not started a route by 21:55:32. The queue used the saved
CP return marker to identify arrival occupancy, although AD handover updates
field detection without necessarily replacing that marker. The log cannot
separate a distant marker from failure to find a valid arrival slot.

Capture the actual position once when the unloader strategy starts. Retain the
native return marker and its access clearance separately. While the full rig
still occupies the actual arrival area, consider nearby aligned headland or
centre-row slots only; do not fall through to a distant assigned stage. Arrival
sampling stays local regardless of fleet index. Check
all destinations and swept routes with the existing crop, obstacle, boundary
and articulation protections. Try direct alternatives first, with 50 ms of
measured work per direct candidate and 100 ms per obstacle-search candidate.
Arrival searches sit between yielding and ordinary preparation in priority,
keep the shared 2 ms update allowance, and are bounded by 1,000 ms accumulated
work and 20 seconds elapsed waiting. Failed attempts exclude their nearby
candidate batch briefly and retry; incomplete routes never become courses.
Native unloading calls and configured departure thresholds still pre-empt.

The same run records CR11/319 finishing its final unload at 22:32:02. CR11/318
was subsequently blocked by the parked combine at 0.3 m at 22:32:40. After its
own final unload, an empty self-propelled combine with another active worker
of the same course nearby now attempts a 20-25 m straight forward clearance
before job completion. Already-empty course completion uses the same path.
Wait for its assigned unloader to release first; preserve native reversing.
Do not move a loaded combine's pipe, change the saved fieldwork course, or
intervene in self-unloading, choppers, towed steering chains or course restart.

Validate the full machine/header envelope on harvested ground inside the
field, incrementally before starting and again over the live near sweep while
moving at no more than 5 km/h. Native proximity braking remains active. A
blocked initial route, route deviation, sustained stop or overall timeout
returns to normal completion safely. Preserve final-unload identity throughout
the manoeuvre, disallow new unloading approaches, and restore the native final
wait state before stopping, retaining the earlier finished-combine release fix.
An empty combine in this parking phase no longer counts as another load when
the native unloader decides whether to depart; use each other vehicle's actual
field position. Other unloading modes keep their original decision.

Regression coverage includes a distant/missing return marker, whole-trailer
arrival clearance, centre-row alternatives, foreground-search starvation,
bounded candidate work, normal preparation resumption, final/empty completion,
both native unload-release paths, header-only obstacles, crop and boundary
rejection, late obstructions, timeouts and cleanup. Existing departure and
recovery suites remain required. Tests simulate the engine boundary, not full
FS25 driving physics; timely entrance clearance and unattended completion still
need the user's in-game validation. Scheduled monitoring remains paused.

## Build 3030 - recover after the unloading tractor finishes reversing

The 3029 log confirms CR11/318 stopped at row turn 1620 on 12 October.
At 20:19:03 its detour failed the final route-clearance check while tractor
322 was still reversing after emptying it. At 20:19:06 the tractor returned
to queue preparation, but the combine remained waiting through 20:24.

Re-evaluate the blocking rig's live ownership when a detour fails and while
waiting for its reserved turn to clear. Once native reversing has finished
and the rig is stopped in preparation, issue one checked clearance request.
Use the original turn clearance area and prefer forward clearance. Existing
yield requests retain their route/search, other combines and clear timers;
repeated updates must not restart the manoeuvre or postpone retries.

Allow a newly issued request five seconds to start. Retry the checked detour
when the actual blockers are stationary, regardless of queue/native ownership.
Check the original waiting area as well as current turn traffic: the rejected
detour's reservation need not cover the original blocker. Moving clearance
and departures retain priority. A clear tractor alone is insufficient: require
the whole rig clear for two seconds, then replan to the same row entry.

Three regression scenarios fail on 3029 and pass with this change: return to
preparation after failure, return while search is pending, and whole-rig
clearance followed by resumption. Coverage also exercises request continuity,
native reverse preservation, movement before retry, bounded retries and a
subsequently accepted route. Existing native departure, other-combine requests,
route validation and earlier fixes remain covered by the release suites.

This repairs the observed recovery lifecycle; it does not weaken the final
collision check or establish why that particular route was rejected. Full
source and packaged checks are required, and unattended completion still needs
in-game validation. Scheduled monitoring remains paused.

## Build 3029 - complete the early-clearance rollback

The 3028 run loaded at 16:52 on 12 October. Tractor 322 entered queue yield
at 16:55:58 while CR11/318 was still working, completed a six-metre reverse
at 16:56:03, then repeatedly failed to find another clearance route. Native
proximity stopped 318 behind it at 16:57:03; the same yield target remained
through 18:56. Removing only the combine speed override in 3028 left the
early ownership intervention intact.

Remove the working-header scan and its proactive yield request completely.
Restore native blocking callbacks as the trigger for working-combine clearance;
do not take an otherwise callable preparing tractor into yield merely because
it overlaps a future header sweep. Native proximity braking, checked yield
routes, turn reservations and parked-trailer recovery remain active.

Separately, ordinary native speed-zero returns must not refresh a queue route's
progress clock indefinitely. After ten seconds without positional progress,
cancel the stalled queue route and use the existing checked retry/backoff.
Explicit waits for reserved combine turns still pause that clock. This applies
only to queue-owned preparation/yield, never to native unloading/departure.

Regression coverage fails on 3028 for proactive ownership and repeated stopped
route recovery, then passes with this correction. Tests also retain native
blocking requests, call availability, search continuity, actual motion,
transient stops, turn waits and collision braking. Keep staged AD-arrival
preparation, finished-empty-combine release, pocket departure pause, configured
cutoffs/native AD handover, accepted bypass retention and bounded checked escape.

The same log separately records tractor 325 stopping at waypoint 97 on an
accepted native approach from 18:24:50. Its obstacle is not identified; this
release does not claim that distinct native-route stall is resolved. Neither
the log nor engine fixtures establish unattended in-game completion. The full
source and packaged release checks are required. Monitoring remains paused.

## Build 3028 - remove the working-combine queue hold

The 3027 incident showed CR11/319 stalled at waypoint 716 for over 23 minutes
while T7.300/322 repeatedly exhausted yield searches towards the same reported
43.7-metre destination. CR11/318 then waited under native convoy spacing.
The 3026 working-header hook could hold the lead indefinitely throughout those
failures; the log did not record which speed override was active.

Keep the early full-header clearance request, but remove its unconditional
speed-zero override. Native proximity braking, collision checks, convoy spacing,
turn priority and parked-trailer recovery retain control. An unsuccessful
preparation search no longer provides its own reason to stop a working combine.

Within the unchanged one-second measured yield-search budget, share 300 ms
across fixed candidates and allow 200 ms for reverse escape before trying
forward escape with the remaining budget. Completed candidates retain their
validated results; unfinished candidates cannot become routes. Charge only
the phase that performed the work, never an untried following destination.
The existing per-frame scheduler limit and whole-train crop, boundary,
collision and articulation checks remain.

Regression tests cover repeated failed searches without a combine speed
override, native obstacle and turn stops, expensive fixed candidates reaching
validated reverse/forward alternatives, and expensive phase transitions.
AD-arrival staging, the pocket pause, native departure thresholds and handover,
finished-combine release, and the earlier turn/bypass corrections are retained.
The complete source and packaged release suites must pass before publication.
Unattended completion still needs in-game validation. Monitoring remains paused.

## Build 3027 - release unloaders after finished combines

The 3025 incident log records CR11/319 completing its final unload, stopping
its job and folding at 08:55:17 on 12 October. T7.300/324 then remained in
UNLOADING_STOPPED_COMBINE, repeatedly waiting for the removed combine strategy.

Retain successful completion only for an empty combine waiting for its final
unload. Clear that marker on job restart; manual stops, errors and non-empty
combines do not qualify. An assigned stopped-unloader now releases the finished
combine and uses native reverse clearance with the retained vehicle markers,
without calling the deleted combine strategy. After clearance it waits for
another active combine on the served field, or takes the native departure and
AD handover when none remains. The configured departure threshold and manual
unload request still take precedence. Check each remaining combine's actual
position, not the position of the completed combine.

Regression coverage executes the native job-stop, reverse-clearance, idle and
marker-departure lifecycle. It checks collision holds, below-threshold final
loads, other-field combines, adjustable cutoffs, manual/error stops, restart,
stale preparation cancellation and repeated updates. Build 3026's traffic and
AD-arrival corrections are included. Automated checks do not establish an
unattended in-game finish; replaying the course remains necessary. The scheduled
monitor remains paused.

## Build 3026 - field arrival and blocked working headers

The 3025 log confirms CR11/318 requested clearance from T7.300/323 at
23:23:49 on 11 October. The queue reported a field-boundary destination
failure, and repeated proximity blocks without waypoint progress persisted
into the following morning. Fixed clearance endpoints could all be invalid
although nearer clear ground might be reachable.

Working combines now request clearance from queue-owned preparation/yield
traffic within their 30-metre full-header route sweep, holding while the whole
rig moves clear. Native unloading and departures keep their controllers. If
fixed yield destinations fail, a bounded local search can choose a reachable,
aligned, clear whole-train footprint. Every edge retains the existing boundary,
crop, obstacle, articulation and self-overlap checks. The fallback tries checked straight reversing and forward steering; it cannot
guarantee recovery from an already physically trapped train.

T7.300/324 returned from AD at 08:18:26 on 12 October and exhausted its queue
search budget at 08:23:38. The old log does not identify that search's target;
a distant assigned target is a code-supported inference, not a proved trace.
Preparation now prioritises nearby checked headland slots while any part of the
rig occupies the AD clearance area. It tries several nearby destinations before
an obstacle-avoiding search, then resumes assigned staged preparation after
clearing the entrance. Native urgent unloading calls can still pre-empt it.
Target coordinates and distance are logged; unchanged failed yield reasons
are repeated only every 30 seconds to expose persistent unsuccessful recovery.

Regression tests cover early full-header holds, trailing-body clearance, native
ownership, invalid fixed endpoints with nearer reachable space, crop/obstacle/
articulation rejection, and arrival priority over a distant assignment. The
four 3025 corrections and previous native protections remain. Automated checks
are not evidence of unattended completion in FS25; that still needs the run.
The scheduled monitor remains paused. Incident evidence is retained under
out/incident-3025-header.

## Build 3025 - combined unattended-run corrections

One release combines the four findings from the 3024 field run. The scheduled
monitor is paused; evidence and discussion notes remain in out/live-log-monitor.
Builds 3020 and 3024 remain available unchanged.

1. Ordinary same-course combine turns reserve their remaining full-header sweep
   against working followers. Fieldwork progress fixes priority, with a stable
   identity tie-breaker. If a follower is already inside, only the leader may
   request a checked detour to its original row-entry target. Native convoy,
   proximity, corner and connector logic remain active.
2. Accepted bypasses are retained while the remaining route is clear. Broad
   traffic overlap no longer resets recovery every frame or renews its timeout.
   An obstructed route stops, retries after five seconds and retains its bypass
   record after a successful retry.
3. A replacement's native stationary approach waits while a departing train
   occupies its exact native destination. It keeps its assignment, checks once
   a second and resumes the unchanged native approach after the whole rig clears.
   After a minute it returns to native idle with a short admission cooldown.
   Other pathfinding failures retain native handling.
4. Preparation uses stable initial/intermediate/near stages, the queue speed cap,
   search latency and whole-rig straightening time. The near target is about
   27 metres behind (more for long rigs and successors). Moving-trigger prediction
   never overrides crop validation. Slots reject bends, turn reservations and
   AD access; headland headings must match the local boundary. Live route checks
   project onto the forward segment instead of mistaking PPC's segment start for
   an obstruction. Blocked goals are temporarily excluded, and arrival requires
   actual train alignment. Early assigned preparation can use a checked headland
   slot when there is not enough course behind the combine yet.

The saved incidents establish the mutual hold, bypass restart loop, replacement
job termination and delayed/repeated preparation. Preparation logs alone do not
identify which clearance branch caused every rejection. Brief native stops that
recovered are not additional defects. The two-second pocket pause, per-tractor
cutoff and native AD handover are retained.

Regression coverage exercises combine update order and equal progress, occupied
goals including a trailing trailer, deferred-search cancellation, successful
bypass retries, clear/obstructed route projection, stable stages, and physical
whole-train arrival before several configured triggers with a delayed search.
These run production code at a simulated engine boundary; they do not establish
unattended completion in FS25. Source and extracted-package release checks must
pass before publishing the ZIP.

## Build 3024 - pocket departure pause and completed bypass cleanup

Two narrow corrections on build 3023; previous release ZIPs remain unchanged.

The full-session log preserved at out/incident-3023-pocket-turn/log-20261011-160310.txt
records T7.300/324 backing away from CR11/319's unloading pocket at 16:00:31,
then starting its forward departure route at 16:00:44 while the combine returns
to its row. Add a two-second stationary pause when that forward route is ready
to move. Reverse clearance and pathfinding run normally; search time does not
consume the pause. Ordinary departures, native backing/yield recovery, the
per-tractor full threshold and native marker/AD handover remain unchanged.

A later full-session snapshot, log-20261011-1612.txt in the same evidence folder,
records CR11/319 turning at waypoint 1419. Its first bypass failed final vehicle
clearance at 16:08:02.142. The retry accepted an immediate analytic route at
16:08:07.908, but the completed planner remained attached to the strategy.
The next update resumed it without start arguments, causing HybridAStar.lua:260
errors every frame. Detach an immediately completed queue bypass planner before
its completion callback. Preserve asynchronous searches and all route checks.

Regression coverage exercises the real immediate analytic search and subsequent
production strategy updates, plus the timed pause, search latency, reverse
recovery, ordinary departures, job cleanup and native handover. The immediate
completion test reproduced the failure before the fix. Release checks must pass
against source and extracted ZIP; in-game acceptance remains outstanding.

## Build 3023 - bounded headland-to-centre entry and follower wait

This is a separate correction on top of the exact 3020 rollback in build 3022.
Both rollback and original release ZIPs remain retained unchanged.

The preserved 3021 incident log records CR11/319 finishing its headland at
22:00:30. Its three local connector entries failed clearance against T7.300/322;
at 22:00:48 it accepted a full route beginning in reverse. CR11/318 entered its
headland corner, and the native historical-trail convoy distance still reported
about 55 metres shortly before a proximity reading of 0.2 metres. An unmatched
trail later returned infinity. These explain the chosen route and inadequate
following separation, but do not establish why an earlier successful run differed.

The 3020-to-3021 package diff changed only the stationary unloader admission
guard and version. The incident's first recorded unloader call was a moving
rendezvous after the failed entries, which bypasses that new guard. No evidence
shows the 3021 guard caused this corner incident; it remains completely reverted.
The retained 3020 comparison copies start mid-operation at 15:07:34. This is a
limitation of those copies, not evidence that the user started logging late.

The original local entry remains first choice. Only after its clearance fails,
and only for a headland-to-centre connector, try a 2 m then 4 m forward lead-in
with the native Dubins solver. Keep the exact saved join/suffix, native turning
radius, fruit policy and complete machine/header clearance validation. Validation
remains capped at 20 samples per update. Reject obstructed alternatives and retain
the existing next-candidate/full-route fallback; never start an unchecked route.

For a same-course follower approaching or turning a headland corner, maintain
its configured CP convoy distance in physical space while the lead plans/drives
its centre entry. This is deliberately more conservative than the historical
trail slowdown during that specific phase. It can hold the follower before the
corner until the lead clears that spacing. It changes only the returned speed,
never the course, steering, tractor state or leader's priority. Release when the
lead clears the distance, leaves the entry phase or stops its fieldwork job.
Normal row turns, other connectors, centre-row work and different courses are
excluded. Log entry/exit of the hold once per transition.

Regression coverage uses the recorded pose, saved connector coordinates and
tractor/trailer dimensions with production path assembly and collision code.
The original and 2 m alternatives fail; 4 m passes and preserves the suffix.
Also check crop/header rejection, bounded retries, original successful entries,
follower hold/release, adjustable spacing and excluded states. The planar fixture
does not replay crop density, scenery or terrain slope. Source/package tests and
release qualification are required; same-save in-game acceptance remains needed.

No staged-preparation, AD handover or trailer-departure changes are included.

## Build 3022 - restore build 3020 exactly

At the user's request, revert the entire build 3021 change (commit
29e9eee120389eb4a69930c44510ea0d82f69106). The user reported that the following
combine no longer waited and the leading combine did not make its usual right
turn into centre work. The current game log was preserved before reverting.
This rollback does not claim a verified causal explanation for those symptoms.

The runtime is restored to build 3020, commit
28b1bd6a8c19f04e4905bb21b997839788a74a00. Remove the stationary approach admission
helper, its call-hook check and the associated tests/release-suite addition.
Retain the agreed staged-preparation requirements as documentation only.

Release qualification must compare every packaged file with the retained 3020
ZIP and allow only the version number to differ. Run the normal source and
extracted-package checks as well. Preserve both previous release folders.
No replacement fix or staged-preparation feature is included in this rollback.

## Agreed requirements - staged preparation (10 October 2026)

These user-confirmed requirements govern the next preparation change and
supersede any earlier description of continuous following or parking alone.
They describe intended behaviour, not a claim that build 3020 implements it.
Build 3020, commit 28b1bd6a8c19f04e4905bb21b997839788a74a00, remains the
user's currently working traffic/unloading baseline. Preserve that release and
its ZIP unchanged; subsequent implementation needs a separate commit/build.

### Staged movement and waiting

1. Once native CP takes control of a returned, available trailer, move it away
   from the AD arrival/exit point and into a safe field staging position. Roughly
   halfway towards its assigned harvester is a suggested starting position,
   subject to harvested ground, access and traffic clearance; it is not a rigid
   midpoint or a requirement to cross standing crop.
2. Park and wait between movements. As the harvester fills, advance in distinct
   stages to nearer waiting positions. Do not continuously follow the harvester,
   chase its position or repeatedly move a parked rig for small position changes.
3. Allow for travel and whole-rig alignment so the lead trailer is about 30 yards
   (27 metres) behind before the harvester reaches its configured CP unloading
   trigger. The trigger is per the CP setting, not a hard-coded 80%. Native CP
   owns the final approach, admission/crop checks and unloading. When immediate
   unloading is unsafe, stage nearby on safe ground without weakening those checks.
4. While loading, estimate whether the current trailer can accommodate the
   remaining load, accounting for compatible free capacity and incoming harvest.
   If it cannot, bring a compatible replacement to a nearby waiting position
   before capacity runs out, ready for prompt native CP changeover. Retain
   existing reservation and partial-load priorities; avoid duplicate dispatch.
5. Full or departure-ready trailers retain native CP departure and AD handover,
   using each tractor's adjustable emptying threshold, not a hard-coded 85%.
   They leave the loading area and follow the established exit behaviour.

### Alignment and clearance at every stage

Every initial, intermediate, near-harvester and replacement staging position
must align and straighten the complete tractor and attached trailer train:

- On a headland, parallel to the local outer field boundary.
- Within the field, aligned with the centre work rows.

Provide enough approach length and spacing to straighten the whole rig rather
than merely point the tractor towards the target. A diagonally parked trailer
or articulated rig is not an accepted staging result. Keep arrival/exit access,
departure routes, active combine turn areas and other parked rigs clear. These
are staging requirements; retain native manoeuvres needed to reach or leave
the position. Combine priority and the working 3020 traffic behaviour remain.

### Scope and acceptance

Participation remains automatic for eligible CP unloaders. Support grain and
other tank harvesters, including beet/vegetable harvesters where supported by
CP. For forage/continuous-output harvesters, use continuous service and trailer
capacity/changeover timing rather than assuming a grain tank reaches 80%.

Keep the change within trailer preparation, staging and replacement readiness.
Preserve 3020's combine courses, headland corners, centre-work transitions,
convoy waits, straight entry, yielding, native unloading and AD departure.
Do not add new options, AD driving logic or broad combine/pathfinder changes.

Regression scenarios must demonstrate clearing the AD point; staged advances
with stationary waits; whole-rig alignment in both permitted orientations;
readiness before different configured triggers; alternative safe positions
after a blocked preparation route; replacement readiness before capacity runs
out; no duplicate reservation; continuous-output replacement timing; and
unchanged 3020 traffic and native departure. Measure actual readiness and
position in scenario tests, not merely successful route generation. Release
checks must pass on source and packaged ZIP, followed by validation in the
user's saved game before describing the behaviour as accepted in-game.

## Current contract - build 3020: separate turn traffic from queue ownership (9 October 2026)

This fixes the build 3019 incident preserved in out/incident-3019/log-2244.txt.
At 22:33:09 the departing T7.300/324 obstructed CR11/319's native turn search;
native calculated fallback added a reverse section. Assigned T7.300/325 was
still clearing that combine. Incoming T7.300/322 then entered the same area
and transferred to queue yield at 22:34:27, where standing crop prevented the
queue search from starting. These were three different native jobs, not three
parked queue trailers. The former parked-only preflight missed that distinction.

Ordinary planned row turns now reserve their full swept area and observe all
participating rigs regardless of queue ownership. Moving native traffic holds
the combine clear. A stationary native obstruction can use the same checked
detour as a parked queue trailer, without taking its assignment, course,
departure flag or pathfinder. Failed native detours retain that job and retry
the original row entry after five seconds. Native departure and AD handover
remain under CP's existing controller and each tractor's adjustable threshold.

Incoming queue preparation and native approaches stop before entering the
reservation, using a whole-rig course envelope and a speed-dependent stopping
horizon. Native waiting transitions retain that protection. Rigs already in
the area, departing rigs and the turn's coupled unloading/reversing follower
retain native local coordination; they are not frozen until the entire future
turn clears. Proximity cannot seize a protected native backup into queue yield.
Before a native-to-queue yield transfer in this ordinary-turn context, validate
the real starting configuration. An invalid crop/boundary/collision start keeps
the native job intact; this does not waive checks or prove an escape route exists.

Reservations expire on turn change, stop or scope exit. Approach checks are
cached for at most 100 ms and invalidated when reservations change. An obstacle
entering an accepted detour stops the combine before checked replanning. Existing
parked-trailer plan-first/forward-clearance behaviour remains in place.

Scope remains ordinary planned row-to-row travel. Native headland corners,
FinishRowOnly, headland-to-centre entry, active-combine convoy waits, saved
courses, straight entry, crop checks and native strategy/turn method bodies are
unchanged from 3019. This is not a parking, allocation or AD integration rewrite.

Qualification includes 39 turn/traffic tests, 25 yield tests and 65 runtime
tests, including the full/backup/incoming sequence, reservation installation
during an update, native waiting transitions, successful and failed detours,
late obstacle arrival, job preservation and a real crop-blocked queue start.
Run all release suites on source and extracted ZIP, including native parity,
connectors, departure and packaged Lua compilation. In-game acceptance of the
same saved-game sequence remains necessary; mocked checks do not prove physics.

## Current contract - build 3019: plan around parked trailers before yielding (9 October 2026)

Starting from the exact 3013 runtime restored in 3018, ordinary planned
row-to-row travel checks the actual turn course against parked CP queue rigs,
including the combine header and every attached trailer. Check the complete
turn when installed, before the first drive command. Subsequent approach checks
use a 30 m horizon every 200 ms; an obstruction reserves the complete remaining
turn for clearance. This does not scan a row-finishing extension as a turn.

Priority is explicit: stop short and reserve the trailer, then plan a checked
combine detour to the unchanged row-entry target. Keep native proximity and
convoy speed limits. A native forward/reverse request cannot move this reserved
trailer ahead of the detour decision. Reverse-disabled recovery must also plan
first; it cannot start a speculative reverse manoeuvre.

Only a failed or timed-out detour requests trailer clearance. The combine waits
while the queue searches a validated whole-rig escape, trying forward distances
before lateral/reverse candidates and retaining its existing quickest-clearance
selection. Clearance must cover the complete reserved turn, not just the tractor
or a short strip. After the whole rig clears for two seconds, replan the same row
entry; do not skip the turn or blindly resume the blocked route. Another active
harvester's outstanding yield request prevents reclaiming that trailer.

Scope excludes native headland corners, FinishRowOnly, headland-to-centre
connectors, incremental turns without a planned course, active combine convoy
coordination and native full/manual departure. Native route generation, crop
checks, turning radius, saved course and straight entry remain as restored in
3018. Departure continues to use each tractor's adjustable CP threshold.

Qualification adds same-update preflight, moving-combine braking, header-only
obstruction, approach detection, no-obstruction/native-stop parity, scope
exclusions, native reverse-request ordering, detour-failure/forward-yield/replan,
whole-trailer clearance, other-harvester yield retention, late callback rejection,
reverse-disabled planning and successful ENDING_TURN completion. Real planner
and articulated escape tests exercise production searches with engine-boundary
fixtures. Release checks run source and extracted-ZIP suites. These checks do
not establish live physics or acceptance in the user's saved game.

## Current contract - build 3018: exact restoration of 3013 (9 October 2026)

The user confirmed build 3013 works at the tested map location and explicitly
requested restoring that implementation. All runtime files are restored to
commit 5c9734c9d4a7f90e7c9024e2a995c0e4142170d6. This removes the runtime
changes in 3014 through 3017, including the additional turn envelope, broader
parked-vehicle recovery, connector recovery and direct-turn attempts. The
matching 3013 tests and qualification checks are restored with that runtime.
Later commits and packages remain available; no history is rewritten.

The new release is qualified with --match-release against the retained 3013 ZIP.
Its inventory and every entry must match byte for byte except the modDesc.xml
version. This is an exact restoration, not a new manoeuvre implementation, and
does not claim to solve other limitations which existed in 3013.

Every future release requires a distinct clean commit and a full-commit-SHA
folder below dist/unloader-coordinator/history. The ZIP filename remains
FS25_Courseplay_UnloaderCoordinatorTest.zip. build.json records version, commit
and SHA-256; restored releases also record the reference ZIP SHA-256. Publishing
a second release for the same commit or reusing a version is rejected. Previous
numbered releases have been copied to their original commit folders and hash
verified; legacy numbered folders remain intact so existing links still work.

The running 3017 log was preserved before restoration. It showed local entries
rejected for native clearance near the starting pose, forward variants rejected
for crop, and the subsequently accepted full route immediately intercepted by
the added parked-trailer recovery. These changes are removed by this rollback;
no further changes to CP behaviour are included.

## Current contract - build 3017 (9 October 2026)

Parked-vehicle avoidance must not take ownership of native row finishing or
coordination between active CP harvesters. The extra queue envelope now returns
native speed unchanged during FINISHING_ROW: that phase follows an overlong
straight guiding course which native implement raising ends early, not a
committed turn. The queue must not reserve its unused tail and trigger a trailer
reverse before the actual turn exists. Native proximity remains active.

An active CpAIJobFieldWork harvester is excluded from the added queue envelope
and parked-vehicle recovery, including while temporarily stopped. The original
native blocking callback and convoy/proximity limits remain in charge. A stopped
fieldwork job is a genuinely parked obstacle again. Actual turns around parked
trailers and inactive combines retain the checked detour and header guard.

Evidence: the preserved 3016 log before reset shows CR11/319 stopped by the queue
while finishing its row at 13:21:19.776; trailer 322 began a 10-metre reverse at
13:21:21.978. At 13:21:49.068 the new connector guard held the lead combine for
active CR11/318. At 13:22:15.183 custom recovery labelled 318 parked. Its failed
detour ended in ERROR_NO_PATH_FOUND at 13:24:15.403, and 318 then remained blocked
by 319 until game exit. These are scope errors in the added recovery, not evidence
that the native convoy controller was removed. The earlier successful 3013 run
had no additional queue envelope. Its first combine's local joins also failed
before a full-route search. Current evidence does not identify the exact cause
of each rejected 3016 U-turn: new per-candidate diagnostics distinguish crop,
native clearance and an unfit exact join without changing those checks.

Three regressions fail on 3016 and pass after the scope correction: unused
row-finishing tail; active harvester versus genuinely parked harvester; and
native blocking callbacks during both a turn and centre-work approach. The
40-test detour suite still covers real planner/header clearance. Release checks
also qualify the packaged ZIP. Actual physical corner timing, trailer clearance
and the tight-turn choice still require the saved-game run; mocks cannot establish
those outcomes. No native course, waiting, collision or AD method is changed.

## Current contract - build 3016 (9 October 2026)

Headland-to-centre connector entry tries the native direct Dubins turn before
allowing the preliminary grid search to veto it. It first tries every existing
local join from the current pose. Only if these fail does it try each join after
a straight forward leg of 3, 6 and then 10 metres. These legs are planned and
validated as part of the complete manoeuvre, never driven speculatively. The
existing local and full-route searches remain the final fallbacks.

The native turning radius, exact join, saved course suffix and straight entry
remain intact. Every new path, including its forward leg, must pass the existing
header/body and crop checks before movement. Validation remains bounded to 20
samples per update. No global pathfinder, working-row or AD changes are included.

Evidence: build 3013 accepted waypoint 10 on 8 October at 16:54:45 after the
native planner found a direct LSL turn in 56 ms. Build 3014 attempted that same
join on 9 October at 09:08:41 from a pose only centimetres away, but exhausted
3,000 preliminary grid iterations in 3,883 ms. The direct turn solver was never
reached. It later selected waypoint 6. The reason the preliminary grid differed
is unproven; the fix removes its veto over an independently checked direct turn.

Regression coverage checks the recorded tight-turn geometry with centimetre pose
variations, a real header obstruction requiring the 3-metre forward fallback,
an obstruction on that forward leg preventing movement, and exhaustion of every
direct variant returning to the original search. The 24 connector tests retain
crop, header, seam and straight-entry coverage. Offline qualification cannot
establish physical steering or successful completion in the live save.

## Current contract - build 3015 (9 October 2026)

An empty trailer must return from successful clearance to the callable queue.
Yield candidates now include straight forward moves of 10, 20, 40 and 60 metres,
as well as existing side passes and reversals. Every candidate still requires
whole-train, field, crop and obstacle clearance; the shortest clearance time wins.
A tractor held stationary for a harvester detour is excluded from allocation and
native calls until the hold ends. Fullness/manual departure retains precedence.

The live header/body guard also covers DRIVING_TO_WORK_START_WAYPOINT. Before
implement lowering starts, a stationary obstruction can initiate native recovery
using the existing row-start context. It searches a local forward detour to a
point at least 60 metres (or six turning radii) ahead on the existing temporary
route, rather than searching hundreds of metres to the final row. An exact
analytic seam rejoins the original route; its straight entry and lowering markers
remain intact. The new detour and its exact join are collision checked before installation;
the unchanged connector tail remains under the live braking-distance guard. Native recovery restores listeners and resumes the saved fieldwork
course at its original destination. Failed detours request yield and retain the
existing bounded clearance wait; they never release an obstructing trailer for
an unrelated call or ignore a collision. Working rows and AD handover are unchanged.

Evidence: 3014 log, 9 October 09:09:36.145, CR11/318 accepted a connector entry.
At 09:09:44.816 proximity stopped it 1.4 metres from T7.300/322, within the checked
analytic tail. At 09:09:51.817 tractor 322 entered QUEUE_YIELD; its escape search
reported destination: field boundary. At 11:55 it was still yielding and CR11/319,
at 95.01 percent, saw it as busy. Other tractors had stopped CP with NEEDS_UNLOADING
(323/324) or ERROR_NO_PATH_FOUND (325). The turn-only guard/bypass did not cover
this connector phase. No log evidence establishes that 3014 changed the original
connector selection; tight path validation versus live tracking remains a live
validation concern, now covered by the predictive guard and checked recovery.

Regression coverage adds a narrow-headland forward escape through the real queue
search, return to callable preparation, work-start header guarding, native recovery
completion/listener restoration, protection of a held trailer against competing
calls, failed-detour yield and unchanged-obstacle retry suppression, and a native
planner detours that locally rejoin routes with 475-metre and 2.5-kilometre final
destinations without treating the unchanged tail as a bounded short turn.
Offline checks do not establish physical steering or acceptance of the live save.

## Current contract - build 3014 (9 October 2026)

New turn routes must be checked for parked vehicles before the harvester starts
following them. A newly installed turn is checked over its complete length against
nearby parked harvesters and tractors, including their attached implements. A
blocked route is held and replanned to the original turn destination. The saved
fieldwork course and work-start waypoint remain unchanged. The local moving guard
also checks body/header clearance through the braking horizon, independently of
proximity-ray hits. It covers parked harvesters whose CP driver has stopped.

The turn bypass now accepts stationary harvesters and non-queue tractors without
claiming their controls. A queue tractor can be held during the detour. The native
Hybrid A* detour reserves tracking clearance around the actual vehicle envelope;
its completed course, including alignment and reverse extensions, must still pass
a separate clearance check before installation. A rejected route gets one
forward-only alternative using Dubins geometry. Both failures request queue yield
where supported and hold the combine for clearance. Retry requires changed
obstacle geometry; unchanged obstacles do not cause repeated searches. Clearance
waiting is bounded to 120 seconds, with a diagnostic stop deferred to the next
strategy update boundary. Unknown geometry is retried with a bounded diagnostic
failure rather than silently waiting forever. No unchecked reverse or row-skipping
fallback is installed. Native CP full-trailer departure/AD handover remains as in
3013, including each tractor's configured cutoff.

Evidence: loaded 3013 log, 9 October 08:18:42.578, CR11/319 attempted a bypass of
T7.300/324; its 94-point solver path became a 105-point native course and final
clearance rejected a collision at 08:18:43.191. The old failure branch stopped the
job without requesting yield and caused a deleted TurnContext debug-node error.
At 08:19:39.575, following CR11/318 detected stopped CR11/319 at 1.3 m, then logged
no obstacle at 08:19:39.911 and continued. 3013's reactive bypass only accepted
queue tractors and did not preflight the initial turn or cover parked combines.

Regression coverage includes a blocked vehicle 75 m along a newly planned turn,
missed ray hits, attached header overlap, moving versus parked vehicles, real
native planner side detours around a trailer and a wide combine, forward-only
gear restrictions, final-course rejection before installation, actual queue-yield
transition, unchanged-obstacle retry suppression, stopped-job blockers, geometry
recovery, and safe deferred timeout. These are offline engine-boundary tests;
acceptance of the live save, physical steering and frame cost remains outstanding.

## Previous contract - build 3013 (8 October 2026)

This revision supersedes the custom row/headland exit and AD-node handover
requirements recorded below. The user explicitly requested native CP handover.
At each tractor's configured full threshold (not a hard-coded 85%), preparation
ends and CP owns departure: reverse clearance where applicable, native return
marker pathfinding, then the native full-job/onCpFull event. With no marker or
failed marker path, CP's original direct event fallback applies. AD owns its
field-exit and delivery route. The queue neither selects AD nodes nor gates that
event. An accepted native departure cannot be reclaimed for preparation/yield.

The same build includes the requested parked-trailer bypass during a persistent
forward blockage in a combine turn. It uses the existing turn context and native
RecoveryTurn implement preparation. Only a stopped, unassigned queue trailer
below its departure cutoff can be held while the combine passes. Working rows,
reverse blockage, active searches and special callback/self-unload turns retain
native handling. Another harvester's yield request is not overridden.

The bypass uses CP's full Hybrid A* with native fruit penalties and vehicle/header
collision constraints, avoiding the fast middle path's penalty-only smoothing.
The final course, including native alignment/reversing adjustments, is checked
again at 0.5 m / 3 degree intervals. No checked route, invalid final clearance or
blocked recovery stops the job rather than using an unchecked calculated turn
or skipping to the next row. Holds expire with an explicit recovery failure after
120 seconds; normal completion, cancellation and full/manual departure release
both references. Existing combine fieldwork courses are not rewritten.

Validation: native marker/no-marker/failed-path handover, actual CP job event
mapping, per-tractor thresholds, ownership/cancellation, native reverse clearance,
real RecoveryTurn lifecycle, whole-header detour through CP's actual planner,
failed/final-invalid routes, active versus completed searches and hold cleanup.
The installed AD 3.0.1.2 event handler is exercised read-only with mocked vehicle
services. These are offline checks, not acceptance of the live save or physics.
The obsolete custom-exit journey tests are replaced by native-departure tests
because their protected behaviour is deliberately removed by this request.

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
Priority does not require a tractor to move when the harvester's existing safe
CP route already passes it. Queue yielding reads that route and responds to
native blocking requests; it does not add mid-turn harvester rerouting.

The user authorised a separate steering adjustment on 5 October (build 2999):
harvesters following an existing forward work-start approach use an 8 m base
lookahead on straight/gentle sections. Tight bends, reversing and the final
15 m use native short lookahead. Native work/turn resets and temporary short
overrides remain effective. This changes tracking only, not waypoint geometry,
route generation, validation or unloading. Other fieldwork implements retain
their original lookahead. Release qualification permits only this exact
reviewed addition to the combine strategy; all original method bodies still
have to match the pinned baseline.

Build 3000 addresses the two combine stops in the 5 October build-2998 run.
CR11/318 exhausted its native connector searches then immediately stopped on
the installed fallback. CR11/319 found a turn, then the additional corridor
validator rejected it. The pinned main includes implement-profile restrictions
which are absent from stock CP: it is not itself a stock CP baseline.
Self-propelled harvesters (`spec_combine` on the driving vehicle) now use native
CP's turn acceptance without this extra work-width-circle corridor veto, for
calculated turns, pathfinder turns and StartRowOnly connecting approaches.
Native turn-on-field, fruit, collision, reverse and target arguments remain;
the shared pathfinder and waypoint generators are not changed. Other implement
turns and every queue world query still use the explicit corridor. Six regression
tests exercise these boundaries, including successful path installation and the
previously rejected fallback approach. The correction does not eliminate native
search failures or promise a particular search time, and still needs live testing.

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

## Harvester coverage and automatic activation

The CP combine-unloading job is the activation boundary for ordinary trailers;
there is no queue option to enable. This includes grain combines, forage
harvesters, beet harvesters, potato harvesters and vegetable harvesters served
by that native job. Classification follows CP's `alwaysNeedsUnloader()` and
actual controller capacity, never a vehicle name or a presumed crop type.

- **Tanked harvesters:** use CP's existing call/unload percentage, capacity and
  fill prediction. Include the native controller's processing/loading-delay
  contents for root crops. Prepare a compatible trailer by that deadline;
  preserve CP's pipe geometry, rear approach, pockets and row-end decisions.
- **Continuous harvesters:** an unserved machine needs a lead immediately.
  While its native owner collects crop, prepare one successor. Its deadline
  comes from that owner's usable free capacity (including mass limits) divided
  by measured intake. Unknown intake means prepare promptly, not wait. Close
  the successor's gap as this time decreases, while keeping turning and native
  rear-approach space. The idle trailer departure percentage is not a fictional
  tank setpoint and must not force a native continuous transfer to finish early.
- **Changeover:** native CP decides when collection ends, releases its owner
  and performs reverse clearance. Only then may its next native call take the
  prepared successor. Queue code never starts a second pipe follower or
  displaces a serving trailer. A continuous owner cannot promise to finish an
  imaginary tank and cover a different harvester at the same time.
- **Compatibility:** use the actual discharge fill type and trailer fill units.
  For an empty continuous harvester with unknown output, preparation may use
  supported types from its actual pipe discharge unit. This does not grant a
  new unloading permission; native output discovery and dispatch remain in
  charge. Recheck when the output becomes known. Do not assume all forage is
  chaff, all vegetables share a fill type, or part-filled trailers can mix loads.
- **Shared rules:** every participating harvester gets the same compatible
  fleet allocation, queue parking, full-train clearance, priority and harvested
  row/headland departure before AD handover. Native following handles clearance
  and turns beside the trailer's own continuous harvester; other trailers yield.
  Auger self-unloading, field tipping and GIANTS delivery jobs retain their
  existing native handling and are not converted into AD queue jobs.

Test coverage must include tanked grain/beet/vegetable machines, continuous
forage/vegetable machines, delayed root-crop processing, known/unknown and
changing output types, partial/incompatible loads, mass-limited free capacity,
unknown/paused intake, multiple distant harvesters and mixed fleets. Exercise
preparation, native acceptance/ownership, collection, successor selection,
release/reverse and exit; retain the existing geometry/crop/AD tests. Native
controller classification, fixed and auto-aim pipe entry, and physical-fullness
changeover are executable contracts. In-game physics and timing still require
acceptance with representative machines; a mock must not be reported as that.

## Implementation order

1. Establish and qualify the clean main baseline.
2. Define explicit idle queue ownership and native CP handover, initially with
   component qualification before movement. Add reservations before movement.
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
native decisions against the automatically integrated queue. Component tests alone
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

At the foundation milestone, the remaining work was: engine fleet snapshots,
ownership/cancellation hooks, crop queries for growing and ripe crops, route
validation for every attachment, straight parking and lag movement, safe
priority manoeuvres, native-call integration, full harvesting simulations,
bounded-work measurements, and controlled in-game acceptance. No component
test substitutes for those checks.

Assert safe geometry and actual transfer progress, not merely state names.
Where native crop or turn restrictions prevent unloading at the configured
level, the queue must keep the trailer near the legal entry and preserve the
restriction. Report the constraint rather than forcing an unsafe approach.

## Operational candidates 2993 onwards

Build 2996 activates the queue automatically for tractors running the native
CP combine-unloading job with ordinary trailers. There is no extra option.
The setting introduced in builds 2993 to 2995 has been removed; previously saved
values cannot disable preparation. Auger wagons, field unloading and GIANTS
unloading retain their native ownership. In-game acceptance is still required.

Seven queue modules are loaded through a small hook file. Existing runtime
files, including both native strategies and every shared solver, remain
byte-identical to pinned main. The only existing-file changes are the module
manifest; vehicle settings and translations match main again. Native crop/readiness checks,
rear approach, pipe following, combine turns and native reverse clearance
remain in their original methods.

Build 2997 extends those snapshots to all native continuous-harvester types,
including forage and conveyor-fed vegetable collection. It adds a successor
forecast using measured intake and usable trailer capacity, output compatibility
at the actual pipe node, and accepted-call ownership before registration.
Tanked beet/vegetable machines use the same native tank deadline as combines.

Build 2998 corrects queue crop probing: `FruitTypeDesc.cutStates` already contains
the density state values, so adding one wrongly rejected harvested stubble and
could permit a different, still harvestable state. Tests now evaluate the actual
filter value against explicit wheat, canola, grass, potato, sugar-beet, carrot,
parsnip and maize state fixtures, including mixed live/cut pixels and a completed
preparation route over stubble. They no longer return a cut count for any equality
filter. Start and destination failures are identified separately; a blocked
start does not blacklist an untested destination. Native combine routes,
route validation, crop protection and shared pathfinding are unchanged.

The runtime takes fleet snapshots once per second, measures transfer progress,
assigns preparation/successor slots and separates reserved parking targets.
Build 2995 accounts for grain still being harvested during unloading by combining
the tank's level change with measured trailer intake. Forecasts require stable
ownership. Both future reservations and successor preparation include that
continuing harvest, rather than relying on a native rate which can reset to zero.
Queue movement uses a private incremental search, strict growing-crop checks,
field/island containment and every supported towing link. When the configured
AD waiting point is outside the field, preparation may use a bounded entrance
to the nearest field edge. Roadside grass is allowed in that entrance; grain,
other standing crops, islands and collisions remain forbidden. This entrance
does not permit unrelated field exits. Native calls cancel
queue ownership and use their original pathfinder. Stale searches cannot
replace native courses. Reversing-combine requests retain native backup.

Priority clearance compares validated forward/lateral and straight reverse
routes by whole-train clearance time. If simple options fail, a bounded queue
search tries a detour. Native proximity and collision controllers remain
active. Actual train clearance can release a manoeuvre before its route ends.

Departure captures the saved working course before native release clears the
combine reference. It returns through that row corridor to the outer headland.
Resumed full rigs can propose a corridor from their current position on an
active working course; live crop/geometry validation is still mandatory. Both
native immediate-finish fallbacks are intercepted. Handover requires all
bodies on harvested headland, a connected directed AD delivery route and a
clear local connection. Perimeter nodes just outside the field are supported;
arbitrary interior nodes and island headlands do not authorise handover. No AD
task, setting or installed file is changed.

Only one background search advances per frame, with a 2 ms target checked
between geometry samples; a single engine query can exceed that target. Native
searches take precedence. Moving rigs retain live body and stopping-horizon
checks. Background overlap tests do not append to the shared debug-box array.
Search elapsed time and measured advance cost are different; neither is FPS.
Build 3001 charges the 15-second preparation budget only for update frames in
which that search is advanced. Time paused behind native pathfinding, another
queue member or before search creation does not consume it. The shared 2 ms
per-frame allowance and native priority are unchanged. This corrects premature
search expiry; it does not make rejected entry positions valid or guarantee a
staging route can be found. The 5 October run had no successful preparation
route before native calls, with both start-boundary rejections and expired
searches; late native unloading is not evidence that preparation succeeded.
Start-boundary failures now report the root position and why a bounded entrance
was unavailable, including the distance from the saved start marker. The old
log cannot establish that the rig was incorrectly parked; containment and crop
checks are unchanged.

`test_runtime.py` adds engine-boundary coverage for automatic membership without an option, excluded unloading modes,
native rear-call dispatch, failed/missing exits, ownership and generation
changes, actual chain modelling, growing/cut/unknown crop states, obstacles,
route confinement, reverse tracking-node conversion, clearance choice,
shared scheduling, saved-course capture and AD/headland eligibility. Together
with the previous suites these exercise 136 queue-related tests in source and
the extracted ZIP. Build 2999 adds nine steering tests using real Course/PPC
methods for straight/curved paths, angle wrap, tight bends, reversing, final
entry, unchanged waypoints, native resets, state isolation and other implements.
These do not simulate tyre physics or establish that live oscillation is cured.
The full release also runs existing implement-profile,
headland, pocket, work-entry, double-pivot and packaging checks.

Remaining acceptance is in FS25: vehicle physics and PPC tracking, real crop
density and collisions, dispatch timings under actual yield, AD pickup/delivery
and unload modes, and measured frame behaviour with the user's fleet. Unsupported
attachment geometry, missing course/boundary evidence or an unavailable AD
connection causes a logged safe wait; it never permits a crop shortcut or a
mid-field handover. Automated tests cannot establish those engine outcomes.

### 5 October build 3000 incident trace

CR11/318 left original waypoint 695 at 12:08:56.642 and requested a route along
its 709.1 m connector to waypoint 907. At 12:09:52.199 the first search exhausted
40,000 iterations. Native CP retried with collision mask zero while retaining
the preferred connector and maximum fruit percentage 50. At 12:10:10.952 it
accepted a 494.3 m route, subsequently extended to 503.3 m for entry. The log
does not prove that a crop-free route was separately tried and ruled out.
The locally available stock revision uses soft crop and preferred-path costs;
its analytic crop rejection threshold is twice the configured percentage.
Build 3000 altered acceptance by removing the additional implement-profile
harvester corridor veto, not these route-search rules. Build 3001 leaves that
native route generation unchanged. A strict crop-free-first connector policy
would be a separate combine-routing change, outside queue preparation.

There was no successful `Queue: driving prepare` record in this run before the
reported late arrivals. T7.300/322 was rejected at its start by field containment;
other preparation searches exhausted their budgets. Native CP called /322 from
560.1 m at 12:12:03.627 and /324 from 373.8 m at 12:13:15.157. CR11/318 waited
before its next row from 12:13:49.034 until approximately 12:14:59.403, with
unloading completed at 12:14:54.239. This eventual recovery does not meet the
requirement to have an eligible trailer staged behind before the row ends.

### Build 3002: AD route-return contract

The same build 3000 session left all four full trailers in `QUEUE_EXIT`:
/322 from 12:31:51, /325 from 12:39:38, /324 from 12:45:48 and /323 from
12:56:50. Repeated `no connected AD route at the headland` messages continued
past 14:44 without a handover. AD 3.0.1.2's `pathFromTo` omits the starting
waypoint on non-trivial routes; the queue wrongly required it, rejecting valid
routes. The original test double incorrectly included the starting waypoint.

Build 3002 accepts either representation, checks the edge from the candidate
node to the first returned waypoint and every subsequent directed edge, and
requires the selected delivery destination at the end. Single-hop routes are
valid. Empty, disconnected and wrong-destination paths remain invalid. The
first outgoing edge supplies the heading. Crop, collision, whole-train headland
clearance and CP-owned departure checks are unchanged; no mid-field handover
or modification of AD is introduced. Build 3001's scheduling fix is included.

Five regression tests cover route shapes, target selection, directed links,
heading, successful headland handover, a trailer still outside the headland,
standing crop and obstacles. The old code was confirmed to fail the valid-route
and handover cases. `tools/unloader-queue/verify_installed_ad.py PATH_TO_AD_ZIP`
also executes the actual installed AD route calculator and graph wrapper on a
small directed network, with engine dependencies mocked. It passed multi-hop,
single-hop and disconnected checks against installed AD 3.0.1.2 (ZIP SHA-256
`6a43ae41edc70f7d97cdaa3c4b7e8f1106128928d9807b6c3bdaed59fb3c7f39`).
This establishes the interface contract, not successful driving in FS25.

### Build 3003: final harvester connector clearance

The build 3002 incident is separate from trailer preparation. CR11/318 accepted
a 495.5 m connector at 16:00:45 on 5 October, extended to 504.5 m by StartRowOnly.
At 16:02:12 its live sensor detected an obstacle 1.2 m away near temporary
waypoint 173; it subsequently remained blocked at the boundary trees. The
planner had detected tree collisions nearby, but the final smoothed and extended
course had no complete clearance gate. The log does not identify the exact
smoothing operation responsible. Although the native retry message says
"disabled collisions", its four-argument detector call places the mask in the
ignoreFruitHeaps argument; the detector retains its default collision mask.
That message must not be treated as proof that obstacle detection was disabled.

The user authorised this isolated harvester connector correction. A separate
module intercepts completed connector searches and exhausted-search fallbacks.
It prepares the real StartRowOnly course once, applies native fieldwork offsets,
waits for the vehicle to stop, and checks the route before installing it. Checks
include the current-pose approach, every edge, both endpoints, rotation and the
appended work-entry section. Native mounted-body/header dimensions are expanded
by 0.5 m on both axes; samples are at most 0.25 m of corner displacement apart.
This is a physical obstacle check, not the discarded circular field-boundary
veto. A towed body is rejected rather than approximated as a rigid attachment.

Braking motion, pose changes or altered fieldwork offsets discard a partial
scan. Cancellation, deletion and stale last-waypoint callbacks cannot install
an unchecked course. A rejected candidate tries the original connector through
the same gate; if that is also obstructed, CP stops with its no-path message.
No unchecked fallback is driven. Validation uses native collision filtering
and a shared maximum of 32 queries or 2 ms per frame, whichever is reached first;
one engine query itself cannot be interrupted. It does not accumulate pathfinder
debug boxes. Native route generation, crop costs, unloading, turns and tractor
implement entry remain unchanged. This gate does not generate an alternative
route, and moving obstacles or steering deviations remain the responsibility
of live collision detection.

Nineteen engine-boundary regressions exercise real Course/StartRowOnly code,
native offset application and AI-marker footprint construction. They cover
header-only collisions, obstacles between waypoints and in the appended entry,
corner sweep, reversing, valid field-edge clearance, checked fallback, exhausted
retries, frame budgets, braking, offset changes and cancellation. Release checks
run them against source and the extracted ZIP, alongside native parity and the
existing queue/implement suites. These checks establish the acceptance gate;
the tree-edge journey and header tracking still require validation in FS25.

### Build 3004: staged departure and queue turn geometry

The 5 October session still loaded build 3002. All four full trailers entered
QUEUE_EXIT without a successful departure or AD handover through 17:29:59:
/325 at 16:22:41, /322 at 16:34:16, /324 at 16:43:30 and /323 at 17:00:38.
The repeated failures were invalid destinations (standing crop, field boundary
or outside the exit corridor), missing connected targets and exhausted searches.
There was no Lua error in that trace. This was not an AD delivery failure:
CP had not released the trailers to AD.

Code review and complete-journey regressions established several defects:

- The queue interpolated heading changes with reversed arguments to the shared
  angle-difference helper, rotating simulated bodies away from the desired
  heading and falsely rejecting bends on articulation limits. Straight-only
  route tests did not detect this. Only the queue caller is corrected.
- A direct candidate aligned the tractor but did not reserve a straight run-in
  to align its trailer. Queue direct searches now include a run-in based on the
  towing chain; the same whole-train acceptance checks remain mandatory.
- Departure targeted a distant AD point in one search, rather than returning
  along the harvested row and travelling around the headland. Short searched
  legs now provide row return, tangent headland entry, perimeter transit and
  the final AD approach. A small cached junction graph links separate headland
  bands while retaining their curved polylines. Every driven leg still passes
  live crop, field, obstacle and articulation checks, including detours.
- Multitool departure geometry omitted the other lanes' headlands. All lane
  geometries are now available as candidates, preserving offsets even for
  inactive, unenriched waypoints. Live crop checks must still prove those lanes
  have been harvested; the combine courses are neither switched nor modified.
- The original fallback ignored rejected and reserved targets. All stages now
  honour them. Final AD approach poses must accommodate the complete train on
  the headland, rather than placing the tractor at an arbitrary crop-edge node.
- The build 3001 timeout still counted selected game-frame duration, so slower
  frame rates reduced useful search work. Build 3004 charges measured advance
  computation against the 15-second work budget instead. The shared 2 ms slice,
  native-search priority and 6,000-expansion bound remain in force.

Intermediate stages cannot trigger handover. CP retains control until the
existing final gate verifies the whole train on harvested headland, a connected
directed AD delivery route, compatible heading and clear local connection.
Unsupported or obstructed departures still wait safely. No AD code, installed
ZIP, native combine route or native unloading approach is changed. Exit logs
now identify the stage, target coordinates and heading for future diagnosis.

Fifteen added engine-boundary tests include complete row-to-AD journeys, the
normal Q.tick lifecycle, a loaded rig turning back from the pipe side, turns in
both directions, a vehicle detour, a cropped-interior perimeter journey across
split bands, a short headland, rejected/reserved targets, multitool offsets and
equal computation allowances at different frame intervals. They use production
route and articulated geometry code with mocked crop/collision engine queries;
they do not simulate GIANTS driving physics. Source and extracted-ZIP checks
include these and the existing suites. Build 3003's connector fix is retained.
The actual four-trailer departure and AD delivery still require an FS25 retest.

### Build 3005: correct the connector gate's traffic and footprint regression

The 7 October session loaded 3004. At 09:50:12 CR11/319's native search
succeeded, but the added 3003 clearance gate rejected waypoint 1 on T7.300/322.
It then rejected the original connector at waypoint 22 on an FD250 header and
stopped the worker. At 09:52:30 it also rejected CR11/318's fallback at waypoint
1 on a header and stopped that worker. These records identify the added gate
as the cause of the no-path stops; they do not establish a collision hazard.
The 3004 trailer-departure changes were not the cause of these stops.

The gate incorrectly treated current vehicle occupancy anywhere along a long
route as a permanent obstruction. It also checked only a combined rectangle,
filling the empty space beside the chassis out to the header's full width.
The earlier tests exercised static obstacles but omitted other vehicles and
treated this oversized rectangle as correct. That coverage was insufficient.

The corrected gate leaves vehicle traffic to native live proximity and convoy
control, which both execute in DRIVING_TO_WORK_START_WAYPOINT. Only this gate's
detector discards a newly counted collision with an object whose root vehicle
is confirmed. Native detectors remain unchanged. Unmapped shapes, trees,
bales and grain heaps remain subject to scenery clearance. The chassis and
mounted implements now have separate buffered rectangles, using direct extent
differences so a header wholly ahead of the chassis is not stretched backwards.
Every body is swept; one overlap query per step retains the shared 32-query /
2 ms frame allowance. Static obstruction fallback and lifecycle guards remain.

Seven additional regressions cover a nearby tractor, a distant combine header,
unchanged native collision detection, mixed traffic/scenery callback ordering,
own-header and trigger filtering, unknown objects, bales/heaps and bare terrain,
and native driving's traffic/convoy stop-and-resume dispatch. Updated geometry
and frame-budget tests cover separate bodies and the empty chassis-side space.
The 26 connector tests use production Lua with mocked engine boundaries; they
do not recreate GIANTS vehicle physics or prove the complete save's journey.
Native route generation, crop fallback, convoy policy and unloading are not
altered by this correction. The two-combine headland-to-centre transition still
requires an in-game retest.

### Build 3006: restore native harvester connector ownership

The 7 October build 3005 run confirms the first combine (/319) passed the gate
at 14:11:48. The second (/318) exhausted its native searches, then the added
gate rejected the original connector at waypoint 84 (-250, -232) on static
shape 123366 at 14:14:14. It stopped the worker before that connector was driven.
Native CP would instead have started its original connecting-path fallback.
This stop was caused by the branch's extra veto, not the trailer or the combine
waiting for its partner.

Following the user's requirement that the established native transition works
in this save, the added CpHarvesterRouteClearance module is removed completely,
including its load entry and release exemption. No replacement search or
recovery system is introduced. Both successful searches and failed-search
fallbacks now use the unchanged native fieldwork strategy and StartRowOnly.
Native crop-aware route selection, necessary crop crossings, collision sensing
and convoy handling retain ownership. The queue, earlier authorised lookahead
adjustment and harvester turn-boundary correction are retained.

This withdraws the extra static tree-clearance gate introduced in 3003 as well
as its later corrections. Tree/edge handling therefore returns to native CP;
this build does not claim to solve the earlier tree-edge incident with another
custom route rule. The deleted gate's tests remain in Git history. Replacement
regressions verify native strategy parity, absence of connector overrides,
successful route handoff, exhausted-search and invalid-goal fallback, native
retry dispatch, and live traffic/convoy stop-and-resume dispatch. All release
checks still run for source and packaged ZIP. These engine-boundary tests do
not prove vehicle movement in FS25; the two-combine transition needs retesting.

### Build 3007: allow preparation from the waiting verge and ahead of connectors

The 7 October 3006 run rejected T7.300/322's preparation at 16:43:30 because
its saved start marker was 39.2 m away, beyond the 22.9 m entry allowance.
It remained unprepared until the native call at 16:49:38, roughly 560 m from
the rendezvous. CR11/318 passed its 80% trigger at 16:50:18. The trailer missed
the first rendezvous, replanned and began unloading at 16:51:42. This was a
late preparation failure with subsequent recovery, not a permanent unload stop.

Preparation now admits a bounded connection from the actual rig to the nearest
edge of its serving field, whether the saved start marker is distant or absent.
The existing 100 m field-distance limit remains. Every swept tractor/trailer
body must still pass crop, island, obstacle and articulation checks. The entry
allowance remains exclusive to preparation; exit and yielding cannot use it.

During native travel to the next work start, preparation now references CP's
already selected row-entry waypoint instead of the last passed headland point.
The normal lag and target validation still apply. Actual departure capture and
other harvester states retain their original position reference. No combine
course, unload trigger, readiness check or native approach is changed.

New engine-boundary regressions drive the real articulated route search from
the verge with distant and absent markers, reject remote entry, check crop,
island and obstacle protection, and exclude exit/yield from the allowance.
They also verify upcoming-row preparation, unchanged native course and actual
departure position, and fallback for other states or invalid/missing context.
The complete runtime suite has 76 tests. These tests mock GIANTS engine queries;
timely physical arrival and the full save still require an in-game retest.

The separate crop-crossing report was traced without another harvester route
patch. CR11/318 exhausted its first 40,000-iteration search, then accepted a
492.3 m native retry route at 16:47:24, before the 9 m straight entry extension.
The connector search and crop-cost behaviour match local upstream/main
150dcd51. Native crop avoidance is a cost preference, not a requirement that
another combine must block the headland. Candidate collision records do not
prove the suggested alternative headland routes were blocked, and the log does
not establish that this crop crossing was necessary.

### Build 3008: complete row departure before attempting the headland turn

The current 7 October log still loads build 3006. At 18:34 all four full
trailers remain in QUEUE_EXIT, with no completed handover: /324 retries row
return after native traffic backup displaced it outside the saved corridor;
/323 also fails row return; /325 and /322 reached headland entry but repeatedly
exhausted searches there. CR11/319 waits for an available unloader and /318 is
held by native convoy spacing, 41.2 m behind against its 75 m requirement.
Build 3007's preparation fixes did not address these departure failures.

The exit planner switched from row return to a headland turn with up to 50 m
of the row still ahead. With the actual saved 15.2 m course and both headland
bands, the /325 target (-38.31, -971.91, heading 75.66 degrees) reproduces a
direct route that turns diagonally out of the permitted corridor. Moving
straight closer to the headland first produces a valid direct route. A new
row-approach stage places that turn using the headland distance, tractor turn
radius and front overhang, instead of treating the 50 m leg length as an entry
threshold. CP's combine routes and unloading controller remain unchanged.

The departure corridor also admits a bounded re-entry from the actual rig
after native reverse/traffic clearance, provided it is still near its saved
row. It is frozen for each search and checked with the same live crop,
field-boundary, island, obstacle and articulated-body checks. Explicit links
between row-start and headland bands close a separate narrow-width gap found
in the generic regression; the actual two-band save does not have that gap.
No crop or vehicle checks are waived and no midfield AD handover is enabled.

Tests now include the recorded headland coordinates, the actual 9 m tractor
turn-radius setting, a 15.2 m complete departure, traffic-clearance re-entry,
crop/obstacle rejection, and a complete journey through the real queue hook
to native onTrailerFull/stopCurrentAIJob. The saved AD graph has directed
connections to the configured Old Mill Grain destination; its API and marker
configuration are compatible. Reaching a headland entry still requires onward
transit and heading alignment before handover, particularly where the closest
AD node is outside 20 m or points the opposite way. Completion now logs the
validated native handover explicitly. Headland entry now prefers a nearby
connected lane/direction among eight geometrically suitable entry candidates.
Once the actual rig passes the existing complete handover gate, Q.tick invokes
native handover before requesting another parking pose.

The complete tick-driven regression includes both ends of this saved field,
recorded headland and AD network coordinates, and verified directed paths to
the saved delivery waypoint. Its field edge is explicitly an estimate from
the outer headland, and AD route results are derived from the saved directed
graph; they are not a live AD simulation. Separate tests enforce crop and
obstacle rejection and exercise the native full-job hook. Engine queries and
driving physics remain mocked; the four-trailer FS25 departure still needs
in-game validation. The route-search algorithm, its shared CPU allowance, AD
code and native combine behaviour are unchanged by this build.

## Packaging

Retain `FS25_Courseplay_UnloaderCoordinatorTest.zip` and
`CoursePlay - Unloader Coordinator Test` so existing settings and mod identity
remain stable. Never replace the live `FS25_Courseplay.zip` or the installed mod
as part of building. Keep numbered history and a receipt identifying the
source revision, baseline, feature stage and checksum.


### Build 3009: checked local entry onto a harvester connector

The 7 October 20:26�20:28 build-3008 trace showed CR11/318 spending about
76 seconds on two unsuccessful 40,000-iteration searches. The saved connector
then started 14.7 m sideways from the combine, facing approximately the opposite
direction. Native fallback followed that displaced connector without constructing
an initial U-turn; the combine subsequently stopped near T7.300/322. This does
not establish that the tractor had to move or that all alternative routes were blocked.

This explicitly authorised connector-entry correction is separate from queue
scheduling. Self-propelled harvesters without a trailing steering length first
search for a forward local entry onto the first section of the existing connector.
Up to three nearby targets use the native planner, collision mask, attached-header
envelope, turning radius and crop preference, with 3,000 iterations per attempt.
An exact analytic finish replaces the tolerant end of the local search. The local
manoeuvre and join are checked at no more than 0.4 m or 2 degree intervals, with
20 overlap checks per update. Local entries exceeding the configured fruit
limit are rejected; native full-route search retains the decision about necessary
crop travel. The original connector is copied; its remaining
route, live traffic/convoy controls and native final straight-row entry remain in use.

If local entries fail, the native full-destination search remains available once.
If that also fails, the worker holds and retries local entries after a delay instead
of starting an unchecked displaced connector. This path never disables collisions.
Non-harvesters and harvesters towing steering-length implements retain their native
connector dispatch. No AutoDrive or queue-yield behaviour changes are included.

Regression coverage runs real native JPS/hybrid search, constraints, collision
filtering, Course and StartRowOnly. It uses the recorded start pose and initial
connector coordinates, a logged 16.6 by 13 m combined envelope and representative
stationary verge tractor/trailer rectangles. Engine transforms and overlap queries
are planar adapters; this is not a replay of all live map scenery or vehicle physics.
Additional cases cover header-only obstruction, failed-search hold/retry, short
connectors, heading wrap, the final join geometry and preserved straight entry.
The release parity gate permits only the three reviewed connector-entry blocks;
all other fieldwork strategy code must still match the pinned main baseline.
Actual steering and timing still require the user's in-game validation.


### Build 3010: yielding from a queue position on the verge

The 7 October build-3009 log records CR11/318 repeatedly blocked by T7.300/324
at 1.3 m from 21:34. After the tractor restart, a later request from CR11/319
produced `QUEUE_YIELD: start: field boundary (root 67.3, -732.7; not preparing)`
at 21:38:09.562. Preparation admitted a bounded verge connection; yielding
rejected the same starting position before searching. Yield now admits that
same bounded connection, retaining standing-crop, island, obstacle and
articulation checks. Exit/handover permissions are unchanged.

Yield clearance now reads the current native PPC course and the actual
combine/header envelope over a bounded 30 m horizon, instead of a fixed strip
straight ahead. Sampling bounds corner travel, and unavailable geometry does
not certify clearance. Native proximity and the whole tractor/trailer must
both be clear for two seconds before resuming preparation or the interrupted
departure. Requests from multiple harvesters remain active independently;
repeated requests do not restart a valid escape search. A combine safely
passing on its existing route can clear the request without a new tractor move.
No combine route, crop permission, unloading trigger or AD API is changed.

Like native move-away control, yield does not stop on a prospective traffic
warning about the route it is clearing. Native proximity and live whole-train
collision validation remain active. The choice set includes lateral quarter
turns as well as forward passes and straight reversing, ranked by full-train
clearance time. Queue transitions now preserve an interrupted departure and
recheck live clearance after reaching a previously planned target.

The new regression suite exercises native blocking-request dispatch, repeated
requests, multiple harvesters, verge-start searches, header-only turn conflicts,
reverse headings, whole-trailer clearance, safe harvester passes, failed escapes,
departure resumption and forward clearance beating slower reverse travel. The
journey uses production search/geometry with planar engine transforms, crop
queries and combine/header overlap adapters; it is not full FS25 physics or
an exact replay of every object at the recorded position. Source and packaged
runtime checks are required; in-game movement still needs validation.


### Build 3011: configured departure cutoff and prompt local exit choices

The 7 October build-3009 log records T7.300/323 entering QUEUE_EXIT at
22:08:12.647 and receiving its first exit course at 22:13:09.371. T7.300/325
and /324 each exhausted the first row-target search after about eleven
minutes before trying another target. These are elapsed route-search delays,
not measured frame times. The log also records /325 invoking the native full
trailer handover at 21:49:36.575; it does not establish an accepted AD delivery,
field departure or completed emptying trip.

At the user's explicit request, the configured Empty when over percentage
is enforced inclusively throughout this queue mode. At or above 85%, for
example, a trailer cannot accept another combine call or remain preparing.
Native transfer logic uses the same threshold and retains release and reverse
clearance before row departure. Explicit fullness arguments are unchanged.
Auger wagons, field unloading and GIANTS unloading retain native behaviour.
This is a narrow authorised unloading-threshold hook; native method bodies,
harvester routes, readiness, pipe following and crop protection remain intact.

Row departure tries the existing 50, 35 and 65 metre local targets with direct
validated paths before beginning an obstacle search. All candidates retain
the harvested exit corridor and whole-train crop, collision and articulation
checks. The actual chosen goal follows the path through completion. Searches
prioritise yielding, then departure, then preparation, rotating within each
priority and retaining the shared 2 ms per-update allowance and native
foreground precedence. Active departure/yield attempts have a 1,000 ms
accumulated computation ceiling; preparation retains 15,000 ms. Neither is a
wall-clock deadline. Failed attempts hold under CP control and retry alternative
targets; no unchecked route or midfield AD handover is introduced.

Regressions cover below/exact/above cutoff, configurable percentages, native
fullness calculation and reverse-clearance dispatch, idle timer bypass,
preparation/yield transitions, call admission, capacity limits and other modes.
Real articulated route tests cover a failed short direct arc followed by a
safe longer option without hybrid expansion, corridor propagation, selected
goal identity, departure scheduling and complete row/headland handover journeys.
Engine queries remain test adapters, not a full FS25 physics replay. Actual
field departure, AD delivery and frame-rate improvement require in-game
validation. Departure logs now distinguish measured computation from elapsed
search time and record the starting pose and candidate count.

The later live log records T7.300/325 reaching its headland-entry target
(-181.4, -1000.1), heading 270 degrees, at 22:28:56, then repeatedly reporting
no connected route. The initial fixture reproduction exposed missing routes
for nodes outside the two older fixture neighbourhoods; it is not proof that
the live run rejected exactly the same candidates. The graph adapter now
calculates a directed-distance route for every retained reachable node. It
still does not simulate AutoDrive's turn restrictions or routing preferences.

The selector's fixed nearest-16 limit can independently hide a valid later
stage on every retry. It now resumes through successive candidate batches,
capped at eight candidates or 2 ms between candidates, retrying after 200 ms
while incomplete. Cached geometry is invalidated by movement, destination or
departure changes and cancellation. Route connectivity, temporary bans and
stage availability remain live checks. A separate regression verifies that
a valid 28th candidate is reached with both count and time slicing.

A second handover restriction staged the rig directly on an AD node at a
headland edge, then added the complete turning radius to all four sides of
the short connector envelope. On a 15.2 m harvested headland this can reject
a clear actual-width connection. Eligible nodes now project to the harvested
lane centre for CP staging. The handover gate retains whole-train harvested
headland occupancy, live crop/collision checks, connected AD routing, range
and heading, and actual-width translated body envelopes. It omits the blanket
radius margin; AD owns subsequent steering and its manoeuvre is not simulated.
A narrow-headland regression accepts the clear connection and rejects crop
inside the actual swept corridor. The existing recorded-geometry journey also
includes the newer logged headland-entry pose; live scenery/physics and AD's
complete delivery still require in-game acceptance.


### Build 3012: reversing-turn yield clearance and return to aligned parking

The 8 October 3011 run shows CR11/318 blocked by T7.300/325 at 12:38:10.677.
The tractor starts yielding at 12:38:21.647. T7.300/324 approaches CR11/319,
then reverses away from /325 at 12:39:46.852 and becomes /318's blocker. Both
tractors subsequently remain in QUEUE_YIELD with harvester clearance unavailable.
The second combine waits 39.2 m behind the first under native 75 m convoy spacing.
These are interrupted yield/approach positions, not completed queue parking.

Three new real-Course regressions fail against 3011: forward/reverse cusps
create phantom body rotations, multiple cusps exhaust the envelope limit, and
a dense straight course exhausts that limit solely through waypoint count.
Course waypoint yaw describes the outgoing segment, so the yielding adapter
must use Course's direction-switch convention when deriving physical heading.
Sampling now carries its accumulated corner-travel allowance across waypoints,
rather than forcing a new sample for every point. One-metre corner-travel gaps
remain covered by one-metre rectangle padding. The 30 m horizon and 160-sample
fail-closed ceiling are unchanged; crop, collision and native proximity checks
remain in force. No combine course or convoy spacing is modified.

The old all-reverse test did not cover direction switches, and sparse route
fixtures missed waypoint-density dependence. Coverage now includes both cusps,
multiple direction changes, dense straight and curved courses, header corners
between samples, genuine excessive-sweep rejection and a full validated yield
journey followed by selection/driving of a straight headland parking slot, with
both tractor and trailer aligned. Missing body geometry and exhausted sample
limits now have separate reasons, and the generic no-destination message no
longer alternates with the specific yield failure every 200 ms.

The live log's old generic message cannot retrospectively distinguish a body
geometry failure from sample exhaustion. These tests reproduce concrete code
defects consistent with the observed reversing-turn deadlock, not every live
vehicle transform or map collision. Full in-game recovery remains to be verified.
