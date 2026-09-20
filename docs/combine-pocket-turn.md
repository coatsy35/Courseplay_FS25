# Combine corner pocket

Test build 008 uses version `8.1.0.325`, filename
`FS25_Courseplay_CombinePocketTest.zip` and the in-game title
`CoursePlay - Combine Pocket Test`.

On the outermost headland, the combine's square-corner pocket retains the stock
Courseplay waypoint proportions while scaling the complete pocket geometry so
the stock 70% lateral leg equals exactly one generated headland lane spacing:
the working width less the configured headland overlap. This avoids the
1.4-width lateral move produced by simply doubling the stock offset, without
steepening the stock reverse or pocket-entry angles. The second straw swath now
sits on the next headland pass rather than between two lanes.

At each of the pocket's two forward-to-reverse changes, the header is raised
and the combine remains stationary while its straw discharge is active. It
starts reversing as soon as the combine reports that discharge has finished;
there is no fixed delay. Combines which are not dropping a straw swath retain
the existing direction-change timing.

The change is confined to the existing combine pocket manoeuvre. Ordinary
combine turns, other fieldwork turns, turn speeds, reverse distances and the
existing no-field fallback are unchanged.

Automated coverage checks the overlap-adjusted pocket coordinates and both
straw discharge waits. The normal catalogue, implement-profile, straight-entry,
multi-pivot and packaged-runtime release checks remain mandatory. Live testing
should confirm both swaths finish cleanly and the second swath aligns with the
next headland pass at a square outer-headland corner.
