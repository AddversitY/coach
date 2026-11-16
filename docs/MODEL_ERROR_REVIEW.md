# Game-model error review and targeted challenger

Implemented 2026-11-16. This milestone diagnoses the free AI failure, audits score-model errors and adds ONE fixed distribution challenger. Nothing is promoted into betting recommendations.

## AI baseline diagnosis and recovery

A quota-controlled live diagnostic returned `provider_daily_limit`. Cloudflare documents the free daily allocation and code 3036 on its [AI error page](https://developers.cloudflare.com/workers-ai/platform/errors/). This is separate from Coach's own request cap. No paid plan or substitute model was enabled.

The worker now stores a safe provider-limit status and pauses inference reservations until the next UTC reset plus five minutes. This is retry eligibility, not a guarantee that provider capacity has reset. Denied reservations do not spend Coach's local request quota. Clear game-analysis planning routes are deterministic and bypass AI inference; the model remains available for less structured requests and grounded explanations. Explanation output is capped at 420 tokens instead of 650. Existing daily/hourly request limits and the maximum two automatic baselines per UTC day stay unchanged.

A provider daily-limit rejection can defer an eligible frozen benchmark until after reset, before kickoff. The automatic reservation checks the provider cooldown before using a slot. Actual model/parse/timeout failures are not repeatedly inferred. Failed older records are not reclassified without evidence. Public failure categories contain no raw exception text, credentials or prompts.

## Error audit

`assets/game-error-audit.json` records separate development and later-period diagnostic slices. Development uses seasons before 2025. The original fixed score model's team-score absolute errors were:

| Development slice | Games | Mean score error |
| --- | ---: | ---: |
| All games | 512 | 7.635 points |
| Extreme final totals (at most 30 or at least 60) | 139 | 11.260 |
| Ordinary final totals | 373 | 6.284 |
| Favorites of at least 7 closing-line points | 121 | 7.818 |
| Observed quarterback changes | 111 | 7.776 |
| Observed quarterback continuity | 401 | 7.596 |

Extreme realized outcomes are harder by construction. This finding does NOT mean those outcomes can be identified before kickoff. The quarterback-change slice uses recorded game QB identity, not a historically verified starter announcement; no causal penalty or invented lineup adjustment is inferred. Closing-line groups are diagnostics, not inputs to the new independent model. Recent scoring swings did not show a larger score error than the overall development sample.

## One fixed scoring-regime challenger

`score-regime-kernel-v1` keeps the original ridge-40/180-day score mean fit, and tests a conditional paired-error distribution. Each earlier out-of-sample error pair carries its own pregame projected combined score and absolute margin. Similar earlier forecast contexts receive more weight, with fixed bandwidths of 10 total points and 7 margin points. We mix those weights equally with uniform weights. Effective samples below 120 revert to the uniform distribution. Up to 1,000 earlier errors are retained; the entire testing week is frozen before its labels enter the bank.

There is no parameter search, no closing-line input, no current-game QB assumption and no same-week outcome input. Python and JavaScript weight parity is tested. The model's history hash, fixed specification, finite weights/coefficients, error/context lengths and unadopted status are checked before publication. It is captured as a separate prospective cohort for game markets only; serving probabilities and the stronger existing challenger remain unchanged. It makes no extra AI or odds-provider requests.

## Retrospective result

The later 2025+ period was NOT used to choose this candidate's settings, but those seasons appeared in earlier project reports. It is therefore retrospective validation, NOT a newly untouched holdout. Only newly frozen future games after deployment are untouched evaluation.

Brier error, lower is better:

| Market | Games | New trial | Original fixed model | Stronger existing challenger | Market reference |
| --- | ---: | ---: | ---: | ---: | ---: |
| Moneyline | 407 | 0.238098 | 0.238434 | 0.225721 | 0.213314 |
| Spread | 402 | 0.272082 | 0.272407 | 0.267743 | 0.249795 |
| Total | 409 | 0.267809 | 0.267888 | 0.259571 | 0.250383 |

The changes versus the original model are small; the total-error paired interval includes zero. The trial still trails market references and the stronger existing challenger in every market. It stays in research. No result is hidden, no setting was changed after seeing this comparison, and no accuracy/profitability/superiority claim is made. Season/week block intervals are exploratory and do not resolve earlier exposure to these seasons or multiple comparisons.

The weekly model workflow regenerates the audit and this fixed candidate. Coach performance now exposes these findings and the provider pause. Existing source refreshes and prospective grading continue. Tests cover same-week/future-label exclusion, parity, effective-sample fallback, model provenance, serving-source immutability and quota recovery. The publishable retrieval index remains below its two-megabyte bound.
