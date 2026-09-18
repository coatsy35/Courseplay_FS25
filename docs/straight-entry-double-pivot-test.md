# Straight Entry + Loop Test v0.14

ZIP identity: `FS25_Courseplay_StraightEntryTest.zip`.
In-game title: `CoursePlay - Straight Entry + Loop Test v0.14`.
Manifest version: `8.1.0.302`.

This local test merges straight-entry v0.13 at `7aad509b` with the main-based
double-pivot headland-loop work. It lives on
`codex/double-pivot-straight-entry-local`; neither source branch is modified.

The v0.13 short-headland handover fix prevents CP from skipping a pending corner
when the Quadtrac has already passed the short incoming headland section. All
earlier straight-entry and field-corridor work in that branch is included.

For forward loop turns on headland corners, supported serial wheeled chains use
separate hitch and axle geometry, detected body/working width, articulation,
settling and field-boundary checks. The captured Seed Hawk 84 / PD 1000 contains
an internal drawbar yaw pivot, so it deliberately uses the width fallback. With
the captured 25.6 m width its base loop radius is at least 13.3 m. The fallback
retains v0.13's alternative pull-ahead and approach placements, but stops with
CP's no-path message rather than accepting an unchecked pathfinder route when
none fits.

CP's configured driving speeds are retained. This is a planar planning test,
not proof of physical drill/cart clearance. Keep collision detection enabled and
inspect the actual hitch motion during the first turn.

The release gate runs 36 straight-entry regressions, 14 loop regressions, six
packaging tests, runtime Lua compilation, deterministic source packaging and
both suites again against the extracted ZIP. The numbered archive and stable
copy are written only under `dist/straight-entry-double-pivot`; existing test
build folders and the live `FS25_Courseplay.zip` are untouched.
