# Implement straight entry and turn recovery

Merged from `codex/implement-straight-entry-and-turn-recovery`, tested candidate
v0.21 (`d41615ac`), into main after the implement-profile update (`fac1f1c2`).

## What changes and why

- Extend and shape the turn approach so a trailed implement has room to align
  before working. Mounted tools use a shorter approach. Speeds remain tied to
  CP settings rather than fixed experimental speeds.
- Check entry and finishing paths against the field boundary so an extended
  approach does not blindly lead the tractor out of the field.
- Lift and centre a plough before obstacle recovery; wait for drawbar alignment
  before turning it back to its working position. The working frame can be
  angled by design, so the check uses the actual drawbar pivot components.
- Follow the saved headland when finishing a recovery on a curved pass, and
  preserve pending short corners instead of skipping them during handover.
- Account for supported multiple-pivot implement chains when checking forward
  headland loops, including articulation and body clearance estimates.
- Connect the final centre row straight ahead to its assigned headland where
  possible, including each offset lane of multi-vehicle courses. Invalid forward
  intersections and island connections retain the established fallback.

## Integration with main

Main's implement profiles and correct-side plough rotation are retained. Entry
readiness checks the requested working side as well as animation completion:
an opposite endpoint cannot allow lowering while drawbar alignment delays
turnover. The straight-entry fixtures now use main's animation convention
(left endpoint 1, right endpoint 0), with a combined regression for this case.

Source manifest version is `8.1.0.27`, with the normal translated CoursePlay
titles. Historical candidate archives and their branch remain available.
No changes from `codex/turnbench` are merged; existing bench files on main are
unchanged. The straight-entry and loop regression tools accompany their runtime
code, but are excluded from installable ZIPs.

## Validation and use

Validate the combined straight-entry, loop, plough-side and implement-profile
suites, packaging and translations. Re-run entry and loop regressions against
the extracted ZIP before delivery. These checks exercise planar geometry and
engine boundaries; they do not replace in-game clearance testing.

Regenerate saved courses for the final-row connection changes. Controller and
recovery changes apply to existing courses. Existing fallback, collision and
no-path checks remain active.

## In-game checks for the plough-course project

- Start and resume a plough course with each working side selected, including
  a plough initially at the opposite endpoint. Confirm turnover completes on
  the requested side before lowering.
- Alternate left/right row turns and clockwise/counter-clockwise headlands;
  verify the furrow side, automatic offset and finished coverage remain correct.
- Save and reload a course and check its first-row orientation and boundary
  flags. `Course.lua` and `AIDriveStrategyPlowCourse.lua` are unchanged from main.
- Repeat the PW100 obstacle recovery and a tight corner, checking lift/centre,
  drawbar clearance, turnover timing and subsequent lowering. Stricter alignment
  can delay rotation, so check short approaches particularly closely.
- Check first/nearest/last startup, mounted equipment, pikes and the final
  centre-to-headland transition. Regenerate a multi-vehicle course to inspect
  each vehicle's forward connection.

The shared controller, turn preparation, boundary checks and final connection
geometry can affect plough-course operation even though side selection and
course serialization are preserved. The 26 plough-course regressions and 61
implement-profile regressions pass alongside 52 straight-entry, 17 loop and
eight packaging/translation tests.
