# Public betting splits – sample fetches

Fetched: Sunday, Nov 22, 2026, around 12:30 AM America/New_York.
No signups, no payments, repo not changed.

## Best structured samples (start here)
- `sbd-nfl-betting-splits.json` — SportsBettingDime public JSON API (`/wp-json/adpt/v1/nfl-odds`). Bets % and stake/money % for spread, total, moneyline. Best free machine-readable source.
- `sao-nfl-consensus-splits.json` — ScoresAndOdds free HTML consensus page, bets % and money % for spread, total, moneyline.
- `action-nfl-consensus-splits.json` — Action Network page-embedded JSON (Consensus book). Tickets % and money % for all 13 games in the payload, including games the website UI may lock behind PRO. Terms forbid scraping.
- `covers-nfl-consensus.json` — Covers contest pick % and pick counts, plus dated history samples from 2016–2026. Not sportsbook handle.
- `cleatz-nfl-splits.json` — CLEATZ free HTML board, handle % and bets % for spread, total, moneyline.
- `comparison-week11-samples.json` — overlapping numbers from the sources above.
- `dk-props-sample.txt` / `dk-props-sample.body` — DraftKings Network Colts–Texans player-prop handle/bet splits article (Nov 19, 2026).

## Raw fetches
HTML/JSON bodies for the pages and APIs are in this folder (`*.body`). Terms extracts: `sbd-tos.txt`, `action-terms.txt`, `covers-terms.txt`, `sao-tos.txt`.

## In the repo (added Nov 22, 2026)
Only the structured `*.json` samples above and this README were copied into
`research/public-splits/`. The raw page bodies, JS bundles, terms-of-service
copies and the DraftKings Network article were left out of git (size and
copyright). They are not needed to rebuild the samples' meaning.
