# Handoff to Cursor (November 28, 2026)

Vincent Mamone (GitHub `AddversitY`) is handing Coach to Cursor. This page is
the starting point: what Coach is, how it is built, how to run and test it,
what has been measured against the sportsbooks, and what to do next. It is
[HANDOFF_CODEX.md](HANDOFF_CODEX.md) (Nov 23) brought up to date with `main`
on Nov 28. It links to the detailed docs instead of repeating them.

Where something could not be checked it says **unknown**.

## Who you are working for

- Vincent is not a programmer and mostly reads on his phone. Use plain words,
  short sentences, and one question at a time. He is in US Eastern time.
- He has said to push and merge on your own once tests pass (open a PR,
  let CI go green, merge it, then tell him in one or two plain sentences).
- Goal in his words: a simple chat interface with depth equal to or better
  than Outlier, OddsJam and PropsBot.AI. What matters most is the best
  parlays and straight bets, and suggestions that are more reliable than
  asking a standard AI.

## Rules (Vincent's, do not break)

1. **Free data only.** No paid data plans, trials or signups without his yes.
   The Odds API stays on the free 500-credit plan; don't add calls outside the
   caps in `tools/line_timing.py` and the backend quota.
2. **NFL only.**
3. **Never commit keys or passwords.** Only variable names go in the repo.
   Secrets live as Windows user env vars, Cloudflare Worker secrets and GitHub
   Actions secrets.
4. **Never invent numbers.** Missing data shows as "unavailable".
5. **Model changes ship only if they win a week-based walk-forward test in
   both the 2025 and 2026 seasons** (Brier and log loss), or for betting
   signals, only if they beat the **closing line** (positive CLV) out of
   sample. Otherwise write it up and leave it off. Elo ratings are shown as an
   extra metric only.
6. Scraping logged-out sportsbook and public-betting pages is allowed by
   Vincent. Signed-in scraping is not the plan.

## What Coach is

An NFL betting research assistant you chat with. Ask about a game, spread,
total, moneyline, player prop or parlay, and Coach answers with forecasts,
evidence, ratings and saved sportsbook prices, framed as "a comparison, not
a pick".

- Public app: https://addversity.github.io/coach/ (Flutter web on GitHub Pages)
- Repo: https://github.com/AddversitY/coach (default branch `main`)
- Worker: https://coach-research.dds-dge.workers.dev

## Architecture

| Part | Where | What it does |
| --- | --- | --- |
| Flutter app | `lib/`, `test/` | The chat UI (web, Windows, iOS from one codebase). Answers are built in Dart from bundled `assets/*.json` plus live Worker routes. Flutter **3.47.7**. |
| Cloudflare Worker | `hosting/` (`worker.mjs`, `wrangler.jsonc`, name `coach-research`) | Workers AI interprets questions, a SQLite Durable Object (`CoachState`) stores state, and a `*/2` cron collects logged-out props from FanDuel, Bovada and BetRivers. Serves `/v1/book-prices`, `/v1/ingest`, `/health`. |
| Odds API | `backend/` (local Dart server), `tools/price_history.py`, `tools/line_timing.py` | Game prices from 10 books incl. Pinnacle (one region, 3 credits per call) at T-24h/6h/3h/90m/30m/~10m. |
| Python models | `model/` | nflverse data (CC BY 4.0) into Coach's Line, prop projections, Elo ratings, backtests. Writes JSON into `assets/` and `research/`. |
| Python tools | `tools/` | Evidence refresh, price history, closing lines, self-grade, line shopping, QB news, weather and Kalshi watch, home DraftKings collector. |
| GitHub Actions | `.github/workflows/` | `price-history.yml` (every 30 min), `news-watch.yml` (every 10 min), `niche-watch.yml` (hourly), `refresh-evidence.yml` (daily), `nfl-model.yml` (PRs + Tuesdays), `publish-preview.yml` (Pages on push to main), `ios-build.yml`. The bots commit refreshed `assets/*.json` straight to `main`. |

