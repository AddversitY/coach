# Closing line value of Coach's suggestions

Status: **tracking. Coach's suggestions do not beat the close yet.**

## What is tracked

Every 30 minutes the Price history workflow:

1. Downloads the published `coach-index.json` (the same model inputs the app
   and Worker use).
2. Runs `hosting/suggestion-log.mjs`, which calls the Worker's own
   `analyzeGame` on the newest saved prices for each upcoming game and keeps
   the top three ranked rows (the rows a game answer leads with). Each row is
   saved with its book, line, price, Coach's chance and the time of the price.
3. Runs `tools/suggestion_grade.py`, which appends new rows to
   `assets/suggestion-log.json` (a row is new when its price, line or book
   changed) and grades every row whose game has kicked off:
   - **CLV vs Pinnacle**: Pinnacle's last no-vig chance before kickoff × the
     suggested price − 1 (Pinnacle is collected from this PR onward, see
     [LINE_SHOPPING.md](LINE_SHOPPING.md)).
   - **CLV vs market**: the same with the median no-vig close of the other
     books, used when Pinnacle is missing.
   - **Result**: win, loss or push from the final score (game markets).
4. Writes a summary per market with the same gate as line shopping: at least
   200 graded suggestions and the low end of the 90% range of CLV above zero.

## First numbers (replay of Nov 19–23 snapshots)

The saved snapshots from November 19 to 23 were replayed as if Coach had
answered one minute after each one (only prices saved up to then were
visible). 97 suggestions on 10 week-11 games are graded against the market
close:

| Market | Suggestions | CLV vs market close (90% range) | Beat the close |
| --- | --- | --- | --- |
| All | 97 | −2.8% (−3.4% to −2.2%) | 13% |
| Moneyline | 32 | −1.6% | 28% |
| Spread | 39 | −3.0% | 8% |
| Total | 23 | −3.8% | 4% |

A bet at a normal −110 price with no information has about −2.4% CLV, so
Coach's current suggestions are about what paying the book's margin costs.
This is expected: Coach's game chances are anchored to the market, so its top
rows are mostly "the best available price", not a view against the market.
Results (win/loss) fill in when the week's scores are refreshed.

## How to read it

`assets/suggestion-log.json` → `summary.all.clv.mean`. Above zero, with
`passes: true`, would mean Coach's suggestions beat the close. Until then they
stay research, not picks.
