# Visual evidence in Coach

Implemented 2026-11-17. Team and player research now lead with interactive recorded-data charts in the conversation, ahead of the written decision.

## Team view

The matchup card plots the six latest available final games for either team, switching with team chips. Paired graphite/stone bars show points scored and allowed. Summary figures show scoring averages, allowance averages and wins/losses/ties for the displayed sample. Tapping a bar reveals the exact date, opponent and scores; View recorded values exposes the underlying rows.

Only exact team identities and dated, published final results at/before the evidence cutoff qualify. The target game and future results are excluded. Opponents vary, and these raw scoring histories are explicitly descriptive rather than adjusted predictions.

## Player view

An exact named player request shows up to ten recorded games for the requested metric. The requested over/under line, or the matching saved quote's line when applicable, appears as a dashed comparison rule. Summary values show the recorded average and counts above/below/equal to that threshold. These are not past sportsbook settlement records or future hit probabilities: earlier games had different opponents and potentially different sportsbook lines.

The stat selector exposes relevant recorded workload/production metrics. Changing metrics clears an incompatible line instead of reusing the original prop threshold. Tapping bars shows dated values, and the records expansion preserves accessible text evidence. Genuine zeros remain zeros; missing metrics remain blank. Negative production plots below a zero baseline.

Named-player requests routed through hosted game analysis use a bounded visualEvidence object. Local recorded-player evidence uses the same chart component. Unknown/ambiguous player identities never acquire another player's series. Empty histories display an explicit missing-data state.

Known player-prop questions route without AI planning and resolve the named player's own upcoming game rather than inheriting an unrelated prior matchup. Missing-price/local player replies also lead with a chart, so the visual evidence does not depend on a quoted price or remaining inference allowance.

## Bet-specific comparisons (2026-11-17)

Spread questions default to a winning/losing-margin chart. The comparison rule is the negative of the requested handicap: a -3.5 spread needs a margin above +3.5, while +3.5 uses -3.5. Zero is preserved. Switching to the other team's history clears a spread that belongs to the originally requested team. Equality is shown separately, never as a cover.

Total questions default to each team's prior combined final scores against the requested total. The two team histories remain separate, rather than being combined into a fictitious head-to-head sample. Scoring, margin and total modes can be changed through the stat selector. A line from another mode is not reused. Captions state that comparisons with today's threshold are not historical sportsbook results.

Player production now includes a separate opportunity chart: attempts behind passing yards, carries behind rushing yards, and targets behind receiving yards/receptions. Recent-three and preceding-three windows show the number of recorded values actually available; missing values are not zeros and do not silently shift the windows. Separate units/axes prevent targets from being drawn as yardage. Workload remains descriptive, not expected snaps or causal evidence.

Exact-selection price comparisons use the existing validated saved quotes for the same event, participant, market, side, line, period and rules. They retain the latest observation per book, sort by decimal price and preserve both provider observation and collection timestamps. Comparison time is explicitly not a sportsbook refresh. Wrong lines/sides/rules, stale/future observations and invalid clock ordering are excluded. Generic team questions do not inherit a random prop quote. A price ordering is not a validated betting edge.

Tests cover handicap signs/zero, date and American-odds ambiguity, total equality, opponent switching, window missingness, exact quote matching/latest-per-book selection, timestamps and mobile layouts.

When availability/weather context expires or changes, the dated historical graphs remain visible with a retained-history notice; live decisions and saved-book comparisons are withdrawn until refreshed. Schedule/data invalidations still hide the affected view. Newly generated reports exclude already-expired weather observations, preventing an old cached weather row from invalidating a fresh response immediately.

## Boundaries and verification

No source requests, odds credits or inference calls are added by chart generation. The charts use the existing attributed nflverse history and player evidence. Forecasts, experimental line thresholds and probability judgments remain separate; no serving model or captured cohort is changed.

Tests cover cutoff/target exclusions, exact player/team selection, missing versus zero, requested lines, stat switching, negative values, ties, large-text phone layouts and chart placement in game answers. The complete app suite and hosted-service checks remain release gates.
