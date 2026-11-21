# Matchups and what changed

Checked November 20, 2026. The numbers below come from the files Coach loads. They are not typed in as a story. Player-prop prices are not in those files, so the prop test uses last season's median as the line.

## Unit ratings

`lib/domain/unit_ratings.dart` builds a rating for a week from regular-season player box scores in earlier weeks only. A game in week 11 cannot move the rating used for week 11.

The inputs are yards per pass attempt, yards per carry, yards per target against wide receivers, tight ends and running backs, and sacks per dropback. Play-by-play EPA, pressures, success rate and pass rate over expected are not in those rows, so they are not filled in. The team weekly file's passing and rushing EPA is used only in the rematch card, and that EPA includes the value of turnovers on those plays.

Each team-week rate is shrunk toward the league rate, then adjusted for the opponents already faced. Clubs with fewer than three earlier games stay unranked. When at least 24 clubs are ranked, Elite is the top 8 and Weak is the bottom 8. With fewer clubs, the cut is about a quarter of the clubs at each end. The rest are Average.

A player's splits use the opponent's tier at the time of each earlier game. A tier with fewer than eight games is shrunk toward that player's own average and labeled a small sample.

## Projections

The served prop chance is the usage model with one opponent adjustment. The adjustment is the opponent's unit rating, clamped between 0.85 and 1.15, times the player's own elite-to-weak sensitivity, shrunk toward no extra response and clamped between 0.94 and 1.06. Recent form uses weight 0.25. The team-total scale and the raw defense-yards scale are not applied on top of that. Passing `environment: null` still keeps the old stacked factors, and the projection tests cover that path. The card does not claim a betting edge.

`assets/price-history.json` now stores prices Coach already pulled, and the last pre-kickoff price is the close. See `docs/SELF_GRADING.md`. The walk-forward still uses last season's median as the line. A saved closing prop price replaces that median only after the market has 1,000 closes (`walkForwardTestLine`). None of the prop markets are there yet. Where a game has a closing spread and total, those are available to the formula. "Stacked" keeps the team-total scale and the defense-yards scale. "Keep total" turns the defense-yards scale off and then multiplies by the unit rating and the sensitivity. "Unit only" drops both scales and uses the unit rating and the sensitivity. The chance below is pulled toward even, the same way the card does it.

| Path | 2025 games | 2025 Brier | 2025 log loss | 2025 chance on over | 2025 actual over | 2025 mean / line | 2026 games | 2026 Brier | 2026 log loss | 2026 chance on over | 2026 actual over | 2026 mean / line |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Stacked | 6,924 | 0.2348 | 0.6623 | 0.494 | 0.402 | 1.240 | 3,948 | 0.2400 | 0.6728 | 0.499 | 0.446 | 1.268 |
| Keep total, add unit | 6,924 | 0.2344 | 0.6613 | 0.491 | 0.402 | 1.225 | 3,948 | 0.2398 | 0.6724 | 0.498 | 0.446 | 1.257 |
| Unit only | 6,924 | 0.2331 | 0.6588 | 0.487 | 0.402 | 1.207 | 3,948 | 0.2391 | 0.6709 | 0.494 | 0.446 | 1.251 |

Unit only is better on Brier and log loss in both seasons than the stacked path and better than keeping the team total. The unshrunk chance was on the over for 43.7% of 2025 lines and 47.1% of 2026 lines. The stacked path was 47.1% and 49.1%. Players cleared the fair line 40.2% of the time in 2025 and 44.6% in 2026.

The card now uses a lognormal curve for yards, then the same 32-game shrink. The shrink keeps the chance inside the existing gap: 10 points, or 15 after a long one-sided record. Receptions stay on the negative binomial. Four candidates beat unit only on both Brier and log loss in both seasons once that gap is applied. Lognormal has the lowest combined Brier, so it is the served chance. Each week in the table is scored with earlier weeks only.

| Path | 2025 games | 2025 Brier | 2025 log loss | 2025 mean chance | 2025 share above 0.5 | 2026 games | 2026 Brier | 2026 log loss | 2026 mean chance | 2026 share above 0.5 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Unit only, before | 6,924 | 0.2331 | 0.6588 | 0.487 | 0.437 | 3,948 | 0.2391 | 0.6709 | 0.494 | 0.471 |
| Lognormal, then shrink | 6,924 | 0.2295 | 0.6515 | 0.467 | 0.317 | 3,948 | 0.2361 | 0.6650 | 0.471 | 0.327 |
| Platt, after shrink | 6,924 | 0.2296 | 0.6516 | 0.441 | 0.214 | 3,948 | 0.2368 | 0.6664 | 0.456 | 0.266 |
| One-number shift, after shrink | 6,924 | 0.2310 | 0.6545 | 0.432 | 0.160 | 3,948 | 0.2385 | 0.6699 | 0.437 | 0.169 |
| Isotonic, after shrink | 6,924 | 0.2296 | 0.6516 | 0.443 | 0.242 | 3,948 | 0.2369 | 0.6667 | 0.452 | 0.285 |

