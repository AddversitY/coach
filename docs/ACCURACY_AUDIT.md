# Accuracy audit — 2026-11-16

Source: the public `/v1/evaluation` endpoint. The captured public figures and response hash are saved in [the audit record](audits/2026-11-16.json). This is an internal model audit, not a personal bet history.

## Findings

The serving model and each of the three background cohorts had one game captured and zero games with published results. There is no prospective accuracy or profit conclusion yet. Captured games must finish and the normal source pipeline must publish final outcomes before grading can proceed.

The historical game-model challenger lost to its market/reference baseline on both probability scores in all three game categories. Lower error is better:

| Market | Games | Challenger Brier | Market Brier | Challenger log loss | Market log loss |
| --- | ---: | ---: | ---: | ---: | ---: |
| Moneyline | 407 | 0.2257 | 0.2133 | 0.6419 | 0.6140 |
| Spread | 402 | 0.2677 | 0.2498 | 0.7316 | 0.6927 |
| Total | 409 | 0.2596 | 0.2504 | 0.7133 | 0.6939 |

These are retrospective challenger results, not scores for the current market-anchored serving forecast. Keeping the challenger out of recommendations remains warranted.

Player results are mixed. QB passing-yard MAE was 61.64 versus 64.66 for its baseline on 624 recorded appearances. RB rushing yards, RB receiving yards, RB receptions and WR receptions did not beat their point baselines. Several central 80% intervals covered substantially more than 80% historically, so their width is not evidence of precise future probabilities. Point improvements alone do not prove a sportsbook-line advantage.

## Implemented response

The performance view now separates prospective sample size from historical comparisons, and includes all four market groups even when no results exist. The public report cannot present an empty prospective sample as model superiority.

A single fixed calibration candidate, `temperature-080-v1`, is registered for NEW frozen forecasts: conditional non-push log odds are multiplied by 0.80, with push mass and structural zero/one probabilities retained. This is a conservative test of less extreme probabilities, not a fitted calibrator or an established improvement. There is no parameter search. Serving values stay unchanged. Old saved captures are not backfilled with trial probabilities. Game-level matched Brier and log-loss differences are reported after actual outcomes; negative differences favor the trial. All candidates remain unadopted; 1,000 matched games triggers review rather than automatic promotion. No confidence or profitability claim is made from that threshold.

Existing result records are regraded once for the new report schema. Corrections remove prior contributions before adding replacements. Pushes do not enter conditional probability scores and missing appearances remain unresolved. Prospective comparisons remain separated by model version. The calibration trial consumes no extra AI or sportsbook calls.

Participation evidence now explicitly states that official active lists and confirmed starting roles are unavailable. Unofficial reports retain their dates and status. No report or an Active label establishes next-game participation. No fabricated injury/role probability penalty was introduced.

Each decision exposes “What would change this answer?”: a fresh price for the exact selection, official participation/role confirmation, and better future probability performance versus matched market baselines. Completing a single condition does not authorize a bet or establish an edge.

## Limits and next evidence

We cannot fit or validate a learned calibrator from zero graded games. A dependable official availability source is still needed before Coach can confirm starters or active lists. Existing free usage limits and collection cadence remain unchanged. Next, review actual matched results as they arrive and compare the fixed calibration trial with its original frozen forecasts. Do not tune the trial after seeing a favorable or unfavorable result.
