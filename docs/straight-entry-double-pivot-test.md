# Straight Entry + Loop Test v0.15

ZIP identity: `FS25_Courseplay_StraightEntryTest.zip`.
In-game title: `CoursePlay - Straight Entry + Loop Test v0.15`.
Manifest version: `8.1.0.303`.

This local test merges straight-entry v0.13 at `7aad509b` with the main-based
double-pivot headland-loop work. It lives on
`codex/double-pivot-straight-entry-local`; neither source branch is modified.

The v0.13 short-headland handover fix prevents CP from skipping a pending corner
when the Quadtrac has already passed the short incoming headland section. All
earlier straight-entry and field-corridor work in that branch is included.

For forward loop turns on headland corners, supported serial wheeled chains use
separate hitch and axle geometry, detected body/working width, articulation,
settling and field-boundary checks. The captured Seed Hawk 84 / PD 1000 drawbar
is now split into approximately 3.78 m and 4.31 m internal links. Candidate loops
check both internal articulation angles, non-adjacent physical bodies and every
modelled working footprint against CP's field polygon. This case stops with CP's
no-path message if the field boundary is unavailable or no safe candidate fits.
The accepted chain route does not apply the old moving 9.7 m tow-bar offset.

CP's configured driving speeds are retained. This is a planar planning test,
not proof of physical drill/cart clearance. Keep collision detection enabled and
inspect the actual hitch motion during the first turn.

The release gate runs 36 straight-entry regressions, 17 loop regressions, six
packaging tests, runtime Lua compilation, deterministic source packaging and
both suites again against the extracted ZIP. The numbered archive and stable
copy are written only under `dist/straight-entry-double-pivot`; existing test
build folders and the live `FS25_Courseplay.zip` are untouched.