The 2025 mean chance moves from 0.487 to 0.467. Players cleared the line 40.2% of the time in 2025 and 44.6% in 2026. The same comparison is not a profit test and not a pick.

This sample does not reproduce a 73% over rate or a mean 1.47 times the line. Against last season's median, the stacked mean was 1.24 times the line in 2025 and 1.27 times in 2026. The served mean is 1.21 and 1.25. The chance on the card stays near even because 32 games at the book's price are mixed in. The mean is still above the median, which is what a right-skewed counting stat does, and players still finished under that median more often than over. The comparison is not a profit test and not a pick.

An earlier no-price check, without the closing spread and total, picked the same weight 0.25:

| Path | 2025 games | 2025 Brier | 2025 log loss | 2026 games | 2026 Brier | 2026 log loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Stacked, no closing total | 6,924 | 0.2335 | 0.6596 | 3,948 | 0.2395 | 0.6719 |
| Unit factor, weight 0.25 | 6,924 | 0.2331 | 0.6588 | 3,948 | 0.2390 | 0.6709 |

## Game lines

Spreads, totals and moneylines were scored the same way. For each game, the feature is the home club's pass and run offense against the away club's pass and run defense, minus the reverse. Defense yards below the league rate count as a tougher defense. A second feature is recent form: the last three games' margin, or points, minus what the closing line of those games expected, compared with the season residual. Ratings and form use only earlier games. The fit for a week uses only earlier weeks, shrunk toward no effect.

| Path | 2025 covers | 2025 cover Brier | 2025 cover log loss | 2025 moneyline Brier | 2025 moneyline log loss | 2025 total Brier | 2025 total log loss | 2026 covers | 2026 cover Brier | 2026 cover log loss | 2026 moneyline Brier | 2026 moneyline log loss | 2026 total Brier | 2026 total log loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Closing line | 271 | 0.2500 | 0.6931 | 0.2126 | 0.6118 | 0.2500 | 0.6931 | 144 | 0.2500 | 0.6931 | 0.2147 | 0.6207 | 0.2500 | 0.6931 |
| Unit versus unit | 271 | 0.2503 | 0.6938 | 0.2128 | 0.6123 | 0.2501 | 0.6934 | 144 | 0.2502 | 0.6935 | 0.2149 | 0.6212 | 0.2501 | 0.6933 |
| Unit plus recent form | 271 | 0.2511 | 0.6953 | 0.2140 | 0.6150 | 0.2494 | 0.6919 | 144 | 0.2509 | 0.6949 | 0.2153 | 0.6219 | 0.2508 | 0.6948 |

Neither adjustment beat the closing line on covers, moneylines and totals in both seasons. Recent form improved the 2025 total and lost on the 2026 total. Served spreads, totals and moneylines stay on version 2. The tier badge is still shown on the game answer. Version 2's published cover Brier is 0.2502 on a longer sample and it does not claim an edge.

Play-by-play rates were then added beside that unit edge. Each rate uses only earlier regular-season weeks, shrunk toward the league (200 plays, 40 dropbacks, 8 third downs, or 40 pass-rate plays). The fit is the same ridge as the unit edge, with the play rate as a second input. A rate would be served only if it beat the closing number on covers, moneylines, and totals in both seasons.

| Rate added to the unit edge | 2025 cover Brier | 2025 total Brier | 2026 cover Brier | 2026 total Brier |
| --- | ---: | ---: | ---: | ---: |
| Closing line | 0.2500 | 0.2500 | 0.2500 | 0.2500 |
| EPA per play | 0.2511 | 0.2505 | 0.2507 | 0.2488 |
| Success rate | 0.2504 | 0.2505 | 0.2504 | 0.2494 |
| Third-down rate | 0.2500 | 0.2503 | 0.2501 | 0.2491 |
| Pressure rate | 0.2500 | 0.2505 | 0.2511 | 0.2496 |
| Sack rate | 0.2497 | 0.2500 | 0.2507 | 0.2493 |
| Pass rate over expected | 0.2501 | 0.2511 | 0.2513 | 0.2503 |
| Blend of the five defensive rates | 0.2499 | 0.2502 | 0.2506 | 0.2488 |

The sample is 271 games in 2025 and 144 in 2026. EPA and the blend improved the 2026 total and lost on covers. Sack rate improved the 2025 cover and lost in 2026. None beat the closing line on all three markets in both seasons. Served game numbers stay on version 2.

