# Niche props (longest reception, kicking points, tackles)

Status: **blocked on free data. Nothing tested against books yet.**

Books are thought to price small markets loosely, and Coach's position
ratings fit them. But an edge can only be measured against the books' own
lines for those markets, and no free source in reach has them:

- The PropLine free sample has only passing, rushing and receiving yards and
  receptions.
- EndzoneAPI's history is paid.
- The Odds API free plan has these markets, but the 500-credit month leaves
  about 16 prop calls (one market, one game each).
- The free logged-out FanDuel, Bovada and BetRivers feeds that Coach already
  reads probably include them, but the parsers only map the four main
  markets.

## What changed

`tools/book_props.py` now counts every market name the public feeds offer
that Coach does not parse yet (player names removed) and publishes the list
as `unmappedMarketLabels` in `assets/book-price-coverage.json`. After the next
game-day run, those real labels can be mapped to longest reception, kicking
points and tackles, the prices saved, and a model for each market graded
against the close the same way as everything else.
