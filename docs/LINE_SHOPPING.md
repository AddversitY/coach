# Line shopping against a sharp book

Status: **research only, not a pick.** Nothing here has beaten the closing
line yet.

## The idea

Pinnacle takes large bets and moves its prices quickly, so its price with
the margin taken out ("no-vig") is the best free estimate of the real chance.
When a softer book (DraftKings, FanDuel, BetMGM and so on) pays more than that
fair chance, the price is flagged. The only test that counts is closing line
value (CLV): would the flagged price have beaten Pinnacle's last price before
kickoff?

CLV = Pinnacle's closing fair chance × the flagged decimal price − 1.

Positive CLV over many bets is the standard sign of a real edge. It needs far
fewer bets than win/loss records to measure.

## What runs

- `tools/line_timing.py` now asks the Odds API for Pinnacle in place of Fliff.
  A list of ten books costs one region, so this is the same 3 credits per
  game-line snapshot. Every snapshot now has a sharp reference.
- `tools/line_shop.py` (run by the Price history workflow every 30 minutes)
  writes `assets/line-shop.json`:
  - `flags`: soft prices in the newest snapshot of each upcoming game that pay
    at least 2% more than Pinnacle's fair price at the **same line**
    (fair chance 10% to 90%, best book per bet).
  - `live`: every flag from an earlier snapshot, scored against Pinnacle's
    close (moved to the flagged line with a small, capped adjustment when the
    close sits half a point or a point away).
  - `adopted`: true only when live flags beat the close on at least 200 bets
    with the low end of the 90% bootstrap range above zero, and the PropLine
    test below passes too.
- `tools/test_line_shop.py` covers the price math, the no-look-ahead rule and
  the scoring.

## Backtest on real book prices (PropLine sample)

PropLine's free sample (CC BY 4.0) has opening and closing prices from 20+
books, graded against box scores, for 32 NFL games from Sep 18 to Sep 29, 2026
(passing, rushing and receiving yards, receptions). The script downloads it;
the raw file is not committed. Results: `research/line-shop/propline_backtest.json`.

Rule tested without look-ahead: a soft book's **opening** price, compared with
the reference book's opening fair price at the same line, only if the
reference opened first. Edge at least 2%.

| Reference | Flags | Average edge at the time | CLV vs Pinnacle close (90% range) |
| --- | --- | --- | --- |
| Pinnacle | 69 | +5.1% | −1.6% (−3.1% to −0.1%) |
| ProphetX (exchange) | 95 | +6.8% | −2.3% (−4.0% to −0.6%) |
| Novig (exchange) | 30 | +6.2% | −1.5% (−4.3% to +1.5%) |

For comparison, every soft opening price in the sample averaged −6.6% CLV.
Flagged prices were much better than a random soft opener, but still lost to
the close. The reason: opening prop prices sit for days, and Pinnacle's own
opening prop number is soft (low limits). By the close, the market had moved
past the "edge".

Closing prices: 82 soft closing prices beat Pinnacle's closing fair price by
2%+; they returned −1.2% per unit (90% range −19% to +18%), far too few to
tell.

An earlier version of this test that let a soft opener be compared with a
Pinnacle number posted *later* showed +3.4% CLV. That was look-ahead and is
not counted.

## What this means

- Line shopping props at the opening number is **not** an edge in this sample.
- Line shopping still matters for the price you take on any bet you already
  like: never take a worse number than the best available.
- The live test on game lines (spreads, totals, moneylines with Pinnacle in
  the same snapshot, close to kickoff) has just started. The Odds API budget
  allows about 16 game-line snapshots a month, so 200 scored flags will take
  a while. `assets/line-shop.json` shows the running count.

## Limits

- One 12-day prop sample, four markets. No game lines in PropLine.
- Moving a fair chance to a nearby line uses a fitted slope per market
  (`LOGIT_SLOPE`), capped (`MAX_SHIFT`). It is an approximation.
- Odds API Pinnacle prices are whatever the free plan returns. If Pinnacle is
  missing from a snapshot, nothing in that snapshot is flagged.
