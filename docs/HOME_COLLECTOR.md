# Home collector (DraftKings and BetMGM)

Checked November 28, 2026. DraftKings and BetMGM answer logged-out prop feeds from a Pennsylvania residential connection and block GitHub, Cloudflare and other servers. The script can run on any machine whose traffic comes out of that connection. It now runs from Vincent's assistant's machine, routed through his home. It was first set up on the Bethel Park desktop at `C:\Users\addve\Documents\Coach` (never the Shieldbreak folder).

- Script: [tools/home_collector.py](../tools/home_collector.py). Standard library only. `--books` defaults to `draftkings,betmgm`. DraftKings returns 403 without an `Accept-Language` header, so the script sends one.
- It asks the books while a game is inside one of the Worker's six pre-kickoff windows (24h, 6h, 3h, 90m, 30m, ~10m), and each window once per game. A DraftKings capture is 7 requests, 3 seconds apart, one per prop group. Each returns the whole slate. BetMGM is one fixtures request after its page and access id.
- Markets: passing yards, passing touchdowns, pass attempts, receiving yards, receptions, rushing yards, anytime touchdown. One main line per player (the over closest to even). Alternate lines and combos are left out. BetMGM anytime touchdown is the PlayerTD price at line 0.5 only (1+). A 2+ line is left out.
- Prices go to the Worker's `/v1/book-prices` store in the same `coach-book-prices-v1` rows. The script still reads the store and posts the merged list, because the Worker that is live today replaces the whole store. After that Worker is redeployed, the store merges by book on the server: a cron row newer than this copy is kept, and a kickoff more than 36 hours ago is still dropped. The ingest secret comes from the `BOOK_PROPS_INGEST_SECRET` environment variable. It is never written to a file.
- Log: `collector.log` and `collector-state.json` in the folder. Raw book responses are not kept.

## BetMGM

Logged out. The script loads `https://www.pa.betmgm.com/en/sports/football-11/betting/usa-9/nfl-35` and keeps only the anonymous cookies that page sets. It then reads `/en/api/clientconfig` for the public access id, and asks `/cds-api/bettingoffer/fixtures` with sport 11, region 9, and competition 35. No account and no paid proxy.

## DraftKings feed layout

`https://sportsbook-nash.draftkings.com/api/sportscontent/dkuspa/v1/leagues/88808/categories/{cat}/subcategories/{sub}`. No ids or headers beyond a browser User-Agent and `Accept-Language`. Flat arrays joined by id: `events` (name, `startEventDate`, `status`, participants with `venueRole` and `metadata.shortName`), `markets` (`eventId`, `marketType.name`), `selections` (`marketId`, `outcomeType` Over/Under or "Anytime Scorer", `points` = line, `trueOdds` = decimal, `participants[0].name` = player). American odds use the Unicode minus sign.

## Other books

- **Caesars**, **Fanatics**, and **theScore Bet** (formerly ESPN Bet) return 403 to a plain request. Not collected.
- **Hard Rock** is not offered in Pennsylvania. Not collected.

## Rules

Free, logged out, no account. BetMGM uses only the anonymous cookies its own page sets. No paid proxy. A missing price stays missing. This comparison is not a pick and does not change the served chance.
