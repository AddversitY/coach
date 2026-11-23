# Handoff to Claude Code (November 22, 2026)

Vincent Mamone (GitHub `AddversitY`) is handing Coach to Claude Code for a
while to save usage on his Grok Bot. This note says what Coach is, the rules
Vincent has set, what was tried most recently, and what to do next.

Read this first, then the docs it links. It does not replace them.
Where something could not be verified it says **unknown**.

## Who you are working for

- Vincent is not a programmer. He mostly reads on his phone. Explain things in
  plain words, short sentences, no jargon. Give him one clear question at a
  time, not a list of options.
- He lives in Bethel Park, PA (US Eastern time). Report times in ET.
- He gets frustrated by repeated asks and long forms. Do the work, then report.
- He has said "push and merge on your own" once tests pass. That still holds.

## What Coach is

Coach (formerly "Odds Edge") is an AI sports-betting **research assistant**
for the NFL. You ask about a game, spread, total, moneyline or player prop and
it brings forecasts, evidence and saved book prices into one conversation.

- Public app (Flutter web, GitHub Pages): https://addversity.github.io/coach/
- Repo: https://github.com/AddversitY/coach (default branch `main`)
- Cloudflare Worker: https://coach-research.dds-dge.workers.dev
  (`hosting/worker.mjs`, config `hosting/wrangler.jsonc`, name `coach-research`).
  It has Workers AI, a SQLite Durable Object (`CoachState`) and a cron
  `*/2 * * * *`.
- The cron collects **logged-out** NFL player-prop prices from **FanDuel,
  Bovada and BetRivers**, only inside six pre-kickoff windows (24h, 6h, 3h,
  90m, 30m, ~10m). `GET /v1/book-prices` serves them (schema
  `coach-book-prices-v1`). The app reads that route; if it fails, it says
  "unavailable". Details: [BOOK_PROPS.md](BOOK_PROPS.md).
  Last time Grok Bot checked (Nov 21–22) it held 2,741 prices across 11 games.
