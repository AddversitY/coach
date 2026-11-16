# Coach hosting

Cloudflare Worker for the one-page Coach app. It uses a Workers AI binding, a
SQLite Durable Object for atomic pilot quotas/telemetry, and a two-minute cron.
No AI credential is embedded in Flutter or committed to GitHub.

Current deployment: https://coach-research.dds-dge.workers.dev

The public app's hosting URL is configured. OAuth credentials are stored only in
the ignored local CLI directory. Live planner and cited answer checks passed.
Injury listings and attributed reporter headlines are connected, alongside
weather/roof telemetry. No paid plan or new licensed feed was enabled. See
[feed coverage and cadence](../docs/LIVE_FEEDS.md).

## Deployment

Run `npm ci --prefix hosting --ignore-scripts --no-audit --no-fund` first.
Use the official Wrangler CLI, sign in to the owner's Cloudflare account, then
run `wrangler deploy --config hosting/wrangler.jsonc`. Set the account ID through
`CLOUDFLARE_ACCOUNT_ID`. Keep CLI auth in an ignored private directory. The
repository does not provision a paid subscription or custom domain.

Verify `/health` and `/v1/telemetry`, then set the nonsecret GitHub Actions
variable `COACH_API_BASE_URL` to the resulting HTTPS Worker URL and rerun
Publish research preview. The public app's `data/coach-index.json` must exist
before interpretation can succeed. Run `node --test hosting/*.test.mjs`.

## Bounds and evidence

- `/v1/plan` selects allowlisted tools; `/v1/coach` refetches public source data.
  Client statements are not trusted source records. Device simulation output is
  explicitly labeled unverified research; the server does not verify its math.
- Shared persistent quota: 60 AI calls/day and 8 calls/IP/hour. Planning and
  explanation each consume a reservation. Failed requests consume reservations.
  Origin checks are browser restrictions, not authentication. This is a bounded
  public pilot; add user authentication before broader distribution.
- Questions are not persisted. Quota identifiers are daily salted IP hashes.
  Worker observability is disabled; avoid enabling request-body logging.
- Gaussian copula uses 10,000 seeded Monte Carlo draws. Marginals use recorded
  outcomes with a fixed 32-game 50% prior. Sparse pairs fall back to independence.
  Sampling intervals exclude model uncertainty. No validated betting edge.
- Ranking enumerates supplied candidates under nine fixed stress assumptions.
  Workload p10 and variability are descriptive; multipliers are not injury,
  weather, pace, or game-script forecasts. Use `versus` to separate tickets.
- Injury polling uses an unofficial ESPN feed, exact name/team matches, and
  withdraws affected research. A missing report never confirms participation.
- NWS forecasts require exact venue coordinates and are cached 30 minutes;
  roof metadata is not a live roof confirmation. No quantitative weather
  adjustments are inferred.
- Markets read existing published snapshots, retaining original observation
  times and the existing credit limits. This is not real-time market data.
- Reporter headlines use ESPN's published RSS feed, preserving author bylines
  and publication dates, and respecting its 30-minute TTL. No article bodies or
  private social posts are fetched. It is not comprehensive beat-writer coverage.
- Verified sharp-money flow is not connected. Matching saved-price changes are
  tracked as market observations. An authenticated `/v1/ingest` adapter accepts
  provider-reported ticket/handle shares only after `MARKET_INGEST_SECRET` and
  `MARKET_ALLOWED_HOSTS` are configured. Such shares do not identify professional
  bettors. The adapter is disabled by default; no provider subscription is created.
- Optional attributed-news ingestion remains disabled until `INGEST_SECRET` and
  `NEWS_ALLOWED_HOSTS` are configured. Posts never become confirmed scratches.
- Free-plan allowance and provider availability may stop AI responses. Guided
  research remains available. No paid upgrade is performed automatically.

Production readiness still needs calibrated marginal forecasts, independent
server verification of device calculations, licensed low-latency feeds, official
availability coverage, and exact sportsbook settlement/SGP quote validation.
