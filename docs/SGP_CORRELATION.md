# Same-game parlay correlation

Status: **measured. No book is shown to misprice these pairs. Not a pick.**

## The idea

A same-game parlay (SGP) pays one price for several legs. Legs from the same
game are not independent: when a quarterback throws for a lot, his top
receiver usually does too. A book that priced such legs as if they were
independent would pay too much. This measures how strongly common pairs move
together.

**Lift** = the chance both legs hit ÷ (chance of leg A × chance of leg B).
Lift 1.00 means independent. Against a book that ignored the correlation, a
two-leg parlay at fair leg prices would be worth about lift − 1.

## Data

`model/sgp_correlation.py` on nflverse box scores, 2023 to week 11 of 2026
(about 1,700 team-games per pair). Each player's line is the average of his
previous 8 games (at least 4), so roughly half the overs hit. Roles (QB, RB1,
WR1, WR2, TE1) come from earlier games only. Results:
`research/sgp-correlation/lift.json`.

| Pair (same game) | Lift | 90% range |
| --- | --- | --- |
| QB passing over + his WR1 receiving over | 1.29 | 1.24 to 1.33 |
| QB over + WR2 over | 1.25 | 1.20 to 1.29 |
| QB over + TE1 over | 1.21 | 1.17 to 1.26 |
| WR1 over + other team's QB over | 1.05 | 1.01 to 1.09 |
| QB over + other team's QB over | 1.04 | 1.00 to 1.08 |
| QB under + his RB1 rushing over | 1.08 | 1.04 to 1.13 |
| WR1 over + WR2 over (same team) | 1.01 | 0.96 to 1.06 |
| QB over + his RB1 over | 0.93 | 0.89 to 0.97 |

## What this means

- The quarterback-to-receiver stack is a real, large correlation (about 29%
  more likely than independent).
- DraftKings, FanDuel and the other big books price SGPs with their own
  correlation models and a bigger margin, so this lift is mostly already
  charged for. No free source has SGP prices, so Coach cannot check which
  book under-adjusts.
- The usable rule: a fair SGP price is (fair chance A × fair chance B × lift).
  If a book's SGP offer pays more than that, it's worth a look. Fair leg
  chances come from the no-vig prices Coach already saves.
- Pairs with lift below 1 (QB over + his own RB over) are negatively
  correlated, so books often overcharge less on them, but they are also less
  likely to hit together.

## Next step

Show the fair SGP price for two-leg same-game combinations in the parlay
answer, so you can compare it with the book's SGP offer yourself.