- Deploying the Worker: see [hosting/README.md](../hosting/README.md)
  (`wrangler deploy --config hosting/wrangler.jsonc`, owner's Cloudflare
  login). Last deploy was from `main` at `4505342` (PR #35).

### Docs to read (already in the repo)

| Doc | Why |
| --- | --- |
| [COACH_WORKSPACE.md](COACH_WORKSPACE.md) | Current product: one conversation page. Start here. |
| [HANDOFF.md](HANDOFF.md) | Older, long handoff (from the Codex era, PR #19 and later milestones). Architecture, run/test commands, env var **names**, Odds API budget. Historical sections must not override the current direction. |
| [GAME_ANALYSIS.md](GAME_ANALYSIS.md) | Shared spread/total/moneyline/prop analysis and automatic evaluation. |
| [BOOK_PROPS.md](BOOK_PROPS.md) | Logged-out book prices, the Worker cron, `/v1/book-prices`. |
| [PUBLIC_SHARP.md](PUBLIC_SHARP.md) | Public vs sharp screen; why public % shows "not available". |
| [PLAYING_TIME.md](PLAYING_TIME.md) | Snap/route/injury role test (PR #36). Not adopted. |
| [PROP_CHANCE.md](PROP_CHANCE.md), [MODEL.md](MODEL.md) | How the prop chance and Coach's Line work. |
| [PROVIDERS.md](PROVIDERS.md) | Odds API free plan and other providers. |
| [hosting/README.md](../hosting/README.md), [backend/README.md](../backend/README.md), [DEVELOPMENT.md](../DEVELOPMENT.md) | Worker, local backend, setup. |

### Checks

From [HANDOFF.md](HANDOFF.md) and the workflows: `flutter analyze`,
`flutter test`, `python -m unittest discover -s model -t model`,
`node --test hosting/*.test.mjs`, and the Python tests in `tools/test_*.py`.
CI on pull requests: `.github/workflows/nfl-model.yml` and
`.github/workflows/ios-build.yml` (Flutter 3.47.7).

## Standing rules (Vincent's, do not break)

1. **Free only.** At most about $10/month, and only with Vincent's yes first.
   Ask before any paid service, trial or signup.
2. **The Odds API stays on the free 500-credit plan.** Don't add calls that
   spend credits outside the existing caps (`tools/line_timing.py`, backend
   quota).
3. **Never commit keys or passwords**, and never paste them in chat. Vincent
   keeps keys as Windows user environment variables and as Cloudflare Worker
   secrets / GitHub Actions secrets (e.g. `BOOK_PROPS_INGEST_SECRET`). Only
   variable **names** go in the repo.
4. **Value-first framing.** Show our chance vs the book's no-vig chance, as
   "a comparison, not a pick". No bankroll, units, Kelly, bet logging, or
   edge/"beat the book" claims in the product.
5. **Never invent numbers.** Missing data shows as "unavailable".
6. **Model changes:** adopt only if the new version beats the current one in
   **week-based walk-forward** testing on **both the 2025 and 2026 seasons**
   (Brier and log loss). Otherwise write it up and leave it off.
7. Scraping sportsbook and public-betting pages is allowed by Vincent.
8. Don't send emails or messages for Vincent unless he asks.
9. Sportsbook sign-ins (if ever needed again) must come from a Bethel Park,
   PA IP (his home connection). Logged-out collection is the plan, so this
   should not come up.

## Recent results (all November 2026)

### Team and player Elo ratings (Nov 23, Claude)
[ELO_RATINGS.md](ELO_RATINGS.md). Kalman/Elo ratings for every team and
every snap-taking player, with receiver vs passer vs defense ratings tied
together. Walk-forward vs the closing line: no edge on games (2015-2026) or
on 1,404 2026 props. **Not adopted.** Current ratings with a 40-99 overall:
`research/elo-ratings/ratings_current.json`.

### EndzoneAPI prop evaluation (private paid data, summaries only)
Files: [research/endzone-eval/](../research/endzone-eval/).
The raw EndzoneAPI responses are **not** in git (paid data). The key is not
in git. Only 7 credits remain and a call costs 10, so it cannot be rerun
without paying.

- 1,453 graded props (passing/rushing/receiving yards, receptions; 2024–2026).
  Brier: **books no-vig 0.2464**, **model alone 0.2772**, **served chance
  0.2462** (the served chance is held close to the book's no-vig price).
  The books are better than our model alone; the served blend is essentially
  tied with the books. (`results_2026-11-22.txt`)
- Anytime touchdown: the books' no-vig price was best on 278 props, so our
  own TD chance stays hidden. (`anytime_td_results_2026-11-22.txt`)

### Public-bias research
Files: `research/endzone-eval/public_bias_build.py`, `public_bias_test.py`,
`public_bias_results_2026-11-22.txt`.
18 walk-forward tests (overs, star players, popular teams, prime time,
favorites, line moves, soft vs sharp books). **None passed** the both-seasons
rule. To test this properly we need real weekly multi-book prices with open
and close, a sharp book, and real public bet% / money% history.

### Merged PRs
- **#35** Worker cron collector + app reads `/v1/book-prices`. Merged.
- **#36** Playing-time (snaps/routes/injury role) write-up,
  [PLAYING_TIME.md](PLAYING_TIME.md). Merged as a write-up but **not
  adopted**: Brier/log loss improved in both seasons but the 2026 projection
  error got slightly worse.

## New finding, Nov 22: DraftKings, BetMGM and Caesars props without login

Grok Bot signed in to DraftKings, BetMGM and Caesars in a real browser from
Vincent's Bethel Park connection. Two things came out of it:

1. **All three show NFL player props while logged out** in a normal browser.
   (Earlier plain HTTP requests got 403 / empty pages, see BOOK_PROPS.md.
   So a real browser, the right headers, or their JSON feeds are needed.)
2. **Signed-in sessions expired within roughly 15 minutes** (DraftKings and
   BetMGM logged out on their own). So signed-in collection is not the plan.
   Logged-out collection is.

Sample: [research/signedin-props/sample_2026-11-22.csv](../research/signedin-props/sample_2026-11-22.csv)
— Jacksonville Jaguars @ New York Giants (Sun Nov 22, 4:25 PM ET), captured
about 1:18 AM ET. 161 rows in the file (DraftKings 56, BetMGM 49, Caesars 56;
the chat summary said 169, the file has 161). Columns: `book, game, market,
player, line, over_odds, under_odds, captured_at_et, page_url`.
`build_sample.py` is the script that wrote it (numbers were read off the pages
by hand/browser, then typed into the script).

Examples of books disagreeing: Trevor Lawrence passing yards 230.5 DK /
232.5 Caesars / 236.5 BetMGM; Malik Nabers receiving yards 69.5 DK / 66.5
BetMGM.

### How each book lays out props (browser view)

- **DraftKings** — game page like
  `https://sportsbook.draftkings.com/event/jax-jaguars-%40-ny-giants/34118110`.
  Tabs: TD Scorers, Passing, Receiving, Rushing. Each has O/U sub-sections
  selected with `?category=odds&subcategory=pass-yards-o%2Fu`,
  `rush-yards-o%2Fu`, `rec-yards-o%2Fu`, etc.
- **BetMGM** — game page like
  `https://www.pa.betmgm.com/en/sports/events/jacksonville-jaguars-new-york-giants-6:44057`.
  Open the game, then the **Players** sub-tab. O/U groups start collapsed and
  need **Show More**.
- **Caesars** — game page like
  `https://sportsbook.caesars.com/sport/americanfootball/event/c3a79427-2887-e1f2-8c2f-348a4af876a7`.
  Tabs with O/U lists and **Show More**. A "can't verify your location" banner
  shows; it only blocks betting, not reading odds.

**Geofencing:** US sportsbooks restrict by location. Collection may need a
US (ideally PA) IP. Whether the Cloudflare Worker's egress can reach these
books' JSON feeds is **unknown** — test before building. The earlier check
(BOOK_PROPS.md) got HTTP 403 from DraftKings and Caesars and an empty page
from BetMGM.

## Next steps

Approved goal (Vincent: "we should collect this data for free ... on as many
books as we can"). He asked to **pause** on Nov 22, so confirm with him
before turning on new automated collection.

1. Add **DraftKings, BetMGM, Caesars** to the free automated collector, then
   **ESPN Bet, Fanatics, Hard Rock** and any others. Prefer each book's public
   JSON feed (what the page itself loads) over HTML. Feed the results into the
   existing `/v1/book-prices` store with the same schema and the same
   pre-kickoff windows. Stay inside the Workers free-plan subrequest cap. If
   the Worker is blocked (403), report it plainly; don't add a paid proxy.
2. Once 4+ books are collected with open and close, a multi-book no-vig
   consensus can be tested — adopt only under rule 6.
3. **Public betting %** (free): SportsBettingDime JSON,
   `https://www.sportsbettingdime.com/wp-json/adpt/v1/nfl-odds` — bets % and
   money % for spread, total, moneyline. No history, so we have to save our
   own snapshots a few times a week. Their terms forbid automated copying;
   Vincent allows scraping. **Waiting on Vincent's go** before starting.
   Other sources compared: [research/public-splits/README.md](../research/public-splits/README.md).
   Covers has dated contest-pick history back to 2016 (a possible back-fill,
   also waiting on his go).
4. A line-movement retest is scheduled for **Dec 14, 2026** by Vincent's Grok
   Bot routine. Leave room for it (it reads the saved price history).

## Branches and PRs found on Nov 22

- Open PRs **#7** (`cursor/parlay-coach-screens-e22c`) and **#8**
  (`cursor/nfl-coachs-line-6797`) are stacked old PRs whose commits are
  already in `main`. They can be closed; left open for Vincent to decide.
- `claude/project-thread-jlp66s` has **7 commits not in main** (Nov 19:
  same-game parlays with correlation, prop record, best-price/arbitrage/
  middle questions, frozen all-books forecasts, ...). No PR. Probably earlier
  Claude Code work. Review before merging; it may conflict with later work.
- `claude/project-thread-4q36wv`: its one commit is already in main (same
  patch). Safe to delete.
- All other `cursor/*` and `codex/*` branches are fully merged.

## What is deliberately not in git

- Keys and passwords (box secrets, Windows env vars, Worker secrets).
- Raw EndzoneAPI responses (paid data; Grok Bot's private store).
- Raw public-splits page dumps and terms-of-service copies (large, copyrighted).
- Big intermediate files from the public-bias build (`games.csv`,
  `players.csv`, `props.json`), which are rebuilt by `public_bias_build.py`
  from repo data plus the private EndzoneAPI files.
