# Complete NFL game analysis

Ask Coach to **Analyze a game**, **Analyze the Bills**, **Bills moneyline**,
or ask about a spread or game total. Select an exact upcoming game when needed.
One response contains a shared score outlook, spread, game total, moneyline,
player workload projections and exact saved-price comparisons. Sportsbook
filters stay in the conversation. Explicit dates and calendar-week requests are
resolved against America/New_York; a different game is not silently substituted.

## Model audit and promotion policy

The legacy EPA model, its walk-forward infrastructure, dated score history,
identity mapping and adoption discipline were reviewed. Its original spread
test had negative returns; v2 adoption did not establish a profitable edge.
Those facts are preserved in the new artifact's `legacyAudit`.

`model/game_forecast.py` fits a fixed opponent-adjusted score ridge model using
strictly earlier calendar weeks, a 730-day window, 180-day half-life, and ridge
40. Training includes only scores at or before the source cutoff. The empirical
joint score-error pool is itself generated out of sample and frozen for each
whole evaluation week. No parameters were retuned after inspecting the results.
Home/away score errors remain paired, preserving their observed dependence.
The model is not a possession simulator; discrete scoring/key-number and tail
calibration are not established.

The initial score-only candidate **did not beat the market/reference baseline**:

| Market | Decided test games | Candidate Brier | Market/reference Brier |
| --- | ---: | ---: | ---: |
| Moneyline | 787 | 0.2394 | 0.2100 |
| Spread | 773 | 0.2746 | 0.2504 |
| Game total | 786 | 0.2667 | 0.2502 |

Lower Brier is better. Historical lines are closing references, not proof that
those prices could have been obtained at forecast time. Missing historical
two-sided odds use an explicitly simple baseline (prior home-win frequency or
50%). This exercise does not validate live returns, player props, or superiority
over an AI. The candidate remains unadopted and `hasEdge` stays false.

When paired market prices exist, live pricing uses a **market-anchored** joint
score distribution. Exact, same-book opposing sides provide no-vig reference
probabilities; repeated proportional fitting constrains one shared score-error
distribution for spread, total and moneyline. No independent model advantage is
claimed. Without game prices the score candidate is labeled experimental, and
no priced opportunity is invented. AI prose cannot replace the server's
unvalidated recommendation status.

Player forecasts expose their recorded workload, recent-volume weighting,
efficiency and uncertainty. They require six appearances, preserve role and
participation caveats, and do not invent opponent or injury adjustments. A
relevant reported Out/Doubtful/Inactive/IR listing blocks ranking that player's
prop as a usable candidate. This does not declare the report confirmed for the
next game. Whole-number pushes have explicit probability mass. A model-fair
decimal price is `(1-push)/win`; conditional return is `win*decimal-(1-push)`.
These calculations are not validated betting edges or guaranteed obtainable prices.

## Price coverage within the existing free budget

The public workflow uses the **balanced** publisher profile: moneyline, spread,
total, and one rotating player-prop market. Exactly four markets are requested.
The four-credit daily cap, 60-credit monthly cap, protected 50-credit reserve,
six-hour pregame window, atomic reservations and provider-usage reconciliation
are unchanged. Existing saved observations are reused without a new charge;
an older valid props-only cache stays readable until it expires. No ledger is
reset or reconciled automatically. This is limited snapshot coverage, not a
continuous live-price service. Unsupported games/books/markets remain unavailable.

## Automatic forward evaluation

`GET /v1/evaluation` and **Coach performance** show the model's research record.
The background coordinator captures the first available forecast within 24 hours
of kickoff for each game/model, plus the first priced cohort when available.
The priced cohort takes precedence for grading. Exact quotes, source times,
capture times, model/source cutoff and settlement assumptions are frozen.
Questions, users, stakes and personal bets are not recorded.

Published final scores and recorded player outcomes grade the forecasts later.
An absent appearance is unresolved, never an imputed zero or invented void.
Score/stat corrections replace a previous grade instead of adding another one.
Pushes are excluded from Brier/log-loss evaluation; book observations within a
game are averaged before averaging games. Market baselines use matched rows.
Unverified settlement conventions and potentially stale snapshots cannot become
proof of realized profit. No cumulative ROI or betting-edge claim is advertised.

For requested games inside the capture window, one optional generic AI benchmark
is attempted from frozen source facts, without the engine's forecast/probability
outputs. Targets cover available market categories, with at most six selections.
The model and prompt version are stored. The existing shared 60-call/day and
8-call/IP/hour limits also cover this call; reservations prevent duplicate
attempts. Failures and partial responses remain missing/partial. Only paired
observations are compared. This benchmark is the configured Workers AI model,
not evidence of superiority to every general AI, and covers requested games.

The coordinator never calls an odds provider or generates AI benchmarks merely
because its clock ticks. Normalized results are published by the existing data
pipeline; outcomes cannot be graded before they appear in those source records.
Forecast storage is capped at 5,000 captured games. No inference of an edge or
automatic promotion occurs from a small or favorable run.

## Reproducible checks

```
python model/game_forecast.py --schedule path/to/nflverse-games.csv
python -m unittest discover -s model -t model
python -m unittest discover -s tools -p 'test_*.py'
node --test hosting/*.test.mjs
flutter analyze
flutter test
```

The weekly model workflow refreshes `assets/game-forecast-model.json`. The public
publisher adds its versioned forecast and dated result data to the trusted Coach
index. `/v1/game-analysis` calculates on the server, and `/v1/coach` independently
recalculates the explanation evidence. Client-supplied probability claims are
not promoted to trusted game forecasts.
