# Home collector (DraftKings)

Checked November 22, 2026. DraftKings blocks GitHub, Cloudflare and other server addresses (HTTP 403), but its logged-out prop feed answers from the owner's home connection in Bethel Park, PA. So DraftKings prices are collected on the owner's desktop, which stays on.

- Script: [tools/home_collector.py](../tools/home_collector.py). Standard library only.
- Folder on the desktop: `C:\Users\addve\Documents\Coach` (never the Shieldbreak folder).
- Runs from Windows Task Scheduler every 5 minutes. Most runs only read Coach's public schedule and stop.
- It asks DraftKings only when a game is inside one of the Worker's six pre-kickoff windows (24h, 6h, 3h, 90m, 30m, ~10m), and each window once per game. A capture is 7 requests, 3 seconds apart, one per prop group. Each returns the whole slate.
- Markets: passing yards, passing touchdowns, pass attempts, receiving yards, receptions, rushing yards, anytime touchdown. One main line per player (the over closest to even). Alternate lines and combos are left out.
- Prices go to the Worker's `/v1/book-prices` store in the same `coach-book-prices-v1` rows. The script reads the store first and merges, so FanDuel, Bovada and BetRivers prices from the cron stay. The ingest secret comes from the `BOOK_PROPS_INGEST_SECRET` Windows user variable. It is never written to a file.
- The GitHub Action's push now merges the same way instead of replacing the store.
- Log: `collector.log` and `collector-state.json` in the folder. Raw DraftKings responses are not kept.

## Feed layout

`https://sportsbook-nash.draftkings.com/api/sportscontent/dkuspa/v1/leagues/88808/categories/{cat}/subcategories/{sub}`. No ids or headers beyond a browser User-Agent. Flat arrays joined by id: `events` (name, `startEventDate`, `status`, participants with `venueRole` and `metadata.shortName`), `markets` (`eventId`, `marketType.name`), `selections` (`marketId`, `outcomeType` Over/Under or "Anytime Scorer", `points` = line, `trueOdds` = decimal, `participants[0].name` = player). American odds use the Unicode minus sign.

## Other books

- **BetMGM** answers from home (its `clientconfig` gives a public access id), but the odds request was stopped by Claude Code's permission check and was not run. Not collected.
- **Caesars** returns a CloudFront 403 from home too. Not collected.

## Rules

Free, logged out, no account or cookies, no paid proxy. A missing price stays missing. A multi-book consensus is only adopted if it beats the current chance in 2025 and 2026 walk-forward tests.