The close itself was then tested as a probability, on the nflverse schedule from 2015 through the latest scored week (`assets/closing-lines.json`). A week is fit only on earlier weeks. The spot model uses key numbers 3 and 7, a favorite of 10 or more, which side is favored, a divisional game, and whether the total is under 41 or at least 52. A second fit adds rest, a dome or closed roof, wind, and cold. That second fit is not eligible to replace version 2, because version 2 already uses rest and weather. The schedule file has no opening number, so a move from the open to the close is unavailable.

| Cover chance | 2025 games | 2025 Brier | 2025 log loss | 2026 games | 2026 Brier | 2026 log loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Flat 50 percent | 271 | 0.2500 | 0.6931 | 145 | 0.2500 | 0.6931 |
| Closing price, no vig | 271 | 0.2496 | 0.6923 | 145 | 0.2497 | 0.6926 |
| Key-number spot | 271 | 0.2477 | 0.6885 | 145 | 0.2507 | 0.6946 |
| Spot plus rest and weather | 271 | 0.2479 | 0.6889 | 145 | 0.2488 | 0.6908 |

The key-number spot beat the flat prior and the closing price in 2025 and lost both in 2026. Adding rest and weather beat both in 2025 and 2026, and lost both in 2024. That fit is not stacked on version 2, because version 2 already moves the close for rest and weather, and this test did not replay version 2's quarterback and injury pieces. The same spot on the total was worse than a flat 50 percent in both seasons (2025 Brier 0.2511, 2026 Brier 0.2521). A moneyline read off the closing price beat a normal curve drawn through the spread in both seasons (2025 Brier 0.2121 against 0.2126, 2026 Brier 0.2110 against 0.2136). That price is the market, not a new model, and the spot moneyline did not beat it in both seasons. None of these paths is served. Version 2 stays the game number. This is not a profit test and not a pick.

A separate file, the public Sportsbook Review odds archive, does have an opening spread and total and one moneyline, through the 2021-22 season (`assets/line-movement-backtest.json`). 3,674 games parsed. Favorites covered the close 48.71 percent of the time on 3,519 decided games, which is the check that the spread sign was read the right way. One 2013 row labeled only "NewYork," against St. Louis, was skipped because the page does not say Giants or Jets. Rows that mix a spread and a total in the same open and close cells were skipped rather than repaired. EndzoneAPI's public pages advertise a free key and player-prop opens and closes since 2023. No account was created, and those historical game opens were not downloaded. The archive has no 2025 or 2026 opening line, so a comparison with version 2 on those two seasons is unavailable.

The movement chance uses the open-to-close spread move and whether that move passed 3 or 7. Totals use the open-to-close total move. A week is fit only on earlier weeks. Covers and totals are compared with a flat 50 percent. Moneylines are compared with the no-vig closing price. It would be served only if covers, totals, and moneylines were all better on Brier and log loss in both 2025 and 2026, with at least 100 games in each. Those seasons are not in the file.

| Archive season | Cover games | Cover Brier | Cover log loss | Flat cover Brier | Total Brier | Flat total Brier | Moneyline Brier | Closing-price Brier |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2019 | 225 | 0.2507 | 0.6946 | 0.2500 | 0.2508 | 0.2500 | 0.2115 | 0.2112 |
| 2020 | 240 | 0.2504 | 0.6938 | 0.2500 | 0.2498 | 0.2500 | 0.2012 | 0.1970 |
| 2021 | 246 | 0.2500 | 0.6932 | 0.2500 | 0.2514 | 0.2500 | 0.2148 | 0.2175 |

The 2020 total was a little better than a flat 50 percent, and the 2021 moneyline was a little better than the closing price. Covers were not better than a flat 50 percent in any of these three seasons. No season here was better on all three markets. Version 2's published cover score is still Brier 0.250187 and log loss 0.693524 on 2,899 games from 2015 through 2026. That number stays the one Coach serves. The chat can still say how a saved line moved. That sentence is a comparison, not a pick.

The same rates were tried on the unit-only prop chance, the path that was served before the lognormal curve. The mean is multiplied by a fixed factor: one typical step is 15 percent, held inside 0.85 to 1.15, with no coefficient fit on the score. The line is still last season's median.

