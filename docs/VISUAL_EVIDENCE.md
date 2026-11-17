# Visual evidence in Coach

Implemented 2026-11-17. Team and player research now lead with interactive recorded-data charts in the conversation, ahead of the written decision.

## Team view

The matchup card plots the six latest available final games for either team, switching with team chips. Paired graphite/stone bars show points scored and allowed. Summary figures show scoring averages, allowance averages and wins/losses/ties for the displayed sample. Tapping a bar reveals the exact date, opponent and scores; View recorded values exposes the underlying rows.

Only exact team identities and dated, published final results at/before the evidence cutoff qualify. The target game and future results are excluded. Opponents vary, and these raw scoring histories are explicitly descriptive rather than adjusted predictions.

## Player view

An exact named player request shows up to ten recorded games for the requested metric. The requested over/under line, or the matching saved quote's line when applicable, appears as a dashed comparison rule. Summary values show the recorded average and counts above/below/equal to that threshold. These are not past sportsbook settlement records or future hit probabilities: earlier games had different opponents and potentially different sportsbook lines.

The stat selector exposes relevant recorded workload/production metrics. Changing metrics clears an incompatible line instead of reusing the original prop threshold. Tapping bars shows dated values, and the records expansion preserves accessible text evidence. Genuine zeros remain zeros; missing metrics remain blank. Negative production plots below a zero baseline.

Named-player requests routed through hosted game analysis use a bounded visualEvidence object. Local recorded-player evidence uses the same chart component. Unknown/ambiguous player identities never acquire another player's series. Empty histories display an explicit missing-data state.

## Boundaries and verification

No source requests, odds credits or inference calls are added by chart generation. The charts use the existing attributed nflverse history and player evidence. Forecasts, experimental line thresholds and probability judgments remain separate; no serving model or captured cohort is changed.

Tests cover cutoff/target exclusions, exact player/team selection, missing versus zero, requested lines, stat switching, negative values, ties, large-text phone layouts and chart placement in game answers. The complete app suite and hosted-service checks remain release gates.
