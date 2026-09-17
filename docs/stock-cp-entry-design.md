# Stock CP implement-entry redesign

## Starting point

Branch: `codex/stock-cp-implement-entry`.
Parent: repository `origin/main`, commit
`9b915b074961464c0b23227956afee2a47edb0d8`.
Its runtime scripts, configuration and mod manifest match upstream main at
`150dcd51f8a108ffc86e95df3e3e240bcc80b6df`; the difference is build workflows.
No envelope-planner runtime, settings, hooks or test code is inherited.

The previous experiment is archived on `codex/implement-envelope-ingame`,
commit `2ae38522`, with `docs/envelope-experiment-handover.md`. It remains
available for captured geometry, recorded failures and comparison. Its 124
passing regressions and 112 packaged cases did not establish game reliability.
Do not present that branch or a plain-stock build as this replacement.

## Intended behaviour

Keep stock CP responsible for turn selection, route following, configured
speeds, reverse control, vehicle configuration and First/Last/Nearest selection.
Add an implement-entry controller that provides sufficient approach room and
uses current measured alignment before unfolding, turnover, lowering and work
handover. The controller must distinguish those operations; a path being found
is not permission to deploy or lower.

The user observes that an ordinary stock turn almost straightens the trailed
implement, but starts returning towards the row before travelling far enough
across. Investigate the placement of that return curve first. Provide room to
settle before the working edge reaches the row; extending the course further
into unworked ground does not achieve that. On pikes, preserve stock CP's
outward turn placement and consider travelling further out before returning.
The shape is unrestricted: lateral travel of around 20 metres is acceptable
where space permits, but is not a fixed offset to impose on every combination.
Practical alignment tolerances are required, not centimetre-perfect tracking.

See `stock-cp-turn-review.md` for the clean-main source review and the distinction
between confirmed code behaviour and the proposed explanation of the observation.

Represent the complete attachment structure explicitly: vehicle articulation,
attachment pivots, internal implement pivots, mounted tools and declared wheel
steering. Do not collapse a chain into one trailer or silently claim equivalent
coverage when a combination falls back to stock CP. Use the appropriate AI work
and travel frames: an offset tool's body axis need not itself be parallel to the
row. Capture data are inputs, not proof of a supported controller.

## Integration boundaries

1. **Before the turn:** obtain the selected stock course target and the complete
   machine geometry. Estimate the approach space needed for the combination,
   accounting for current joint angles, CP speeds and deployment state. Keep
   stock turn context and work-end marker semantics. Do not change the chosen row.
2. **During the turn:** let CP generate and follow its ordinary manoeuvre. Prefer
   its existing outside-headland placement and straight approach where feasible.
   Do not install the retired planner's conservative rectangular-envelope stop
   around the entire turn or duplicate CP's tight-turn offsets.
3. **Before deployment:** assess live alignment and the available approach.
   Detect poor convergence early. Hold stock deployment events until their
   prerequisites are met, then remeasure changed working geometry and offsets.
   Never infer straight wheels merely from a stationary or straight-looking tractor.
4. **Before work:** assess each relevant working edge and direction against the
   selected row, with practical tolerances and a stable/improving measurement.
   Retain stock hydraulic readiness and lowering handlers. All work-producing
   attachments must satisfy their entry conditions before work handover.
5. **If there is insufficient room:** select a permitted stock repositioning
   manoeuvre, with trailer-aware reverse execution and explicit direction-change
   alignment. Consider asymmetric forward turns, straight reverse sections or
   K-turns according to capability; do not force the rigid-vehicle K-turn on a
   towed implement or repeatedly launch loops at the lowering point.

Runtime responsibilities should remain small and separate: attachment geometry,
entry state/control and the stock integration. Existing stock code should acquire
only necessary hooks or parameters. The bench must exercise those actual hooks,
not a separate imitation of their ordering.

## Verification before enabling a test build

- Establish a stock baseline using complete turn sequences, not just isolated
  final poses; distinguish original CP behaviour from added behaviour.
- Reuse captures as fixtures for rigid, articulated, skid-steer, mounted, offset,
  passive-trailer, steered-trailer and chained combinations. Verify that each
  relevant pivot and declared steering capability survives loading.
- Exercise saved work resumption and First/Last/Nearest without changing their
  waypoint semantics. Include both plough sides and initially turned steering.
- Vary speed, steering response, braking, frame rate, geometry measurement error,
  slopes and headland shape. Execution perturbations must be independent of
  planning assumptions; log when a model assumption is being used.
- Check deployment, lowering, direction changes and next-row handover across
  successive turns. Test early recovery and genuinely infeasible approaches too.
- Compare commanded speeds and turn selection with stock CP. Reject hidden
  constant-speed dependencies, unsupported-pivot flattening and late lowering.
- Review the implementation again after the tests pass. Qualify the exact ZIP,
  give every functional test build a new visible number and a direct link, and
  never overwrite the installed/live game ZIP automatically.

This file records the agreed design and acceptance criteria. It does not claim
that the replacement controller has already been implemented or qualified.
