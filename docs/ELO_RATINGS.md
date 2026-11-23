# Coach ratings (team and player Elo)

Vincent asked (Nov 22, 2026) for an Elo-style rating for every team and every
player, like the video games, built only from math and free data, with the
ratings tied together: a receiver against the defense covering him, plus the
secondary and the quarterback. This page says what was built, how it was
tested, and what the test found.

**Result in one line:** the ratings come out sensible (they track the books'
own lines very closely), but they do **not** beat the closing line, for games
or for props. Under rule 6 (beat it in both 2025 and 2026) they are **not
adopted** into any chance the app shows.

## What was built

All code is in `model/`. Inputs are free nflverse files (CC BY 4.0):
play-by-play 2006-2026, snap counts 2013-2026, the players table, and the
schedule with closing spreads, totals and moneylines.

Every rating is a number plus an "how sure are we" spread (a Kalman filter,
which is Elo with uncertainty). After each game, every rating that took part
moves toward what happened. Ratings we are unsure about move more. Between
seasons, every rating is pulled part of the way back to average.

| File | What it rates |
| --- | --- |
| `elo_ratings.py` | Teams: pass offense split into **quarterback + supporting cast**, pass defense, run offense, run defense, special teams, and a points (margin) Elo. A pass play updates the passer, his cast and the opposing pass defense together. |
| `elo_players.py` | **Every player who takes a snap**, offense and defense, pass and run. Each game, a team's EPA per play is the sum of its players' ratings times their snap share, minus the same for the 11 defenders. A team's number for a game is the sum over the players expected to be active, so injuries move it. |
| `elo_props.py` | Prop skills. Every target is one observation of *yards = position average + receiver + passer + that defense against WRs/TEs/RBs*. The same for catches, passer yards per attempt and rusher yards per carry. Opportunity is rated too: target share, carry share, and each team's attempts and carries against each opponent. |
| `elo_backtest.py` | Week-by-week walk-forward test of the game side. |
| `elo_report.py` | Runs everything, writes `research/elo-ratings/`. |

The few tuning choices for the team model (how fast ratings move, how much
carries over between seasons) were picked on 2009-2014 games only. The
player-rating settings were checked on 2015-2018. Later seasons were not
used to choose anything.

### What free data cannot do

Free data does not say **which defender covered which receiver**. That is
paid charting (PFF, Next Gen Stats). The on-field list of all 22 players
(nflverse participation) exists for 2016-2025 but is **not posted for 2026**.
So the receiver is matched against the defense as a unit (by position he
plays), and individual defenders are rated from snap shares. Teammates who
are always on the field together share credit (for example, two starting
receivers on a good passing team both rate high). That is a known limit of
this kind of rating.

## The test

Walk-forward by week: to score week W, ratings and every fit use only games
before week W. Same-week games are never used.

### Games (spread, total, moneyline)

From `research/elo-ratings/game_backtest.json`, team + player version:

| Seasons | Games | Margin error, ratings | Margin error, closing line | Cover Brier (ratings on top of line) | Win Brier, market | Win Brier, market + ratings |
| --- | --- | --- | --- | --- | --- | --- |
| 2015-2024 | 2,743 | 13.03 | 12.77 | 0.2501 | 0.2123 | 0.2125 |
| 2025 | 285 | 12.84 | 12.25 | 0.2516 | 0.2111 | 0.2118 |
| 2026 (wk 1-11) | 159 | 12.11 | 11.90 | 0.2484 | 0.2066 | 0.2060 |

- The closing line is closer to the final score every season.
- Using the gap between our number and the line to call covers is a coin
  flip (0.25 is a coin).
- Adding ratings to the moneyline makes the win chance worse in 2015-2024
  and 2025, and very slightly better in 2026 (159 games, well inside noise).
  That fails the both-seasons rule.
- Adding the player ratings to the team ratings helped the margin a little
  in 2015-2024 (13.07 to 13.03) and not at all in 2025 or 2026.

### Props

From `research/elo-ratings/prop_backtest.json`. 1,404 two-sided props, all
2026: 1,004 PropLine closes (weeks 2-3) and 400 props the Worker collected
from FanDuel, Bovada and BetRivers before kickoff on Nov 22 (week 11),
scored from nflverse play-by-play.

| | Props | Books no-vig | Ratings alone | Pooled, 5% ratings |
| --- | --- | --- | --- | --- |
| PropLine | 1,004 | 0.2514 | 0.2754 | 0.2518 |
| Worker (week 11) | 400 | 0.2486 | 0.2656 | 0.2485 |
| All | 1,404 | 0.2506 | 0.2726 | 0.2509 |

- Our projections line up with the books' lines (correlation 0.98 on these
  props), so the ratings are measuring the right things.
