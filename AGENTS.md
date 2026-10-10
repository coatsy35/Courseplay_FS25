# Unloader queue branch

- Use concise British English.
- Follow the scope contract in `docs/unloader-queue.md`. Preserve native CP's
  crop protection, combine behaviour and unloading ownership.
- The agreed behaviour is staged preparation: clear the AD arrival/exit point,
  park on harvested ground roughly partway towards the assigned harvester,
  then advance to nearer waiting positions as it fills. Roughly halfway is a
  suggested initial position, not a fixed geometric requirement. Park and wait
  between stages; do not implement continuous following or chasing.
- Aim to have the lead trailer about 30 yards (27 metres) behind before the
  harvester's configured CP unloading trigger, allowing for travel and alignment.
  Native CP still controls the final approach, crop checks and unloading.
- Every staging position, including initial, closer and replacement positions,
  must straighten the complete tractor/trailer rig parallel to the local outer
  field boundary on a headland, or aligned with the centre rows within the field.
  Keep AD access, departure routes and combine turning areas clear.
- During loading, anticipate whether the current trailer can take the remaining
  load. Bring a compatible replacement closer before capacity runs out when
  needed, ready for a prompt native CP changeover. Preserve existing reservations
  and partial-load priorities; do not dispatch duplicates.
- Apply preparation to all supported harvesters, including forage harvesters.
  Continuous-output harvesters need service/replacement timing rather than an
  assumed grain-tank percentage. Participation remains automatic, with no opt-in.
- Preserve each tractor's adjustable CP departure threshold and native departure
  and AD handover. Do not hard-code 80% or 85%, change combine courses, or weaken
  crop/collision protections to achieve preparation targets.
- Preserve build 3020 (commit 28b1bd6a8c19f04e4905bb21b997839788a74a00) as the
  user's currently working traffic/unloading baseline. Implement subsequent
  preparation changes as separate commits/builds; retain its ZIP unchanged.
  The staged-preparation requirements are not yet verified as working in 3020.
- Retain `FS25_Courseplay_UnloaderCoordinatorTest.zip` and the in-game title
  `CoursePlay - Unloader Coordinator Test` for this feature. Keep the live ZIP
  separate. Every release needs a new commit and its own full-commit-SHA folder
  under `dist/unloader-coordinator/history` in the repository root, retaining
  the same ZIP filename. Record the numbered version and commit in build.json.
  Preserve previous releases and legacy version folders.
- Run release checks before publishing each changed build. Fix failing checks;
  do not bypass them. Provide a direct link to the numbered ZIP.
- Build 2990 is a clean main baseline, not an implemented queue feature. Never
  describe baseline parity or mocked tests as successful in-game acceptance.
- Preserve the archive checkout and builds. Do not cherry-pick its runtime
  changes without independent evidence that they belong within the new scope.
- Use at most two narrowly scoped read-only subagents when independent
  investigation materially helps. The lead owns edits, integration and release.
