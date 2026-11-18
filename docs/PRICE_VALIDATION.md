# Price coverage and forward validation

Implemented 2026-11-16. Coach remains one conversation, with optional research details.

## Collection within the existing budget

The public publisher selects the `slate` profile. A free event-index request checks the provider usage counter against the existing private checkpoint. One four-credit reservation covers a bulk NFL h2h/spreads/totals request (at most three credits across ten bookmakers) and one rotating prop market for the earliest matched game (at most one credit). The daily four-credit and monthly 60-credit limits and protected 50-credit reserve apply. The slate is eligible for collection within 36 hours of the next kickoff. The existing publishing schedule, cache and no-retry rule govern actual observation times.

Coach retains the first matching pregame observation for up to seven days through gaps in the feed. Displayed changes require a fresh later observation from the same book, provider and market scope. For adverse spread or total moves, another book can appear as a better saved number when its payout is at least as high and both quotes are within two hours. First saved quotes may follow the actual opener. This comparison does not forecast future prices.

Provider contract: https://the-odds-api.com/liveapi/guides/v4/ — the sport odds endpoint covers multiple games; usage is per market and group of ten bookmakers. Player props require the event odds endpoint. This improves breadth, not refresh frequency. There is still no continuous or complete real-time feed.

The maximum charge is persisted before any paid request. Each response must reconcile its own charge and cumulative usage. Unexpected accounting blocks later charging. A prop timeout retains validated slate prices while its possible charge remains reserved. The checkpoint is never reset to recover from a mismatch. Existing one-game caches stay readable until expiry; new caches retain separately validated games and prune started games. Test data remains marked and rejected by the live app.

Public v2 coverage accepts optional `eventIds`, retaining `eventId` as the prop-identity scope. Every game quote is checked against its own exact schedule entry. A prop cannot borrow another game's player registry. The UI removes expired/started selections independently. Original source and collection times remain unchanged on cache reuse. No secret, ledger or raw provider response is published.

## More useful answers

The decision brief filters requested team, market, player, side and line before choosing a price. An unrelated priced selection cannot fill a gap. Player and total requests omit the game-winner lean. No candidate is promoted: the brief explicitly passes while context, exact prices or validation remain insufficient. The saved observed price includes its book and time alongside the separate, unvalidated research break-even price. Price coverage expands to show quote counts, books and latest observation times by market group. It does not imply the prices can still be obtained.

## Forward validation

Frozen pregame snapshots and separate model cohorts remain unchanged. New grading includes:

- Five descriptive probability bands, with predicted probability and actual outcome averaged within each game before averaging games in that band. Pushes and missing appearances remain excluded/unresolved as before. Counts include repeated quotes and are not independent trials.
- Price-matched Brier and log-loss differences against the same-selection paired market baseline. Unpriced historical reference probabilities do not enter this comparison. Differences below zero favor Coach.
- An approximate 95% interval for the mean game-level difference after at least 30 matched games; it is hidden for smaller samples. This normal approximation does not resolve temporal correlation, quote selection bias, unverified settlement rules or transportability.

The report stays `collecting_evidence` below 1,000 matched priced games, then `review_required`. This is a research reporting threshold, not an adoption gate. `adopted` and `hasEdge` remain false regardless of the interval. The worker regrades existing frozen records once under the new grading version without replacing captures or double-counting old results. Score corrections remove prior calibration and comparison contributions before adding replacements.

Generic AI benchmarks still use their existing shared limits and requested-game behavior. No extra background AI calls, provider credits, personal bet logs or paid tiers were added. Actual validation must wait for games and source results; historical improvements cannot prove future profit or superiority to every AI.


## Schedule-only availability

The price publisher now emits a version-one schedule with odds.status unavailable and a bounded availability reason instead of claiming the source is disconnected for every empty result. Checked time describes the publisher check, never a new quote. A future eligibleAt is published only for the pregame window or daily/monthly allowance reset; eligibility does not promise a successful refresh. The app and Worker reconstruct public wording from an allowlist rather than exposing provider errors. Stale availability checks expire after 24 hours. Prices still expire after 18 hours. Free caps, protected reserve, persistent accounting, no-retry policy and six-hour acquisition window are unchanged.