- But where we differ from the line, the line was right more often. A test
  of whether our gap from the line predicts the over found nothing (95%
  range of the effect included zero, and fitting on one set and testing on
  the other made both worse).
- The books themselves are barely better than a coin on props (0.2506 vs
  0.25). Props are noisy; beating them needs either information the books
  do not have yet, or far more data than 1,404 props to show a small edge.
- There are no free 2025 two-sided prop closes, so the both-seasons rule
  cannot be met for props yet anyway.

## What this means

The closing line already contains everything these ratings know, plus
injury news, weather updates and sharp money. A rating system built from
public box-score data, however detailed, ends up re-deriving the line. That
matches every published attempt we know of.

Where an edge could still come from (all free):

1. **Earlier lines.** Ratings may beat the *opening* line even if not the
   close. The Worker already saves prop prices from 24 hours before
   kickoff onward, so ratings can be tested against those earlier prices
   once a few weeks are saved.
2. **More prop closes.** Keep grading the Worker's saved prices each week.
   With a few thousand props a small edge can be measured, if one exists.
3. **Participation data for 2026**, if nflverse posts it, would let the
   defender ratings use exact on-field lists instead of snap shares.

## Player ratings from every free variable (Nov 23)

Vincent asked for player ratings built from as many variables as possible,
plus physical traits like the video games use. `model/elo_skill.py` does
this for quarterbacks, running backs, receivers and tight ends.

Before each game, everything a player did in earlier games is summarized.
All seasons count, recent games count more (half weight after 16 games, and
an extra fade each new season), and small samples are pulled toward the
position average. The inputs:

- **Opportunity:** snap share, target share, air-yard share, targets per
  pass play on the field, red-zone target share, carry share and goal-line
  carry share.
- **Efficiency:** yards per target, EPA per target, first downs per target,
  catch rate, depth of target, yards after catch, touchdowns per target,
  yards per carry, rushing EPA and success rate. For passers: EPA per
  dropback, yards per attempt, sack rate, interception rate, completion %
  over expected and depth of throw.
- **Next Gen Stats (2016+):** separation, cushion, YAC over expected,
  rushing yards over expected, rushing efficiency, time to throw and
  aggressiveness.
- **Context:** the quality of his quarterback, the defenses he faced, age,
  years in the league and draft slot.

A ridge regression learns each input's weight from what predicted the
**next** game's production per opportunity: receiving yards per team pass
play for WRs and TEs, scrimmage yards per team play for RBs, and EPA per
dropback for QBs. The weights were learned on 2013-2022 and tested on
2023-2026. The overall is that prediction's percentile within the position.
The weights are in `research/elo-ratings/skill_weights.json`.

Out-of-sample R² (share of next-game variation explained), new rating vs a
two-variable rating:

| Position | 2023 | 2024 | 2025 | 2026 |
| --- | --- | --- | --- | --- |
| WR | 0.391 vs 0.267 | 0.380 vs 0.244 | 0.374 vs 0.253 | 0.363 vs 0.279 |
| TE | 0.414 vs 0.301 | 0.422 vs 0.318 | 0.429 vs 0.304 | 0.438 vs 0.350 |
| RB | 0.467 vs 0.455 | 0.489 vs 0.486 | 0.493 vs 0.481 | 0.494 vs 0.469 |
| QB | 0.119 vs 0.097 | 0.079 vs 0.071 | 0.122 vs 0.051 | 0.145 vs 0.090 |

The new rating predicts better in every season at every position.

**Physical traits.** NFL Scouting Combine results (40-yard dash, vertical,
broad jump, 3-cone, shuttle, bench press, height and weight, via nflverse)
were tested as inputs too. In most seasons they made predictions slightly
**worse** once
on-field data was in, so they are not in the overall. They are shown as
traits instead.

**Against the books.** On 282 2026 WR/TE receiving-yard props,
the books' Brier score was 0.2499 and the new rating alone
scored 0.2675. A 5% blend scored 0.2496,
which is within noise. Better player ratings still do not beat the closing
prop line.

**Defenders** are rated by their on-field rating plus measured production
per snap. Pass rush counts sacks (×3) and QB hits. Coverage counts
interceptions (×2) and passes defended. Run stopping counts tackles for loss
(×2), solo tackles (×0.5) and forced fumbles. These weights were set by
hand, not learned, because there is no clean per-defender target to learn
them from.

### Traits (Madden-style, measured only)

Each trait is a 40-99 percentile within the position:

- **Receivers and tight ends:** Speed (40), Agility (3-cone and shuttle),
  Jumping (vertical and broad), Strength (bench), Size, Separation, Catching,
  Yards after catch, Deep threat, Earning targets, Red zone, Durability.
- **Running backs:** Speed, Agility, Jumping, Strength, Size, Vision (rushing
  yards over expected), Rushing, Catching, Yards after catch, Durability.
