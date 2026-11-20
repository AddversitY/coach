# Outlier parity

Checked November 20, 2026. Coach stays a paper-and-graphite chat. It does not copy Outlier's tab bar, branding, logos or colors. "Comparison, not a pick" stays on price answers. A missing number stays unavailable. Prices below are the advertised monthly USD figures already recorded in `docs/PROVIDERS.md` from the vendors' public pages. Nothing here was purchased.

| Outlier surface | Coach now | Status | What it would take |
| --- | --- | --- | --- |
| Prop board with a book filter and an over/under filter | "NFL props at FanDuel" and "best overs" read the saved snapshot. Implied probability is the price as a percentage, fee included. | Partial | A fuller board needs the prop markets in the snapshot. The free Odds API plan is 500 credits/month. Props stay inside the existing daily and monthly caps. |
| Hit-rate sentences against a defense rank | Splits by Elite, Average and Weak, with the game count, from box scores before the week in question. | Partial | The tiers are yards and sacks, not a paid opponent-rank feed. Small samples are shrunk and labeled. |
| One matchup sentence and a tier badge | Every player answer and every game answer leads with one sentence and a tier badge. Elite, average and weak rows are on the card. The longer unit list opens underneath. | Matched for NFL box scores | Other leagues are not loaded. |
| Alternate-line ladder | If the snapshot has more than one spread point, they are listed. Otherwise the answer says the free snapshot is the main line. | Partial | Alternates are a paid or extra-credit market. The Odds API paid plans, as recorded in `docs/PROVIDERS.md`, start at $30/month for 20K credits, then $59/100K, $119/5M and $249/15M. |
| Team and game props | The answer says they are unavailable when the snapshot has no team-total market. | Needs a paid feed | Same Odds API plans, or SportsGameOdds Pro at $299/month, BoltOdds Pro at $349/month, TheRundown Pro at $149/month or Ultra at $399/month. OpticOdds is a custom quote. |
| Stake calculator for a middle or a two-book cross | A dollar amount splits by implied probability. It is not saved. It does not say the profit is guaranteed. | Matched as a calculator | Live middles still need a faster paid feed. |
| Injuries, inactives and snaps on a rematch | Out, Questionable and snap-count club changes are quoted from the nflverse files. | Partial | Week 11, 2026 snaps are not in the snap file. A practice note without a game status is not called an inactive. |
| What changed since the earlier meeting | The Texans–Colts card is computed in `lib/domain/rematch.dart` and described in `docs/MATCHUPS.md`. | Matched for what those files contain | A trade or a general-manager firing is not in the files. Snap share is the detectable evidence. |
| Sportsbook deep link | The existing odds request now asks for `includeLinks` and `includeSids`. A button opens only an https link on that book's own host. | Partial | Saved snapshots do not contain links until the next publication. No extra request is added. The button stays off when the link is missing or the host does not match. |
| Implied-probability explainer | The price card has "What implied probability means." | Matched | The fee-free line is still only shown when both sides were posted. |
| Expected lineup | Not built. | Needs a license | Rotowire-style expected lineups are not in the free files and are not copied. |
| EV, Kelly, boosts, DFS, prediction markets | Not added. The stake box is a calculator only. | Needs a paid feed or a license | Those products are outside the free snapshot. No bankroll, unit, or bet log was added for them. |
| NBA and other leagues | Not added. | Needs a paid feed | The same 500 credits would be spent faster. NBA stays off. |
| Matchup-adjusted prop chance | Priced and unpriced props both use the opponent unit factor and the shrunk sensitivity. The team-total scale and the raw defense-yards scale are not stacked on top. Yards use a lognormal curve before the shrink, which pulls the over rate down and keeps the chance inside the existing gap. See `docs/MATCHUPS.md`. | Partial | The fair line is last season's median, not a historical prop price. Game spreads, totals and moneylines were tested and left on version 2. |

## Blockers

- No front-office or transaction feed. Snap-count team changes are not trades.
- Third-down rate, success rate, pressure and pass rate over expected for a rematch come from `assets/play-units.json`. They are not in the team weekly file. The prop card and the game line do not use them: the walk-forward did not beat the unit-only chance or the closing line in both seasons. The card stays on the lognormal chance. See `docs/MATCHUPS.md`.
- No week 11, 2026 snap counts in `assets/nfl-matchup.json`.
- Deep links appear only after a snapshot is published with the new request flags.
- Alternate lines, team props, live EV, boosts, DFS and prediction markets need one of the paid plans named above.
- The main player bundle still ends on 2026-11-16. Later box scores used for the rematch live in `assets/nfl-recent-evidence.json`.
