# Logged-out prop prices

Checked November 21, 2026. Coach reads public sportsbook pages while logged out. There is no account, no paid proxy, and no extra Odds API credit. A missing price stays unavailable. This is a comparison, not a pick.

## Books

These three returned NFL player props from a normal request:

| Book | What answered | Prices in this snapshot | Closes | Players matched to a GSIS id |
| --- | --- | ---: | ---: | --- |
| BetRivers | Kambi's public offering file | 678 | 678 | 250 matched, 6 unmatched |
| Bovada | The public NFL coupon | 742 | 742 | 148 matched, 1 unmatched |
| FanDuel | The logged-out New Jersey page | 1,093 | 1,054 | 368 matched, 8 unmatched |

The snapshot is the games inside 26 hours of the check: 10 games. Together that is 2,513 prices and 2,474 closes. A close is the last saved price before kickoff. Thirty-nine prices are an earlier copy of a side that already has a later close.

These did not return a logged-out prop feed: DraftKings (HTTP 403), BetMGM (the page had no prices), Caesars (HTTP 403), ESPN Bet (HTTP 400), Fanatics (HTTP 403), Hard Rock (HTTP 404), Pinnacle (HTTP 403). They are checked again after 20 hours. They are not polled on every run.

Markets saved when the book posts them: passing yards, rushing yards, receiving yards, receptions, pass attempts, pass completions, passing touchdowns, and a single player's anytime touchdown. Combo props ("A or B") and team defenses are left out. Alternate lines are not stored. The line kept for a player is the posted over/under closest to an even price. No line is invented.

Pass attempts and completions came from BetRivers and Bovada. FanDuel's passing page had yards and passing touchdowns, not attempts or completions.

## DraftKings, BetMGM and Caesars (checked November 23, 2026)

A real browser on the owner's home connection shows all three books' props while logged out (see HANDOFF_CLAUDE.md). Servers do not get the same answer:

- GitHub Actions (latest coverage file): DraftKings HTTP 403, Caesars HTTP 403, BetMGM page with no prices.
- A Claude Code cloud machine: DraftKings' current feed (`sportsbook-nash.draftkings.com/.../leagues/88808`) HTTP 403 "Access Denied", Caesars' schedule feed HTTP 403 from CloudFront.
- The Cloudflare Worker (November 21): DraftKings and Caesars HTTP 403, BetMGM empty.

The DraftKings probe now asks for the current feed instead of the retired `api/v5/eventgroups` one, so the daily check tests the right address. No parser is added until a feed answers from a free server, because a parser written without a real response would be a guess. A paid proxy is not used.

The free route that is known to work is a home connection. That would mean a small collector on the owner's computer during the pre-kickoff windows, posting to the existing ingest route. It is not built. It needs the owner's yes.

## How often

The Worker cron is the live collector. It runs every two minutes and only requests books when a game is inside one of the six pre-kickoff windows: 24 hours, 6 hours, 3 hours, 90 minutes, 30 minutes, and about 10 minutes. Each run reads one slice, so the requests stay a few minutes apart. The close moves to the newest pre-kickoff price. It does not add a second close.

The GitHub Action still runs every 30 minutes for the public counts. It does not push prices unless its ingest secret is set.

## Where the prices are

The live numbers are in the Worker durable object and are served by `GET /v1/book-prices`. The app reads that route and, if the read fails, keeps the public counts and says the number is unavailable.

The Worker's existing two-minute cron collects only while a game is inside one of the six pre-kickoff windows. Each run asks for one slice: Bovada's coupon, then a few BetRivers games, then one FanDuel game. That stays inside the free-plan subrequest cap. A short window may refresh Bovada and only part of the other two. The last saved price before kickoff remains the close. Raw book responses are not stored.

`assets/book-price-coverage.json` is the public count from the GitHub Action. It has no prices. The Action still skips its Worker push when `BOOK_PROPS_INGEST_SECRET` is empty. The Odds API path is unchanged and spends no extra credits.

Checked from a Cloudflare Worker on November 21, 2026: BetRivers, Bovada, and FanDuel each returned HTTP 200. Bovada's coupon parsed. The other seven books are still unavailable.

## The consensus

A multi-book no-vig price is not on the card. The rule is the same as the rest of the prop work: it has to beat the current chance on Brier and log loss in both 2025 and 2026. This store has no 2025 closes, so that comparison is unavailable. `consensusAdopted` is false.