- **Quarterbacks:** Speed, Size, Accuracy (completion % over expected),
  Decisions (avoiding interceptions), Pocket (avoiding sacks),
  Aggressiveness, Quick release, Deep threat (depth of throw), Rushing,
  Durability.
- **Defenders:** Speed, Agility, Jumping, Strength, Size, Pass rush,
  Coverage, Run stopping, Durability.

Durability is the share of his team's games he played, this season plus
half of last season.

**What free data cannot cover:** in-game top speed and acceleration
(tracking data is not public per player), 10-yard splits, hand size and arm
length for most players, route-by-route grades, press and man/zone coverage
grades, blocking grades, awareness, play recognition, injury severity and
medical history beyond the weekly injury report. A trait with no
measurement (for example, a player who skipped a combine drill) is left
blank, not guessed. We do not copy any video game's ratings.

## Every position, and line-vs-line matchups (Nov 23)

`model/elo_trenches.py` adds:

- **Offensive linemen.** Pass block uses sacks plus QB hits per dropback, run
  block uses stuffed runs (no gain or a loss), and run push uses run success.
  Every lineman on the field is updated by his snap share against the
  opposing front. The quarterback is in the pass-block measure too, because
  some sacks are his. The overall mixes these three with the on-field
  rating.
- **The defensive front** (DE, DT, NT, OLB, ILB, MLB) uses the same three
  measures from the other side (pocket pressure, run stuffing, run fits).
  These are added to the on-field rating and measured production.
- **Kickers:** field goals made over the league rate at that distance,
  range (50+ yard makes) and extra points.
- **Punters:** net yards over average from the same spot, and inside-the-20
  rate.
- **Team line units:** each team's pass block, run block, pass rush and run
  defense, from its most recent lineup. Game answers show them side by side,
  for example "BUF pass block 84 vs MIA pass rush 64".

Free data has no per-play pressure for 2026 and no yards before contact, so
sacks, hits and stuffs stand in for those. Pregame pass-block edges
correlate 0.27-0.40 with the next game's actual sack-plus-hit gap (2016,
2020, 2024, 2025 and 2026).

Game test with everything added, ratings alone (margin / total error, points):

| | 2015-2024 | 2025 | 2026 |
| --- | --- | --- | --- |
| Team only | 13.07 / 13.73 | 12.84 / 13.71 | 12.07 / 14.22 |
| + players | 13.03 / 13.55 | 12.84 / 13.30 | 12.11 / 13.72 |
| + line matchups | 13.04 / 13.57 | 12.83 / 13.25 | 12.03 / 13.67 |
| Closing line | 12.77 / 13.29 | 12.24 / 13.24 | 11.90 / 13.14 |

The line matchups make the ratings' own totals clearly better. In 2025 the
total error, 13.25, nearly ties the closing total
(13.24). They still do not beat the closing number. Over/under Brier
on top of the line was 0.2501, 0.2499, 0.2521 (a coin flip is 0.25). Win Brier for
market plus ratings vs market alone was 0.2126 vs 0.2123; 0.2119 vs 0.2111; 0.2055 vs 0.2066. That is better only
in 2026, so it fails the both-seasons rule, and nothing is adopted.

## In the app

Vincent asked (Nov 23) to show the ratings as **one more number to weigh**,
not a replacement. Nothing about Coach's chances, lines or prop math changed.

- `assets/elo-ratings.json` is a compact copy of the current ratings, read by
  `lib/domain/elo_ratings.dart`.
- On a game or player answer, a **Coach ratings (Elo)** section opens under the
  card: both teams' overall, offense and defense, the points gap on a neutral
  field, the line-vs-line matchups, both quarterbacks, both secondaries, and for a player his overall,
  his skill ratings, the opponent's pass defense rank against his position,
  the opponent's secondary, his quarterback and his measured traits.
- Direct questions work too: "what's Justin Jefferson's elo against the
  Bears", "coach ratings Bills Chiefs", "top rated corners", "best teams by
  elo", "top rated offensive linemen", "best rated pass rushers", "top rated
  kickers".
- Every ratings answer carries the note that they are not part of the chance
  and did not beat the closing line.
- The weekly model workflow (Tuesday) rebuilds the ratings and commits them.

## Current ratings

`research/elo-ratings/ratings_current.json` holds every team and every player
with 100+ snaps this season, with an overall from 40 to 99 (percentile within
position; teams within the league), plus the detail behind it: EPA per play,
yards per target, catch rate, target share, yards per carry, and each
defense's yards allowed per target against WRs, TEs and RBs. These are
descriptive, not picks.

To rebuild (downloads about 450 MB of nflverse files into the cache):

```
python model/elo_report.py --cache model/.cache/nflverse --schedule model/.cache/games.csv
```

The schedule file is `https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv`.
