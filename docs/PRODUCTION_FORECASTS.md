# Joint workload and efficiency trial

Ask **Forecast the Bills passing yards**, then open **Prop forecast trial**.
Ask **Coach performance** for **Yards & receptions research** and its nested
**Quarterback signal check**. These are research views in the Coach conversation.

The trial covers QB passing/rushing yards, RB rushing yards, RB/WR/TE receiving
yards and RB/WR/TE receptions. It remains `adopted:false`, `hasEdge:false` and
separate from serving prop estimates and rankings.

## End-to-end method

The volume component uses the workload model's settings selected before 2025.
Its historical predictions are refitted with strictly earlier weeks; final
coefficients are never replayed over historical outcomes. Efficiency starts
from earlier weighted production per opportunity, with an optional ridge
residual selected from no correction, 1, 10 and 100 using only pre-2025 data.
Features include earlier efficiency, opponent allowance and explicit previously
observed quarterback continuity/passing-efficiency signals. Future starter names,
current-game production, injuries without reliable historical timestamps and
the actual future quarterback identity are not forecast inputs.

The uncertainty engine replays **paired out-of-sample volume and efficiency
errors**, individually centered and frozen before each whole evaluation week.
It retains their dependence rather than multiplying independent marginal
probabilities or treating a product of point estimates as the full distribution.
Counts and final outcomes are rounded; receptions cannot exceed simulated
targets. Zero opportunities do not define an efficiency rate: their rate-error
convention is zero, and their recorded production still counts in evaluation.
Negative recorded yardage is retained. Research bounds are efficiency -20 to 60
yards/opportunity and total yardage -999 to 999; these are modeling assumptions,
not asserted sport limits. At least 120 earlier residual pairs are required for
live distributions, with at most 512 retained per group.

Six same-team/position records and the workload eligibility rules are required.
Trial history can include earlier seasons within 730 days, up to ten records;
the ordinary recorded-stat cards retain their current-season scope.
The comparison reproduces the existing nonnegative-production record filter
and weighting formula on the same available history; it is not an assertion
that every live record/price vintage was historically available. Missing
appearances remain unresolved, never invented zeros.

## Initial retrospective evaluation

Evidence through **2026-11-12**, later seasons from 2025. Errors are per recorded
appearance. The underlying archive is a current retrospective vintage, not a
historical point-in-time availability feed.

| Group | Recorded | Candidate MAE | Baseline MAE | Nominal 80% range coverage |
| --- | ---: | ---: | ---: | ---: |
| QB passing yards | 624 | 61.64 | 64.66 | 81% |
| QB rushing yards | 605 | 11.80 | 12.35 | 82% |
| RB rushing yards | 1,565 | 21.31 | 21.16 | 86% |
| RB receiving yards | 1,533 | 11.29 | 11.25 | 84% |
| RB receptions | 1,547 | 1.15 | 1.14 | 90% |
| WR receiving yards | 2,390 | 22.65 | 22.68 | 88% |
| WR receptions | 2,398 | 1.47 | 1.46 | 92% |
| TE receiving yards | 1,326 | 16.49 | 16.65 | 87% |
| TE receptions | 1,326 | 1.33 | 1.36 | 93% |

Passing yards improved, several other point forecasts did not, and some ranges
were too wide. Passing/rushing QB yards and TE production cleared the exploratory
point-error criteria, which require better MAE, lower RMSE and a paired week-block
bootstrap upper bound below zero on at least 200 recorded outcomes. This is not
a probability-calibration or betting-edge gate. No multiple-comparison correction
has been applied across the nine research groups. All remain unadopted.

Historical Brier scores use **baseline-mean-derived half-line reference cutoffs**
known before the outcome. They are not historical sportsbook lines, offered
prices or evidence of obtainable returns. Actual saved quote comparisons are
collected prospectively instead of inventing historical market coverage.

## Quarterback signal test

For receiver groups, the ablation refits both volume and efficiency models
without the explicit earlier observed QB continuity/passing-efficiency signals,
holding selected ridge settings fixed. Other historical performance features
can still indirectly reflect quarterback play. Results are reported for all
matched appearances, earlier observed-change subsets, and game passing-leader-change
outcome slices. The game leader is the recorded QB with the most attempts; this does not establish who started. That identity is used only afterward to label evaluation
subsets. It cannot leak into either forecast's feature vector.

Effects were mixed and often small. For example, WR receiving-yard MAE in the
game passing-leader-change slice was 20.50 with explicit signals versus 20.45 without them.
This is not a causal estimate of changing a quarterback. No blanket receiving
penalty or confirmation of an upcoming starter is derived from this experiment.
The existing current-source lineup warnings remain separate.

## Prospective capture and grading

The coordinator freezes the first trial forecasts within 24 hours of kickoff.
When saved matching quotes exist, it also freezes the first priced cohort;
that cohort takes precedence for grading under the existing evaluation policy.
Candidate and same-input serving probabilities share the exact line, side,
player identity, source time and observed price. No extra odds or AI calls are
made. No user identity, stake or personal bet history is recorded.

Point errors and exact-line Brier/log-loss results are graded from published
outcomes with exact player/team identities. Recorded negative yards and real
zeros are valid; missing appearances or mismatched teams stay unresolved.
Corrections replace prior grades. Prospective rows are averaged within each
game before averaging games. They do not establish a realized return or an
advantage over general AI.

`assets/production-model.json` retains development candidates, season slices,
coverage, synthetic-cutoff scores, QB ablations and source hashes. The publisher
verifies the dependent workload-model hash before indexing. Python/JavaScript
fixtures check distribution parity for passing yards, receiving yards and
receptions. The weekly workflow refreshes both models together. Reproduce with
`python model/production_forecast.py --schedule <nflverse schedule CSV>`.
