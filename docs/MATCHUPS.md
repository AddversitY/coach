# Matchups and what changed

Checked November 20, 2026. The numbers below come from the files Coach loads. They are not typed in as a story. Player-prop prices are not in those files, so the prop test uses last season's median as the line.

## Unit ratings

`lib/domain/unit_ratings.dart` builds a rating for a week from regular-season player box scores in earlier weeks only. A game in week 11 cannot move the rating used for week 11.

The inputs are yards per pass attempt, yards per carry, yards per target against wide receivers, tight ends and running backs, and sacks per dropback. Play-by-play EPA, pressures, success rate and pass rate over expected are not in those rows, so they are not filled in. The team weekly file's passing and rushing EPA is used only in the rematch card, and that EPA includes the value of turnovers on those plays.

Each team-week rate is shrunk toward the league rate, then adjusted for the opponents already faced. Clubs with fewer than three earlier games stay unranked. When at least 24 clubs are ranked, Elite is the top 8 and Weak is the bottom 8. With fewer clubs, the cut is about a quarter of the clubs at each end. The rest are Average.

A player's splits use the opponent's tier at the time of each earlier game. A tier with fewer than eight games is shrunk toward that player's own average and labeled a small sample.

## Projections

The served prop chance is the usage model with one opponent adjustment. The adjustment is the opponent's unit rating, clamped between 0.85 and 1.15, times the player's own elite-to-weak sensitivity, shrunk toward no extra response and clamped between 0.94 and 1.06. Recent form uses weight 0.25. The team-total scale and the raw defense-yards scale are not applied on top of that. Passing `environment: null` still keeps the old stacked factors, and the projection tests cover that path. The card does not claim a betting edge.

There is no historical file of player-prop prices. The walk-forward uses last season's median as the line. Where a game has a closing spread and total, those are available to the formula. "Stacked" keeps the team-total scale and the defense-yards scale. "Keep total" turns the defense-yards scale off and then multiplies by the unit rating and the sensitivity. "Unit only" drops both scales and uses the unit rating and the sensitivity. The chance below is pulled toward even, the same way the card does it.

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

## What changed, including a rematch

The chat answers "why did the Texans beat the Colts so badly after losing earlier?" from `assets/nfl-recent-evidence.json` plus the snap and injury rows in `assets/nfl-matchup.json`. The recent file is generated by `tools/import_recent_evidence.py` from nflverse schedules, team weekly stats, player weekly stats and injuries (CC BY 4.0). The main player bundle still stops at 2026-11-16. Week 11 of 2026 is only in the recent file. Snap counts in the matchup file stop before that week.

The report states scores, closing home margin, total, net yards, rushing yards, giveaways, passing and rushing EPA, rest, head coaches, and the win-loss record in the weeks strictly between the two meetings. A closing home margin is the schedule's `spread_line`: positive means the home club was favored. That matches the app's existing reading of 2024–2026 moneylines. The week 3, 2026 Houston at Indianapolis total in the schedule file is 41.5. A 42.5 total is not what that file says, so the answer uses 41.5.

Net yards are passing yards plus the file's sack-yard figure plus rushing yards. In the 2026 team file, sack yards are negative, and that sum matches the team totals in the source. Third-down rate is not in the team file. The answer says third-down rate is unavailable. It does not print 8-for-14 or 1-for-11.

## What the files can and cannot name

The injury report and the later player row can show a player who was Out, then has a counting stat. Snap counts can show a player whose club changed between the meetings. The Texans–Colts card uses those two tests. It calls a club change a snap-count team change.

These files do not name a general manager, a firing, or a transaction. They cannot say that Chris Ballard was fired or that a player was traded. A sentence that needs a trade recap from Colts.com, an ESPN transaction note, or an NFL game book stays unavailable. Snap share is the evidence that can be detected. Head coaches come from the nflverse schedule. Both meetings in the loaded 2026 file list the same two head coaches.

Practice participation without a game status is not called an inactive designation. Questionable is not called Out.

## Sources

- nflverse schedules, team stats, player stats, injuries and snap counts, CC BY 4.0, via the generator and `assets/nfl-matchup.json`.
- NFL game books, ESPN transaction notes and Colts.com trade recaps are not in the free files. They are not quoted, and the answer does not invent them.
