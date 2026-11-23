# More free signals: starters, practice reports, Kalshi and wind

Status: **research and live logging. Nothing here is a pick yet.** Every
signal is logged with the price when Coach first saw it and scored against
Pinnacle's close with `tools/line_shop.py`. A signal becomes a pick only after
200 scored alerts with closing line value (CLV) clearly above zero, out of
sample.

All sources are free and need no key: nflverse injury reports and snap
counts, the Sportsbook Reviews opening and closing archive, ESPN's injury
feed, Kalshi's public market data and Open-Meteo forecasts.

## 1. Key starters ruled out (any position)

`model/news_backtest.py` covers 2012–2021. A starter is a player with at
least 70% of snaps over his previous games, listed Out or Doubtful on the
final injury report. Sizes were fit on 2012–2016 and checked on 2017–2021.
Results are in `research/news/backtest.json`.

| Starter out | Games | Spread move against his team, 2017–21 | CLV of betting the other side at the opener, 2017–21 |
| --- | --- | --- | --- |
| QB | 167 | 1.57 pts | +3.9% (+0.3% to +7.4%), but −1.7% in 2012–16 |
| RB | 86 | 1.13 pts | +2.5% (not clear) |
| WR | 307 | 0.49 pts | −1.2% |
| DL | 142 | 0.57 pts | −1.0% |
| OL | 672 | 0.25 pts | −2.9% |
| CB | 395 | 0.23 pts | −2.7% |
| LB | 333 | 0.11 pts | −3.4% |
| TE | 144 | 0.06 pts | −3.5% |
| S | 251 | −0.04 pts | −5.1% |

Outside quarterback (and maybe running back), the market barely moves for a
missing starter, and betting against his team lost to the close even with
perfect timing. So these are shown as **information** in
`assets/qb-news.json → starters`, each with the expected line move. They are
not bets. Quarterback alerts keep the bet and price, as before.

## 2. Practice reports

Questionable starters, 2012–2021, by their last practice status of the week:

| Last practice | Starters | Played (2012–16 / 2017–21) |
| --- | --- | --- |
| Did not practice | 789 | 41% (35% / 46%) |
| Limited | 2,906 | 74% (76% / 73%) |
| Full | 693 | 90% (87% / 92%) |

This held up out of sample and is useful for a player's chance to play.
ESPN's feed has no practice column, so the live watch uses the overall
Questionable rate (73%). The NFL.com report the Worker already reads has the
practice columns, and that's the next place to wire this in.

## 3. Faster news checks

`.github/workflows/news-watch.yml` runs every 10 minutes using free sources
only, with no Odds API credits. It runs the starter watch, Kalshi and the
wind watch, and commits only when an alert or price actually changed. Alerts
carry the bet and the price at first sighting. The Worker's 2-minute cron
already reads injuries and NFL.com inactives in the last 90 minutes before
kickoff. Line prices are the slow part: the free Odds API plan allows about
16 snapshots a month, which is why Kalshi matters (below).

## 4. Kalshi (prediction market)

`tools/prediction_markets.py --backtest` covers every settled 2026 game-winner
market (146 games). It compares Kalshi's mid price from its free hourly
history with the nflverse sportsbook closing moneyline (margin removed):

| | Brier (lower is better) |
| --- | --- |
| Sportsbook close | 0.2074 |
| Kalshi, 1 hour before kickoff | 0.2069 |
| Kalshi, 24 hours before | 0.2086 |

Kalshi one hour out is as accurate as the sportsbook close, and on average
within 0.9 percentage points of it. That makes it a **free sharp reference
we can read as often as we like from the cloud**, unlike Pinnacle through the
Odds API. The live part writes `assets/prediction-markets.json` every 10
minutes. It flags a book moneyline paying 2%+ more than Kalshi's fair chance,
or a Kalshi ask (after its fee) beating the books' fair chance by 2%+. The
first run found no gaps above 0.5%: books and Kalshi agree closely.

## 5. Wind

`model/wind_backtest.py` covers open-air games, 2007–2014 (to find the
threshold) and 2015–2021 (to check it), using game-day wind:

| Wind 15+ mph | Games | Total move, open to close | Under at the opener: CLV | Under at the close: result |
| --- | --- | --- | --- | --- |
| 2007–2014 | 167 | −3.9 pts | +1.0% | +8.8% per bet |
| 2015–2021 | 143 | −1.1 pts | +1.9% | +6.8% per bet |

Both periods point the same way, but the ranges still include zero and the
wind is the game-day reading, not a forecast. This is a lead, not an edge.
`tools/weather_watch.py` reads Open-Meteo's hourly forecast for the three
hours from kickoff at each open-air stadium. When forecast wind is 15+ mph,
it logs the best under price for scoring. The first run flagged KC at BUF
(Nov 26, about 16 mph with gusts to 46, total still 50.5).

## 6. Niche props from the home DraftKings collector

It isn't running yet. The Worker's `/v1/book-prices` holds FanDuel, Bovada
and BetRivers prices only, with none from DraftKings. The collector on
Vincent's desktop still needs the one-time setup (`finish_setup.ps1`). Kalshi
also lists some player markets (longest reception, passing touchdowns), which
are a free niche source to add next.

## 7. Backups stepping in

When a starter is ruled out, Coach projects his backup's props and logs the
first price seen after the news. See [BACKUP_PLAYERS.md](BACKUP_PLAYERS.md).
