# Combine corner pocket

Test build 006 uses version `8.1.0.323`, filename
`FS25_Courseplay_CombinePocketTest.zip` and the in-game title
`CoursePlay - Combine Pocket Test`.

On the outermost headland, the combine's square-corner pocket now places its
second forward cut one complete working width inside the first cut. This keeps
the second straw swath on a working lane rather than between two lanes.

At each of the pocket's two forward-to-reverse changes, the header is raised
and the combine remains stationary while its straw discharge is active. It
starts reversing as soon as the combine reports that discharge has finished;
there is no fixed delay. Combines which are not dropping a straw swath retain
the existing direction-change timing.

The change is confined to the existing combine pocket manoeuvre. Ordinary
combine turns, other fieldwork turns, turn speeds, reverse distances and the
existing no-field fallback are unchanged.

Automated coverage checks the full-width pocket coordinates and both straw
discharge waits. The normal catalogue, implement-profile, straight-entry,
multi-pivot and packaged-runtime release checks remain mandatory. Live testing
should confirm both swaths finish cleanly and the second swath aligns with the
next working pass at a square outer-headland corner.
