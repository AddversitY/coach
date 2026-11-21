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

The share file is still in the app. Anytime touchdowns use the red-zone part. Yards and receptions do not.

## Anytime touchdowns

An anytime score is rushing touchdowns plus receiving touchdowns. A passing touchdown is not a score for the passer. The old chance is the player's recorded rate, shrunk toward 50 percent with the same gap. The line in the test is 0.5, meaning at least one score. Players scored on 6.3 percent of the 2025 games and 6.7 percent of the 2026 games. The shrink and the gap keep every chance near 40 percent, so none of these chances is close to the rate players actually scored. The new curve is closer than the record. It is still not a prediction that someone will score.

| Path | 2025 games | 2025 Brier | 2025 log loss | 2025 mean chance | 2026 games | 2026 Brier | 2026 log loss | 2026 mean chance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Recorded rate | 14,240 | 0.1715 | 0.5340 | 0.401 | 8,379 | 0.1710 | 0.5329 | 0.399 |
| Zero-inflated count, plus red zone and the closing total | 14,240 | 0.1571 | 0.5033 | 0.376 | 8,379 | 0.1542 | 0.4971 | 0.370 |

The plain zero-inflated count already beat the record (2025 Brier 0.1572, log loss 0.5034; 2026 Brier 0.1545, log loss 0.4976). Adding the red-zone share and the game's implied total, one at a time and then together, beat that plain count on both scores in both seasons. That combined count is what the card uses when an anytime price is on the board. The chat is unchanged.

## Real closing prices

`assets/prop-closes.json` is derived from the PropLine graded sample (CC BY 4.0, NFL September 18–29, 2026). The file keeps a no-vig prior, the line, the box-score result, and how many books were used. It does not keep raw prices. A book is left out of the prior only when its no-vig chance is at least 8 points from the others and its price is at least 3 hours older. Pinnacle is half of the prior when it posted both sides and was not stale.

| Comparison | Games | Brier | Log loss |
| --- | ---: | ---: | ---: |
| Our chance, 2026 | 909 | 0.2533 | 0.7000 |
| Closing no-vig, 2026 | 909 | 0.2513 | 0.6958 |
| 2025 | unavailable | unavailable | unavailable |

On these 909 props, our chance sat 0.64 points below the closing no-vig on average. The closing no-vig scored better. The consensus is not used as the card's anchor. One season of prices cannot pass the both-seasons rule, and 2025 two-sided closes are unavailable.

The Odds Gap free CSV has one side, so the vig cannot be removed. That comparison is unavailable. The Bovada 2021 and 2022 files were read locally and not committed. The bundled box scores start in 2023, so those seasons cannot be scored. That comparison is unavailable.

`assets/price-history.json` still has no prop prices. Yards and receptions in the season tables above still use last season's median.
