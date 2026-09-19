# Course-specific headland loop turns

Branch: `codex/course-headland-loop-setting`, based on main `00a5216b`.

**Loop turn on headland** is now under **Course generation > Fieldwork Settings > Headland**,
beside the rounded-corner setting. It is available without expert mode and removed from the
vehicle page. This selects driving behaviour; it does not regenerate or alter course waypoints.

Implement profiles still supply the working preference. Generate a course using that preference,
or adjust it with a course loaded. Saving the course records the choice. Loading a saved course
restores its explicit on/off value, including on another tractor. Applying a different profile
can change the current working choice; neither action updates a saved library profile. Save the
course again to retain later adjustments in its library file.

Older courses without this attribute adopt the current fieldwork value when loaded. The next save
records it. Course copies, the course editor, assigned courses in savegames and multiplayer course
streams retain the attribute. The existing vehicle-setting storage/profile key is retained solely
for compatibility and as the active working value used by all existing turn manoeuvres.

The Headland section remains accessible for loaded headland courses even when the generation
headland count is zero. This does not change the generation count or its validation.

## Verification

Run `python tools/course-headland-loop/build_test.py --output <output-directory>` with Python,
Lupa and lxml installed. The release gate runs packaging/translation checks, implement profile
tests, course preference tests, straight-entry and headland-loop regressions. It builds twice for
reproducibility, checks the packaged bytes and tests the extracted runtime before publishing.

Test build 001 uses version `8.1.0.318`, filename `FS25_Courseplay_ImplementProfilesTest.zip` and
title `CoursePlay - Implement Profiles Test`. The live manifest and live ZIP remain separate.

In FS25, check the visible row and controller navigation; save two courses with opposite choices,
load each on another tractor and drive a sharp headland corner. Repeat savegame reload and a
host/client course transfer. Automated boundary tests do not establish in-game rendering or physics.
