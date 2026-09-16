# v0.29 qualification

Test mod: `FS25_Courseplay_EnvelopeTurnsTest.zip`, version `8.1.0.129`.

## Fault and correction

The v0.28 live log selects the closest waypoint in the correct direction,
waypoint 132, then applies an experimental outward target 112.44 m behind it.
Repeated starts request the same unnecessary detour. CP selected the waypoint
correctly; the experimental new-entry policy was incorrectly applied to resume.

All three start modes now use stock CP startup behaviour. The transport strategy
is restored verbatim to the existing CP base; fieldwork start and alignment
methods are restored too. The unused experimental initial-entry controller and
outward-target/slope helpers have been removed from the source and manifest.
Row-end envelope turn selection, alignment checks and CP speeds are unchanged.

## Validation

- Stock transport source and five fieldwork entry methods match the local CP base.
- All 91 regression tests pass; results: `out/v029-final-regressions.txt`.
- All 43 packaged execution cases pass with handover and at least 8 m of work.
- Packaged Lua/source matching and ZIP integrity pass.

ZIP SHA-256: `3018a33155fda81f05e04e1b78cb8dc6becd82db73b18a1dc7d673ebd3846eea`.

Regressions execute the production transport-start, fieldwork-start and waypoint
selection methods for first, nearest and last. Nearby starts request neither an
outward route nor a forced alignment loop. CP retains its own first index,
remembered index and nearest waypoint in the correct direction.
Tests for the removed experimental startup policy were removed; row-turn,
containment, planner failure and handover checks remain. Five packaged cases
specific to the removed outward initial target were retired.

These are production-Lua checks with mocked game services and planar dynamics.
They do not certify GIANTS physics. Initial offset measurement remains separate.
The scheduled log monitor remains paused as requested.
