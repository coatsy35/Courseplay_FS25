# Unloader queue branch

- Use concise British English.
- Follow the scope contract in `docs/unloader-queue.md`. Preserve native CP's
  crop protection, combine behaviour and unloading ownership.
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
