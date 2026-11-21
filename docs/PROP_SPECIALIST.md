# Prop specialist

Checked November 21, 2026. Each piece was scored on earlier weeks only, against the chance the card already shows. A piece is on the card only when Brier and log loss are both lower in 2025 and in 2026. The line for yards and receptions is still last season's median. The shrink and the 10/15-point gap are unchanged. A lower score is a closer chance. It is not a pick and it is not a betting edge.

The card's lognormal chance, rerun on the current box scores:

| Path | 2025 games | 2025 Brier | 2025 log loss | 2025 mean chance | 2025 actual over | 2026 games | 2026 Brier | 2026 log loss | 2026 mean chance | 2026 actual over |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Lognormal, this file | 6,924 | 0.2293 | 0.6509 | 0.464 | 0.402 | 3,972 | 0.2364 | 0.6655 | 0.469 | 0.446 |
| Recent games weighted more | 6,924 | 0.2289 | 0.6502 | 0.467 | 0.402 | 3,972 | 0.2356 | 0.6640 | 0.472 | 0.446 |

The earlier write-up in `docs/MATCHUPS.md` is 0.2295 and 0.6515 on 6,924 games in 2025, and 0.2361 and 0.6650 on 3,948 games in 2026. The 2025 count matches. The 2026 count is 24 games higher because the box scores now include more completed games. The comparison above uses the same games for both rows.

A teammate listed Out can move a share. That shift was scored on its own and was worse in 2025, so it is not on the card. This model does not add a second version of that move.

Recent weighting is the only yard or reception piece that won. The last eight games are weighted 0.8 to the power of how many games ago they were. Older games in that window count less. The weight was set before looking at these scores.

These pieces did not win on both scores in both seasons, so they are not on the card:

| Piece | 2025 Brier | 2025 log loss | 2026 Brier | 2026 log loss |
| --- | ---: | ---: | ---: | ---: |
| Gamma curve for yards | 0.2297 | 0.6518 | 0.2364 | 0.6656 |
| Position spread, shrunk | 0.2299 | 0.6522 | 0.2366 | 0.6659 |
| Zero-inflated receptions | 0.2295 | 0.6514 | 0.2365 | 0.6658 |
| Snap, route, air yards, red zone | 0.2286 | 0.6495 | 0.2376 | 0.6680 |
| Closing spread shifts the pass rate | 0.2299 | 0.6523 | 0.2358 | 0.6644 |
| Closing total shifts the volume | 0.2297 | 0.6519 | 0.2367 | 0.6661 |

The share file is still in the app. Yards and receptions do not use it. Anytime touchdowns do not use it either, because that chance is not on the card.

## Anytime touchdowns

An anytime score is rushing touchdowns plus receiving touchdowns. A passing touchdown is not a score for the passer. The line in the test is 0.5, meaning at least one score. Recent-games weighting on yards and receptions is unchanged.

The chance that was about to ship shrunk the player's record toward 50 percent, then kept it within 10 or 15 points of that anchor. On an earlier full count that put the average chance near 40 percent while players scored on 6.3 percent of 14,240 games in 2025 and 6.7 percent of 8,379 games in 2026. That chance is not on the card.

The replacement pulls the raw count toward the book's no-vig price when a real price is saved, and toward the position's earlier score rate when it is not. A position rate is used only after 12 players at that position have four earlier games. A small correction, fit on earlier weeks only and warmed up on 2024, is added after 200 earlier scored games, then the same 10/15-point gap is applied again. The card can show that chance only when the average sits within 2 points of the rate players scored, and the chance beats the position-anchored record on both scores in both seasons.

On the games that have a position rate, players scored on 10.9 percent of 8,110 games in 2025 and 10.8 percent of 5,181 games in 2026. The old 50 percent shrink on those same games still averaged 40.2 percent and 39.9 percent.

| Path | 2025 games | 2025 Brier | 2025 log loss | 2025 mean chance | 2025 actual | 2026 games | 2026 Brier | 2026 log loss | 2026 mean chance | 2026 actual |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Old shrink toward 50 percent | 8,110 | 0.1798 | 0.5506 | 0.402 | 0.109 | 5,181 | 0.1776 | 0.5460 | 0.399 | 0.108 |
| Record pulled toward the position rate | 8,110 | 0.0824 | 0.2611 | 0.110 | 0.109 | 5,181 | 0.0790 | 0.2476 | 0.103 | 0.108 |
| Poisson count, calibrated | 8,110 | 0.0841 | 0.2722 | 0.113 | 0.109 | 5,181 | 0.0822 | 0.2629 | 0.103 | 0.108 |
| Zero-inflated count, calibrated | 8,110 | 0.0851 | 0.2751 | 0.105 | 0.109 | 5,181 | 0.0832 | 0.2655 | 0.094 | 0.108 |
| Poisson, plus red zone and the closing total | 8,110 | 0.0825 | 0.2671 | 0.114 | 0.109 | 5,181 | 0.0808 | 0.2590 | 0.103 | 0.108 |

The calibrated counts land within 2 points of the rate players scored. None of them beat the position-anchored record on both scores in both seasons. The card therefore does not show an anytime chance. The feed and the detail say "Anytime touchdown chance is unavailable." The chat is unchanged.

## Real closing prices

`assets/prop-closes.json` is derived from the PropLine graded sample (CC BY 4.0, NFL September 18–29, 2026). The file keeps a no-vig prior, the line, the box-score result, and how many books were used. It does not keep raw prices. A book is left out of the prior only when its no-vig chance is at least 8 points from the others and its price is at least 3 hours older. Pinnacle is half of the prior when it posted both sides and was not stale.

| Comparison | Games | Brier | Log loss |
| --- | ---: | ---: | ---: |
| Our chance, 2026 | 909 | 0.2533 | 0.7000 |
| Closing no-vig, 2026 | 909 | 0.2513 | 0.6958 |
| 2025 | unavailable | unavailable | unavailable |

On these 909 props, our chance sat 0.64 points below the closing no-vig on average. The closing no-vig scored better. The consensus is not used as the card's anchor. One season of prices cannot pass the both-seasons rule, and 2025 two-sided closes are unavailable.

## Leaning on the market

Checked November 21, 2026 in `test/market_blend_test.dart`. The question was whether the projection adds anything on top of the closing no-vig. The pooled chance is the close moved toward the projection in log odds, by a weight. On the same 909 props:

| Chance | Brier | Log loss |
| --- | ---: | ---: |
| Closing no-vig | 0.2513 | 0.6958 |
| Old card: projection pulled toward that price with 32 games, capped | 0.2541 | 0.7017 |
| Projection alone | 0.2775 | 0.7785 |
| Pooled, weight fit on the other week only (0 and 0.1) | 0.2516 | 0.6963 |
| Pooled, weight 0.05 (the card now) | 0.2512 | 0.6956 |

The best weight on all 909 was 0.05, so the projection's disagreement with the close carries little information. The old 32-game pull scored worse than the close, which means it was showing gaps the result did not back up. The card now serves the pooled chance whenever a real no-vig price exists (`propModelWeight` in `lib/domain/prop_chance.dart`). Gaps against the price are now usually under a point, so fewer props show as value. The season backtests above still pass the even proxy and are unchanged. Two weeks of one season is a small sample; the weight should be refit once more two-sided closes are saved.

The Odds Gap free CSV has one side, so the vig cannot be removed. That comparison is unavailable. The Bovada 2021 and 2022 files were read locally and not committed. The bundled box scores start in 2023, so those seasons cannot be scored. That comparison is unavailable.

`assets/price-history.json` still has no prop prices. Yards and receptions in the season tables above still use last season's median.
