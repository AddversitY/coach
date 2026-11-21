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

## How often

The GitHub Action still runs every 30 minutes and only requests books when a game is at one of the six pre-kickoff windows: 24 hours, 6 hours, 3 hours, 90 minutes, 30 minutes, and about 10 minutes. This check was one of those windows. A later window saves another snapshot of about this size for the games in that window. The close moves to the newest pre-kickoff price. It does not add a second close.

Requests go one book at a time, with two seconds between books and about a second between games. At most 16 games are read in one run.

## Where the prices are

Normalized prices are in `backend/data/book-props.json`. That directory is gitignored. GitHub Actions keeps the file in its cache between runs, so the history survives the next cron. Raw book responses are not stored.

`assets/book-price-coverage.json` is the public count. It has no prices. The app says a number is unavailable until a saved price is actually loaded. Asking for a FanDuel or BetRivers prop price uses that file.

The Worker can hold the latest snapshot in its existing durable object and serve `GET /v1/book-prices`. A post to that path requires `BOOK_PROPS_INGEST_SECRET`, which is not in the repo. Until that secret is set and the Worker is deployed, the public app has the counts and not the numbers. The Odds API path is unchanged and spends no extra credits.

## The consensus

A multi-book no-vig price is not on the card. The rule is the same as the rest of the prop work: it has to beat the current chance on Brier and log loss in both 2025 and 2026. This store has no 2025 closes, so that comparison is unavailable. `consensusAdopted` is false.
