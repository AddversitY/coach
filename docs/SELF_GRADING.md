# Self grading

Checked November 20, 2026. Coach saves prices it already pulled and, separately, tries public sportsbook pages while logged out. A missing price stays unavailable. The report is a record of cards. It is not a pick and it does not claim a betting edge.

## What is saved

`assets/price-history.json` stores each price as the book, market, player, line, decimal price and timestamp. Game prices and prop prices use the same file. The file keeps about 90 days of snapshots and at most 25,000 rows. Older rows are dropped after the closing price has been kept.

The closing price of a side is the last saved price whose timestamp is strictly before kickoff. A price taken at or after kickoff is not the close. One snapshot cannot be compared with itself, so closing-line value stays unavailable until a later price is saved.

The Odds API snapshot that GitHub Pages already publishes is copied in. That copy does not spend a credit. The free plan's caps are unchanged.

## The optional public scrape

`tools/price_history.py --scrape` requests DraftKings, FanDuel, BetMGM and Pinnacle the way a logged-out browser would. There is no account, no paid proxy, and no key in the repo. A key that a public page hands to its own browser stays in that request and is not written to the file. Books are requested one at a time, with two seconds between them. A block, a timeout, or a page with no prices is stored as unavailable. The run still keeps every price that did parse.

GitHub Actions runs this on Thursday, Sunday and Monday afternoons and evenings (`.github/workflows/price-history.yml`). It commits only when the file changed.

## Cards and the report

A card is a chance and a side saved before kickoff, next to the price that was on the card. After the game, the grade is the result (hit, miss or push) and the closing-line value: the card's implied probability minus the closing implied probability, for the same book and side. A push is not a hit. A card without a result, or without a later close, is not graded.

`assets/self-grade.json` is the count by market. The chat reads it. "How good is Coach at receiving yards props?" answers from that file. With no graded receiving-yards card, the answer says the report is unavailable.

## Walk-forward hook

The prop test still uses last season's median as the line. `walkForwardTestLine` in `lib/domain/price_history.dart` switches a market to its saved closing line only after that market has 1,000 closing prices. The floor was set before any of those closes existed. It is the same 1,000-game floor used for the other model checks. Below the floor, the median stays, including when the saved close is missing.

The file saved on November 20, 2026 has 888 game prices (moneylines, spreads and totals) from the published Odds API snapshot, across the books in that snapshot. It has no prop prices. DraftKings, FanDuel, BetMGM and Pinnacle were checked logged-out and came back unavailable (HTTP 403, HTTP 400, no logged-out feed, and HTTP 403). No prop market has a closing price, so both seasons still use the median. The numbers in `docs/MATCHUPS.md` are that median test. No card has been graded, so the receiving-yards report says unavailable.

The nflverse schedule used for the closing-line walk-forward has the kickoff spread, total, and the American prices on those numbers. It does not have the opening number, so a move from the open to the close stays unavailable.
