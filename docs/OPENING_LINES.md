# Betting the opening line

Status: **no edge. Not a pick.**

## The question

Opening lines are posted days before kickoff with low limits and are softer
than closing lines. If Coach's ratings disagree with an opener, does the line
then move toward Coach far enough to beat the closing line?

## Data

- Opening and closing spreads and totals, 2007–2021, from the free Sportsbook
  Reviews Online archive (one consensus number per game). 3,144 regular-season
  games from 2008 to 2021 match the nflverse schedule; the archive's close is
  within a point of nflverse's close in 96.5% of games.
- Coach's number: the walk-forward team ratings from
  [ELO_RATINGS.md](ELO_RATINGS.md) (`model/elo_backtest.py`). Each week is fit
  only on earlier weeks, and the closing line is never an input.
- **Quarterback**: the ratings normally use the quarterback who actually
  started. An opener is posted before injury news, so this test uses the
  team's previous starter instead. That matters a lot (see below).

Script: `model/opening_line_backtest.py`. Results:
`research/opening-line/backtest.json` (and `backtest_actual_qb.json` for the
look-ahead comparison).

## How it is scored

Rule: when Coach's margin (or total) differs from the opener by at least K
points, bet Coach's side at the opener at −110.

Closing line value (CLV): the chance that bet wins, judged by the closing
number and how results have spread around closing numbers in earlier seasons
(so key numbers like 3 and 7 count), times the −110 payout, minus one. A bet
with no edge at −110 has CLV of about −4.5%.

## Results (2008–2021)

The line does move toward Coach: the correlation between (Coach − opener)
and (close − opener) is 0.30 for spreads and 0.32 for totals. But it moves
only about a fifth of the gap, which is not enough to pay the −110 margin.

| Spreads, gap ≥ | Bets | CLV (90% range) | Seasons with positive CLV |
| --- | --- | --- | --- |
| 1 | 2,243 | −1.1% (−1.6% to −0.6%) | 3 of 14 |
| 2 | 1,469 | −0.7% (−1.3% to −0.1%) | 4 of 14 |
| 3 | 924 | +0.2% (−0.7% to +1.0%) | 7 of 14 |
| 4 | 536 | +0.6% (−0.6% to +1.8%) | 6 of 14 |

| Totals, gap ≥ | Bets | CLV (90% range) |
| --- | --- | --- |
| 1 | 2,496 | −2.4% |
| 2 | 1,919 | −2.0% |
| 3 | 1,420 | −1.4% |
| 4 | 965 | −0.8% (−1.5% to −0.2%) |

Totals show a positive win/loss result at the opener (+6.1% at gap ≥ 4)
despite negative CLV. The totals model uses game-day wind and temperature,
which were not known when the opener was posted, so that result is not
trusted.

## The quarterback lesson

With the actual starter (look-ahead), spreads at gap ≥ 4 show **+3.0% CLV
(+1.8% to +4.1%), positive in 10 of 14 seasons**. Using the previous starter
drops that to +0.6%. Almost all of the apparent edge was quarterback news the
opener did not have yet. So the opener isn't beatable from ratings alone, but
**reacting to quarterback news before the line moves** is worth a lot. That
is the case for the news-speed phase.

`quarterbackNews` in the results file measures it directly. In 626 games a
team started a different quarterback than in its previous game. Those lines
moved 2.05 points from open to close on average, against 1.30 points for
other games. Betting the side the change favors at the opener, judged by the
close:

| Coach's rating swing from the change | Bets | CLV (90% range) | Result at the opener |
| --- | --- | --- | --- |
| ≥ 1 point | 415 | +0.9% (−0.6% to +2.4%) | +3.7% |
| ≥ 2 points | 233 | +2.3% (+0.3% to +4.4%) | +11.2% |
| ≥ 3 points | 126 | +4.4% (+1.5% to +7.1%) | +12.4% |

This is an upper bound. It assumes Coach saw the change before the line
moved, and some changes were already known when the opener went up. It shows
what speed on quarterback news is worth, not that Coach has that speed.

## Limits

- One consensus number per game, not the softest book's opener.
- Openers from 2007–2021 only. The archive stops after the 2021 season.
- Vig is assumed at −110 on every opener.
