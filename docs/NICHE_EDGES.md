# Niche edges: nine ideas, tested and logged live

Status: **research and live logging. Nothing here changes Coach's picks.**
Each idea is an extra signal. It becomes a pick only after 200 live bets
scored against the closing line with closing line value (CLV) clearly above
zero (`line_shop.gate`), the same rule as docs/FREE_SIGNALS.md.

All data is free: nflverse schedules and weekly player stats (CC BY 4.0), the
Sportsbook Reviews Online archive (2007–2021 opening and closing lines and
quarter scores), the PropLine sample (CC BY 4.0), the Worker's logged-out
FanDuel, Bovada and BetRivers props, the saved Odds API snapshots, Open-Meteo,
and SportsBettingDime's public splits feed. "Backup players stepping in" is
handled in its own thread and is not repeated here.

How to read the numbers: game angles are tested on 2007–2014 ("find") and
checked on 2015–2021 ("check"). CLV is the value of the bet at the opener,
judged by the closing number. A random side at the opener averages about
−4.5% (the bookmaker's margin), so anything near zero is already "better than
random" but still not a bet. Player angles have no free historical prop lines,
so they use a proxy line (the player's median over his previous 10 games) and
report **lift**: the angle's hit rate minus the hit rate of the same bet on
every player-game.

## Results

| # | Idea | Backtest | Live log |
|---|---|---|---|
| 1 | Prop lines that don't move when the matchup does | 2026 weeks 2→3, 55 props: **lost badly** at the fair close (−31%, range −52% to −10%). Books were right not to move. | `niche_watch.py`, angle "sticky line" |
| 2 | Fade the public / follow the money | No free history of splits with lines. Earlier public-bias tests (18 rules) found nothing. | `public_splits.py` (signals only) |
| 3 | Turf, dome, altitude | Game totals: dome, turf, Denver: **no edge**. Freezing games: under CLV −0.4% / +0.9% (near zero). Players' own turf/indoor splits: lift +0.6% to +0.8%, not clear, and **lost** on 2026 closes. **Visiting players at Denver: under lift +6.3% / +2.9%, clear in both periods** (proxy line); the same Denver defense away from altitude shows nothing. | `niche_watch.py` |
| 4 | Revenge games and milestones | QB or head coach vs a former team: **no edge**. Player vs a former team: no lift. Player within reach of 1,000 rushing/receiving or 4,000 passing yards in the last two weeks: over lift +7.0% / +4.2% (**lead**, proxy line, about 200 bets in each period). Contract incentives: **skipped, no free source.** | `niche_watch.py` |
| 5 | Which book is slowest | PropLine: BetWay, Courtside and Dabble barely follow Pinnacle's moves; BetRivers and Fanatics on passing yards and BetMGM across props follow less than a third. But betting the side Pinnacle moved toward at the slow book's close was still **negative** after the margin at every real sportsbook. Only DFS pick'em apps (PrizePicks, Dabble) showed positive value, and their posted prices are not true odds. | `book_lag.py` (live lag per book, stale prices) |
| 6 | Short weeks and Thanksgiving | Thursday unders and home sides, Thanksgiving, rested vs short-rest teams: **no edge**. Player props on Thursday/Thanksgiving: no lift. | `niche_watch.py` |
| 7 | Kickers in wind or cold | Kicking points (3 × field goals + extra points) in 15+ mph wind or 32°F or colder: under lift **+4.6% / +4.7%, clear in both periods**; about 0.5–0.7 points below the kicker's median. Strongest for the better long-range kickers (+9.8% / +9.4%) because their usual numbers are higher. Proxy line only: **no free kicker prop prices** (not in the Odds API free markets or the Worker feed), so live alerts are logged without a price until a source exists. | `niche_watch.py` |
| 8 | First quarter / first half from scripted drives and coach tendencies | No free first-half lines. Against a proxy line (closing total × the league's first-half share), team and coach early-scoring history **lost** in the check period (hit rate 49–50%). | Not logged: no free first-half prices to log against. |
| 9 | Late-season motivation | Team out of the race (approx.): **no edge** either side. Final week, betting **against** a team likely to rest starters (75%+ win rate): CLV +5.0% / +5.6% (**lead**, only 40 games, range includes zero). | `niche_watch.py` |

The full numbers are in `research/niche/game_angles.json`,
`research/niche/player_angles.json` and `assets/book-lag.json → backtest`.

### What looks worth watching

- **Visiting players at Denver, unders** (passing, rushing, receiving
  yards and receptions). Clear on the proxy line in both periods, and the
  control (the same Denver defense at the visitor's own stadium) shows nothing,
  so it looks like altitude, not the defense. Not yet tested on real closing
  lines (only 12 such 2026 props in the sample).
- **Kicking points unders in wind or cold.** Clear on the proxy line, but
  there is no free price to test against yet.
- **Milestone overs** and **fading teams that may rest starters in the final
  week.** Leads with small samples.

Everything else is either no edge or a loss, and stays as information.

## Live logs

All three run hourly in `.github/workflows/niche-watch.yml` with free sources
only and no Odds API credits. Each alert keeps the bet and the best price when
first seen; after kickoff it is scored by `tools/edge_log.py` against
Pinnacle's close, or against the median no-vig close of the books we saved
when Pinnacle has no close (most player props). Each file has a summary per
angle with the 200-bet gate.

- `assets/niche-watch.json` — ideas 1, 3, 4, 6, 7, 9. Game angles use the
  side that did better in the backtest (for example, against the team that may
  rest starters).
- `assets/public-splits.json` — idea 2. Fade the side with 70%+ of bets;
  follow the side whose share of money is 15+ points above its share of bets.
  Only the signal and a bucket ("70–80%") are stored, never the raw numbers,
  and nothing is shown in the app (docs/PUBLIC_SHARP.md: no free source grants
  a display right).
- `assets/book-lag.json` — idea 5. Median hours each book takes to match a
  line move made first by two or more books, per market, and books still on
  the old number now (logged as a bet on the side the stale number favors).

## Rebuild

```
python model/niche_backtest.py           # needs model/.cache/games.csv and the SBR archive
python model/player_angles_backtest.py   # needs model/.cache/stats/stats_player_week_YYYY.csv
python tools/book_lag.py --backtest --propline model/.cache/propline.csv.gz --book-prices <worker json>
```
