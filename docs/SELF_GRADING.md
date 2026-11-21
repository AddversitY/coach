# Self grading

Checked November 21, 2026. Coach saves prices it already pulled and, separately, tries public sportsbook pages while logged out. A missing price stays unavailable. The report is a record of cards. It is not a pick and it does not claim a betting edge.

## What is saved

`assets/price-history.json` stores each price as the book, market, player, line, decimal price and timestamp. Game prices and prop prices use the same file. The file keeps about 90 days of snapshots and at most 25,000 rows. Older rows are dropped after the closing price has been kept.

The closing price of a side is the last saved price whose timestamp is strictly before kickoff. A price taken at or after kickoff is not the close. The opening price is the first saved price before kickoff. One snapshot cannot be compared with itself, so a move stays unavailable until a later price is saved.

The Odds API snapshot that GitHub Pages already publishes is copied in. That copy does not spend a credit.

## The optional public scrape

`tools/price_history.py --scrape` reads logged-out pages for the books that answer, then checks the others once. There is no account, no paid proxy, and no key in the repo. A key that a public page hands to its own browser stays in that request and is not written to the file. Books are requested one at a time, with two seconds between them, and only for games inside the capture window. A block, a timeout, or a page with no prices is stored as unavailable. The prices that do parse go to the private store, not into this public file. Counts are in `assets/book-price-coverage.json`. See [BOOK_PROPS.md](BOOK_PROPS.md).

GitHub Actions runs this every 30 minutes (`.github/workflows/price-history.yml`). The script only requests pages when a game is inside one of these windows before kickoff: 24 hours, 6 hours, 3 hours, 90 minutes, 30 minutes, and about 10 minutes. A missed window is filled once, until the next window opens. It commits only when the file changed.

## Cards and the report

A card is a chance and a side saved before kickoff, next to the price that was on the card. After the game, the grade is the result (hit, miss or push) and the closing-line value: the card's implied probability minus the closing implied probability, for the same book and side. A push is not a hit. A card without a result, or without a later close, is not graded.

`assets/self-grade.json` is the count by market. The chat reads it. "How good is Coach at receiving yards props?" answers from that file. With no graded receiving-yards card, the answer says the report is unavailable.

## Walk-forward hook

The prop test still uses last season's median as the line. `walkForwardTestLine` in `lib/domain/price_history.dart` switches a market to its saved closing line only after that market has 1,000 closing prices. The floor was set before any of those closes existed. It is the same 1,000-game floor used for the other model checks. Below the floor, the median stays, including when the saved close is missing.

The public file saved on November 20, 2026 has 888 game prices (moneylines, spreads and totals) from the published Odds API snapshot. It still has no scraped prop prices. Those prices are in the private store. On November 21, 2026 the logged-out collectors saved 2,513 prop prices for 10 games inside the 26-hour window, and 2,474 of those sides already have a pre-kickoff close. DraftKings, BetMGM, Caesars, ESPN Bet, Fanatics, Hard Rock and Pinnacle came back unavailable. No prop market has 1,000 closes, so both seasons still use the median. The numbers in `docs/MATCHUPS.md` are that median test. A separate PropLine sample from September 18–29, 2026 is scored in `docs/PROP_SPECIALIST.md`. That sample is not part of this saved history, and it has no 2025 closes. No card has been graded, so the receiving-yards report says unavailable. The no-vig consensus is not on the card.

The nflverse schedule used for the closing-line walk-forward has the kickoff spread, total, and the American prices on those numbers. It does not have the opening number.

A live injury check and a kickoff forecast are attached to the game, and to a prop on that game when the question names the game. The answer says "Injury report as of Fri 4:10 PM ET" or "Forecast as of ..." when the check is current. A missing check says unavailable. A check older than 12 minutes for injuries, or 35 minutes for the forecast, says stale. In the last 90 minutes before kickoff the free two-minute cron asks again for the injury list, the NFL.com inactive list, and a forecast older than 10 minutes. The forecast tries the National Weather Service, then Open-Meteo. Neither feed changes the chance.

## Credit budget

The free Odds API plan is 500 credits a month. The app's own schedule already plans about 240 credits for moneylines, spreads and totals, at most 60 for props, and at most 36 for a Pinnacle request, and it holds 50 in reserve. This capture may spend 48 more on game lines (16 calls, 3 credits each, because ten books count as one region and three markets cost 3) and 16 more on props (16 calls, one prop market on the earliest late game, 1 credit each). 240 + 60 + 36 + 48 + 16 = 400. The 50 in reserve is not spent by this job. 400 + 50 = 450, which is under 500.

A call is skipped when the remaining-credit header is missing, when remaining credits are under 50 plus the cost of that call, or when this job's own monthly cap is used up. March through July does not call the odds host. Pinnacle is not requested on this job, because that book is a separate region and would double the cost. The logged-out Pinnacle page was checked and did not return prices, so that book stays unavailable. The key stays in the action's environment. It is not written into the file.

## What the chat says

`assets/line-moves.json` is the movement card: open to close, the last 3 hours, a move through 3 or 7 on a spread, Pinnacle against the other books, and a fast move when three or more books move the same way inside 20 minutes. A public betting percentage is not in any free source this app is allowed to use, so a move against the public stays unavailable. The file saved on November 21, 2026 has one timestamp per price, so no move has been measured yet. Asking how the line moved says that. A game answer stays quiet until two prices exist. The sentence, once a move is measured, is a comparison. An example is "The line moved from -3 to -4.5 in the last 3 hours." It is not a pick. The served chance stays version 2. See `docs/MATCHUPS.md`.