Key data files in `assets/`: `nfl-model.json` (Coach's Line), `price-history.json`,
`closing-lines.json`, `accuracy-scorecard.json`, `suggestion-log.json`,
`line-shop.json`, `qb-news.json`, `prediction-markets.json` (Kalshi),
`weather-watch.json`, `elo-ratings.json`, `prop-closes.json`, `self-grade.json`.

## Run, test, deploy

```bash
# Flutter (needs Flutter 3.47.7; not in a bare cloud box)
flutter pub get && flutter analyze && flutter test

# Worker tests (Node 22+)
cd hosting && npm ci && npm test

# Python tools and models (pip install -r model/requirements.txt first)
python -m unittest discover -s tools -t tools
python -m unittest discover -s model -t model
```

- Last run on `main` (Nov 28): tools 176/176 pass; hosting 155/157 pass.
  The 2 failures are in `hosting/answer-quality.test.mjs` and were already
  failing on Nov 23 (not yet fixed; a good first task). Flutter and model
  suites were not run in the cloud box (no Flutter 3.47.7 / model deps).
- Windows setup: `.\tools\setup.ps1` then `.\tools\flutter.ps1 run -d windows`.
  More in [DEVELOPMENT.md](../DEVELOPMENT.md).
- Web deploy: automatic. Merging to `main` runs `publish-preview.yml`.
- Worker deploy: manual with Vincent's Cloudflare login,
  `wrangler deploy --config hosting/wrangler.jsonc`. See
  [hosting/README.md](../hosting/README.md).
- CI on pull requests: `nfl-model.yml` and `ios-build.yml`.

## Ratings (Elo)

[ELO_RATINGS.md](ELO_RATINGS.md). Kalman-filter Elo for every team and every
snap-taking player (`model/elo_*.py`): QB vs supporting cast, pass/run offense
and defense, special teams, receiver vs passer vs the defense covering him,
offensive and defensive line play, kickers, punters, and line-vs-line
matchups. A 40-99 "overall" mixes the on-field rating with measured traits.
PR #46 added angles: situations (3rd down, red zone, blitz, play-action),
head-coach scheme, QB-receiver chemistry and O-line continuity, travel and
rest, referees, injuries.

**Result:** the ratings track the books closely but do **not** beat the
closing line on games (2015-2026) or on 1,404 2026 props. They show in answers
as "Coach ratings" only and do not change any chance Coach serves. Current
ratings: `research/elo-ratings/ratings_current.json`.

## What has been measured against the books

Short version: **no edge over the closing line has been shown yet.** Coach is
about as accurate as the closing price, not better.

| Test | Result | Doc |
| --- | --- | --- |
| 2026 season scorecard (922 lines, mostly props, as of Nov 28) | Coach Brier 0.25032 vs books 0.25030, log loss 0.69358 vs 0.69357, a tie | `assets/accuracy-scorecard.json`, [SELF_GRADING.md](SELF_GRADING.md) |
| Game model v2 cover chance | Brier 0.2502 vs flat 0.25, no edge | [MODEL.md](MODEL.md) |
| EndzoneAPI props 2024-26 (1,453) | Books 0.2464, model alone 0.2772, served blend 0.2462 | `research/endzone-eval/` |
| Served prop chance | Held near the no-vig price (`propModelWeight = 0.05`) because the model alone loses | [PROP_SPECIALIST.md](PROP_SPECIALIST.md) |
| Line shopping vs Pinnacle (PropLine sample) | Soft openers flagged +2% lost to the close, -1.6% CLV (n=69) | [LINE_SHOPPING.md](LINE_SHOPPING.md) |
| Coach suggestions, live log (Nov 28) | -3.4% CLV (n=269, 90% range -4.1% to -2.7%), beat the close 20% of the time | [SUGGESTION_CLV.md](SUGGESTION_CLV.md) |
| Opening lines 2008-21 | Model gap 4+ at opener +0.6% CLV (not significant) | [OPENING_LINES.md](OPENING_LINES.md) |
| Non-QB starter outs | Lines barely move (WR 0.5, OL 0.25, CB 0.2 pts); negative CLV | [FREE_SIGNALS.md](FREE_SIGNALS.md) |
| 18 public-bias tests | None passed | `research/endzone-eval/public_bias_results_2026-11-22.txt` |
| Niche angles (9 ideas, PR #48) | Mostly no edge; Denver visitor unders and wind/cold kicker unders are proxy-line leads | [NICHE_EDGES.md](NICHE_EDGES.md) |
| Backup projections (PR #49) | Beat backups' own averages; real-price sample too small (6 props) | [BACKUP_PLAYERS.md](BACKUP_PLAYERS.md) |
| Same-game parlay correlation | QB+WR1 lift 1.29, QB+TE1 1.21; no free SGP prices to test against | [SGP_CORRELATION.md](SGP_CORRELATION.md) |

Watch out for look-ahead: comparing to a Pinnacle open that was posted later
falsely showed +3.4%, and using the actual starter at the opener gave +3.0%.

### Leads worth chasing

1. **QB news.** Knowing the starting QB before the line moves is worth about
   +2.3% to +4.4% CLV (upper bound from the backtest). `tools/qb_news.py`
   logs ESPN injury changes with QB Elo and the price when first seen.
   [QB_NEWS.md](QB_NEWS.md).
2. **Early wind unders.** Forecast wind 15+ mph, under at the opener: +1-2%
   CLV, not yet significant. `tools/weather_watch.py`.
3. **Kalshi as a free sharp reference.** Public API, no key. One hour before
   kickoff its Brier was 0.2069 vs book close 0.2074. Saved in
   `assets/prediction-markets.json`. Polymarket is also reachable.
4. **Visiting players at Denver, unders** (yards and receptions). Under lift
   +6.3% (2007-14) and +2.9% (2015-21) on a proxy line (player's 10-game
   median); the same Denver defense away from altitude shows nothing. Not yet
   tested on real closing lines. [NICHE_EDGES.md](NICHE_EDGES.md).
5. **Kicking-points unders in 15+ mph wind or 32°F or colder.** Under lift
   +4.6% / +4.7% on a proxy line, strongest for strong-legged kickers. No free
   kicker prop prices yet, so live alerts are logged without a price.
6. Smaller leads: milestone overs in the last two weeks (+7.0% / +4.2% lift),
   and betting against a team likely to rest starters in the final week
   (+5.0% / +5.6% CLV, only 40 games).

### Niche edge tests (PR #48, Nov 23)

Nine ideas in [NICHE_EDGES.md](NICHE_EDGES.md) (`model/niche_backtest.py`,
`model/player_angles_backtest.py`). No edge: sticky prop lines (lost badly),
dome/turf/altitude game totals, revenge games, short weeks and Thanksgiving,
first-quarter/first-half scripting, teams out of the race. Slow books
(BetWay, Courtside, Dabble barely follow Pinnacle) still lose after the
margin at every real sportsbook. Leads are listed above. Live logs, hourly in
`niche-watch.yml`: `assets/niche-watch.json`, `assets/public-splits.json`
(signals only, never shown in the app), `assets/book-lag.json`, all scored by
`tools/edge_log.py`.

### Backup players stepping in (PR #49, Nov 23)

[BACKUP_PLAYERS.md](BACKUP_PLAYERS.md). When a starting QB/RB/WR/TE is newly
ruled out, Coach projects his backup (`model/backup_backtest.py`; fitted
share of the missing starter's volume: QB 0.72, RB carries 0.43, WR targets
0.20, TE targets 0.31). On 265 step-ins in 2021-25 the projection beat the
backup's own recent average in every market but one, but ran high for backup
QBs and RBs (207 vs 166 passing yards). Real-price test: only 6 props, says
nothing. `tools/backup_watch.py` runs in the 10-minute news watch, logs the
first price after the news to `assets/backup-watch.json`, and grades it by
CLV. Game answers show a "Next man up" line marked as research.

### Live grading toward ~200 bets

Every flagged bet (line shop, QB news, Coach suggestions) is saved with the
price and time shown, then graded by closing line value. A flag type becomes a
real pick only after **200 scored bets** with the low end of the 90% CLV range
above zero. As of Nov 23: suggestions have 97 graded (-2.8% CLV), line shop
and QB news have 0 live graded. Niche angles and backup step-ins started logging Nov 23.

Live counts on Nov 28 (from the files below):

| Log | Scored | CLV (90% range) | Status |
| --- | --- | --- | --- |
| Suggestions | 269 | -3.4% (-4.1 to -2.7) | fails, below zero |
| Line shop (soft book vs Pinnacle no-vig) | 11 | **+4.0% (+2.3 to +5.8)**, beat close 91% | most promising, needs 200 |
| Niche angles | 253 | -5.6% (-6.1 to -5.2) | fails (mostly Thanksgiving short-week rows) |
| Slow books (book-lag) | 10 | -1.8% (-3.7 to +0.1) | too few |
| QB news | 0 (4 alerts) | none yet | waiting |
| Backup step-ins | 0 (9 current) | none yet | waiting |

Files: `assets/suggestion-log.json`,
`assets/line-shop.json`, `assets/qb-news.json`, `assets/niche-watch.json`,
`assets/book-lag.json`, `assets/backup-watch.json`.

## Pending: desktop DraftKings collector

DraftKings, BetMGM and Caesars block every free server (Actions, Worker, cloud
boxes). Only Vincent's home connection works. `tools/home_collector.py`
([HOME_COLLECTOR.md](HOME_COLLECTOR.md)) runs on his always-on Windows desktop
every 5 minutes and pushes DraftKings props into the Worker's
`/v1/book-prices` store (it merges with the cron's FanDuel/Bovada/BetRivers
rows). A dry run there got 199 prices (DraftKings needs an `Accept-Language`
header). Caesars returns 403 even from home; BetMGM is untested.

**Still not running (checked Nov 28):** the Worker's `/v1/book-prices` has
1,120 rows, all FanDuel (467), Bovada (356) and BetRivers (297), and **no
DraftKings rows**. Vincent still needs to set `BOOK_PROPS_INGEST_SECRET` as
a Windows user variable and run the Coach setup script
(`Documents\Coach\finish_setup.ps1`, which creates the scheduled task, makes a
new secret and walks through pasting it into GitHub and Cloudflare). If the
secret is rotated, the GitHub Actions secret and the Worker secret must both
get the new value. Check: `/v1/book-prices` has no `draftkings` rows until this
is done.

## Open ideas (not started unless noted)

Backup players, prop line anchoring, public-money fade, turf/stadium splits,
revenge spots and slow books were all tested on Nov 23 (sections above).
What is left:

- **Public-money fade, properly:** `tools/public_splits.py` now saves free
  SportsBettingDime signals going forward; a real test needs a season of them.
- **Kicker prop prices:** needed to test the wind/cold kicking under.
- **Book blind spots:** niche props (longest reception, kicking points,
  tackles). `tools/book_props.py` now publishes `unmappedMarketLabels` so the
  labels can be mapped after a game-day run. [NICHE_PROPS.md](NICHE_PROPS.md).
- Show a fair same-game-parlay price in parlay answers.
- Refit `propModelWeight` as more two-sided closes arrive.

## Next steps (in order)

1. Fix the 2 failing tests in `hosting/answer-quality.test.mjs`.
2. Keep the line-shop log growing toward 200 scored bets; it is the only
   live log with CLV above zero so far (n=11). Don't promote it to a pick
   before the 200-bet gate.
3. Help Vincent finish the home DraftKings collector (section above), one
   step at a time, so prop prices include DraftKings.
4. When QB-news and backup step-in alerts get scored, check their CLV.
5. Map `unmappedMarketLabels` from `tools/book_props.py` after a game-day run
   (niche props), and look for free kicker prop prices for the wind/cold
   kicking under.
6. Refit `propModelWeight` as more two-sided closes arrive
   (`assets/self-grade.json` has 861 prop closes; gate is 1,000).

## GitHub state (checked Nov 28, 2026)

- Every branch on GitHub points at a commit that is already in `main`
  (checked each branch tip against merged PR heads). Nothing is waiting to
  be merged. Since PR #49 the only new commits on `main` are the bots' data
  refreshes.
- Old open PRs #7 and #8 were closed on Nov 28: their work went into `main`
  through PR #10.
- Old `claude/*`, `cursor/*` and `codex/*` branches are all merged; ignore
  them. Work on a new branch and open a PR into `main`.

## Other docs

- [HANDOFF_CODEX.md](HANDOFF_CODEX.md): the Nov 23 version of this page.
- [HANDOFF_CLAUDE.md](HANDOFF_CLAUDE.md): Cursor's Nov 22 handoff (book
  layouts, rules, EndzoneAPI and public-bias details).
- [COACH_WORKSPACE.md](COACH_WORKSPACE.md): current product shape.
- [HANDOFF.md](HANDOFF.md): older, long handoff from the first Codex era.
  Historical sections do not override this page.
- [BOOK_PROPS.md](BOOK_PROPS.md), [PROVIDERS.md](PROVIDERS.md),
  [GAME_ANALYSIS.md](GAME_ANALYSIS.md), [PROP_CHANCE.md](PROP_CHANCE.md).
