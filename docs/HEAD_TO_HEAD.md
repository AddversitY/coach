# Fair pregame head-to-head protocol

Implemented 2026-11-16. Protocol: `fair-source-context-v3`.

The earlier baseline event object could include a Coach forecast. Earlier baseline scores remain in stored diagnostics but are excluded from the fair three-way comparison. Frozen captures are not rewritten or retroactively qualified.

## Design

- New captures freeze an allowlisted event, dated prior results and box scores, descriptive role context, availability/weather facts and exact observed prices. Coach forecasts, model coefficients, probabilities, rankings and decisions are excluded. The exact baseline input is SHA-256 hashed. This does not give the AI identical training data to Coach's models; the result is a controlled comparison against the configured Workers AI model, not every general AI.
- Snapshot selection order and up to six target identities are deterministic by market, selection and book rather than engine EV order. The quote cap remains 54 per snapshot. The AI sees the stored price context and exact targets. First priced cohort per game/model continues to take precedence over unpriced research.
- AI model, prompt protocol, frozen input hash and start/completion times are stored. The reservation and completion must precede kickoff. Late replies do not qualify. Duplicate completions cannot overwrite a result. A denied global quota reservation may defer until a later request before kickoff; a failed model call is not automatically retried.
- At most TWO automatic primary-model baselines per UTC day are enabled, only for priced v3 captures inside the existing pregame capture window. Games are considered in kickoff/ID order. The durable reservation caps this at two even if configuration requests more. These calls share the unchanged global 60-call/day cap and existing hourly reservation checks. Interactive requests can still trigger a baseline. No sportsbook request is added. The telemetry coordinator no longer has a blanket no-AI rule: this is the explicitly bounded exception.
- The automatic limit is deliberately small and does not cover every game. Coverage shows selected priced-cohort states and separates older protocols. A missing/partial/late/unavailable baseline never counts as a Coach win. Older frozen captures are not regenerated just to obtain a qualifying baseline; current qualified counts can stay zero until future captures.

## Scoring

Coach, AI and market scores use identical priced, non-push selections with all three probabilities available. Brier and log-loss scores are averaged within a game, then across games, separately by market/model cohort. Pushes are excluded from conditional probability scoring; missing player appearances remain unresolved. No verified settlement/profitability claim is made.

Different baseline AI models are identified, and combined scores are withheld if model versions would be mixed. Score corrections undo prior paired contributions before adding replacements. A 1,000-game threshold triggers review, never automatic adoption or a superiority claim. Selection bias, limited source coverage, correlated games and model training differences remain limitations. The independent game challenger and production trial retain separate evaluation cohorts; automatic baselines currently target the primary serving cohort only.

## Official inactive reports

Coach now monitors [NFL.com’s public inactive hub](https://www.nfl.com/inactives/) only when an indexed game starts within three hours. Checks are cached ten minutes; at most two discovered, same-season/week article links are read per refresh. Redirects are rejected, documents bounded, and failures preserve timestamps. This adds free public-page requests, not odds or AI calls.

A report must have dated NewsArticle metadata, matching season/week, exact Eastern game day, both team sections together, an exact known player/team/event identity and an explicit inactive-list entry. Old or future articles, a mismatched game, ambiguity, and emergency third-quarterback annotations cannot become ordinary inactive confirmations. Named confirmed observations expire after twelve minutes or kickoff and withdraw affected analysis through existing injury invalidation. No entire article body or complete raw list is stored or copied to the app.

Only named inactive designations can be confirmed. Missing names do not establish active status, health, projected snaps or a starting role. Official full active lists and confirmed starters are still unavailable. The actual currently published report may be missing; Coach displays waiting/unavailable rather than inventing a confirmation. This collector is deliberately narrow and depends on NFL.com retaining the observed article structure.

## Verification

Tests cover forecast leakage, neutral target ordering, exact three-way scores, legacy/late/unpriced exclusion, correction rollback, mixed AI versions, quota deferral and the hard two-call automatic limit. Official-source tests cover exact identities, game dates and weeks, emergency QB exclusions, caching, outside-window skips and timestamp preservation. Phone UI tests exercise the comparison panel without claiming a winner.