| Prop adjustment | 2025 games | 2025 Brier | 2025 log loss | 2026 games | 2026 Brier | 2026 log loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Unit only, before lognormal | 6,924 | 0.2331 | 0.6588 | 3,948 | 0.2391 | 0.6709 |
| EPA allowed | 6,924 | 0.2330 | 0.6586 | 3,948 | 0.2395 | 0.6719 |
| Success rate allowed | 6,924 | 0.2330 | 0.6586 | 3,948 | 0.2398 | 0.6724 |
| Third-down rate allowed | 6,924 | 0.2335 | 0.6596 | 3,948 | 0.2392 | 0.6713 |
| Pressure rate | 6,924 | 0.2336 | 0.6597 | 3,948 | 0.2400 | 0.6730 |
| Sack rate | 6,924 | 0.2335 | 0.6594 | 3,948 | 0.2398 | 0.6725 |
| Opponent pass rate over expected | 6,924 | 0.2334 | 0.6592 | 3,948 | 0.2393 | 0.6713 |
| Blend of the five defensive rates | 6,924 | 0.2332 | 0.6590 | 3,948 | 0.2397 | 0.6722 |

EPA allowed is a hair better in 2025 and worse in 2026. Nothing beat that unit-only chance on both scores in both seasons. The card stays on the lognormal chance and does not use these rates.

A teammate listed Out can move a target or carry share. That move is shrunk toward no extra share, and a teammate who is no longer Out pulls the recent share back. The Out list is the nflverse weekly report, used only as a pregame list. The same lognormal chance was scored with and without that move. Each week uses earlier games only.

| Path | 2025 games | 2025 Brier | 2025 log loss | 2026 games | 2026 Brier | 2026 log loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Lognormal, no lineup shift | 6,924 | 0.2292 | 0.6509 | 3,972 | 0.2363 | 0.6654 |
| Shrunk lineup shift | 6,924 | 0.2297 | 0.6518 | 3,972 | 0.2359 | 0.6646 |

The shift was worse in 2025 and better in 2026. It is not served. The card can still name a teammate who is listed Out. That sentence does not change the chance.

Weather, pace and rest are not a new prop or total chance. Version 2 already moves an open-roof game total for weather and rest. An earlier week-by-week test of rest and weather on the closing total was worse than a flat 50 percent in both recent seasons. The live forecast is shown with the time it was checked. A missing or old check says unavailable or stale. It is not a pick.

## What changed, including a rematch

The chat answers "why did the Texans beat the Colts so badly after losing earlier?" from `assets/nfl-recent-evidence.json` plus the snap and injury rows in `assets/nfl-matchup.json`. The recent file is generated by `tools/import_recent_evidence.py` from nflverse schedules, team weekly stats, player weekly stats and injuries (CC BY 4.0). The main player bundle still stops at 2026-11-16. Week 11 of 2026 is only in the recent file. Snap counts in the matchup file stop before that week.

The report states scores, closing home margin, total, net yards, rushing yards, giveaways, passing and rushing EPA, rest, head coaches, and the win-loss record in the weeks strictly between the two meetings. A closing home margin is the schedule's `spread_line`: positive means the home club was favored. That matches the app's existing reading of 2024–2026 moneylines. The week 3, 2026 Houston at Indianapolis total in the schedule file is 41.5. A 42.5 total is not what that file says, so the answer uses 41.5.

Net yards are passing yards plus the file's sack-yard figure plus rushing yards. In the 2026 team file, sack yards are negative, and that sum matches the team totals in the source. Third-down rate, success rate, pressure and pass rate over expected come from `assets/play-units.json`, built by `tools/build_play_units.py` from the nflverse play-by-play release (CC BY 4.0). A third down is a converted flag divided by converted plus failed, and a no-play is excluded. For week 11 of 2026, that file has Houston at 8 of 14 and Indianapolis at 1 of 11. The answer prints those counts from the file. If the play file is missing, the answer says the rate is unavailable.

## What the files can and cannot name

The injury report and the later player row can show a player who was Out, then has a counting stat. Snap counts can show a player whose club changed between the meetings. The Texans–Colts card uses those two tests. It calls a club change a snap-count team change. It calls that change a trade only when `assets/nfl-trades.json` names the player, the two clubs, and a date strictly between the meetings. The file is the nflverse trades list (CC BY 4.0). A snap change with no row stays "not a trade."

These files do not name a general manager or a firing. The public ESPN transactions list returned no rows, so a front-office change stays unavailable. They cannot say that Chris Ballard was fired. Head coaches come from the nflverse schedule. Both meetings in the loaded 2026 file list the same two head coaches.

Practice participation without a game status is not called an inactive designation. Questionable is not called Out.

## Sources

- nflverse schedules, team stats, player stats, injuries and snap counts, CC BY 4.0, via the generator and `assets/nfl-matchup.json`.
- nflverse trades, CC BY 4.0, in `assets/nfl-trades.json`. A pick with no player name is left out.
- NFL game books and Colts.com trade recaps are not in the free files. They are not quoted. The public ESPN transactions list returned no rows.
