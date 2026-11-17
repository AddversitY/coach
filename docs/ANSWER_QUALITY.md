# Selection-specific answers and regression questions

Implemented 2026-11-17. This improves answer correctness and clarity, not demonstrated predictive accuracy.

## Answer contract

When a matching usable quote and calculated probability exist, Coach explains the requested selection's conditional chance, push chance and opposing case. A game-winner lean is never substituted for a spread, game total or player prop. Market-anchored rows are explicitly described as market-based outlooks; independent and player models remain experimental. Favoring an outcome occurring does not establish value at its offered odds.

Price reasoning shows an experimental exact-line break-even threshold `(1 − push) / win`. It does not call this an approved betting price. A different spread or total requires recalculation; no invented alternate-line cutoff is supplied. Missing, stale, blocked, wrong-book and unknown-player selections receive no numerical judgment or threshold. Unknown player props ask for one full recorded player name.

Parlays cannot borrow a single leg's probability or price. They require explicit legs, correlation-aware joint analysis and the sportsbook's actual ticket quote. The existing joint-simulation workflow stays separate.

Follow-up links offer a market comparison, the opposing case and matchup evidence. Server-generated queries include the exact event date and original side/line when applicable, so a button on an older answer can restore its subject. Typed follow-ups preserve the selected side/line where appropriate, but clear them when switching to a total or whole matchup.

## Fixed question suite

`hosting/fixtures/answer-scenarios.json` supplies thirty-seven realistic question forms across spreads, moneylines, totals, receiving yards, receptions, passing yards, rushing yards and parlays. The tests run those questions through the real game-analysis engine, not a mocked answer generator. They verify exact selected market/side/line, preserved follow-up context, explicit unvalidated status and missing-input behavior.

Additional checks cover stale/closed prices, requested books with no matching quotes, blocked roles, push-aware threshold arithmetic and invalid probabilities. Phone tests verify judgment, threshold, line-change limitations and follow-up layout; session tests cover typed market switches and mixed spread/odds numbers.

The suite caught and fixed: winner leans leaking into spread answers; signed spreads appearing before the word “spread”; an unknown player inheriting another player's quote; and the word “Receiver” in a name being mistaken for a receiving-yards market. Existing player/market/side restrictions remain in force.

Run:

```powershell
node --test hosting/*.test.mjs
flutter analyze
flutter test
```

These checks assess deterministic structured answers, source selection and conversation behavior. They do not grade unrestricted model prose, prove profitability, or establish superiority to general AI. No extra paid service, AI calls or odds budget was introduced.

## Completion milestones

Coach is a functioning hosted early product with game/prop research, a single conversation, free source checks and automatic model evaluation. This pass strengthens the path to a dependable test release. Remaining release work includes broader real-user question coverage, explicit handling of source outages/limits, verified starter/participation coverage where obtainable and operating-cost/reliability review.

Predictive superiority is a separate, uncompleted research milestone: collect untouched pregame predictions across future weeks, grade matching results, compare against market prices and completed configured-AI baselines, and assess calibration/error uncertainty by market. There is no supported completion percentage or guaranteed date for that outcome, and the models may not beat the market.


## Everyday wording and exact intent

The fixed suite now includes signed team spreads without the word spread, ML, game-side over/under wording and rec/pass/rush yds. The server decision and default chart share the same market recognition; app conversation memory retains shorthand selections for follow-ups. American prices and ISO dates cannot become spread handicaps. A named player plus over/under and a line without a stat asks which player market is intended and does not attach that threshold to a default production chart. Deterministic recognized requests do not need planner inference. This expands routing correctness, not predictive skill.


## Complete selections, supported scope and clarification replies

A priced judgment now requires an explicit supported market and complete selected side/line (or a named moneyline team). Missing over/under numbers, unspecified spread teams and bare market overviews cannot choose a saved quote. Generic player/matchup research has no silently selected price. Named-player requests in local mode require the recorded full name; surname overlap does not identify a player. A new explicit team request clears a prior player even in the same game. Unknown new subjects cannot inherit the previous game; clear contextual questions and case-insensitive NFL codes still resolve.

Half/quarter, team-total, in-play and regulation-only requests are explicitly unsupported. The app, planner, hosted decision and direct interpretation route do not substitute full-game prices, probabilities, chart thresholds or winner leans. A planner cannot drop the requested scope, switch the requested market or choose a missing player stat. Recognized missing/unsupported selections clarify without an inference reservation. Historical charts returned with an unsupported API scope have no requested selection line.

ISO dates and American odds cannot supply a missing spread. New explicit requests reset prior side/line memory. Clarification replies can supply only the missing number, over/under, player stat or team, preserving the user-specified parts and original game date. Unknown subjects reset context; why follow-ups repeat the unresolved question rather than reviving an unrelated selection. Local research participates in the same conversation memory. No provider request, AI budget increase, predictor change or model adoption was introduced.
