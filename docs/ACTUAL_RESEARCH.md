# Actual-game research and visual redesign

Actual scheduled games now open recorded player research without requiring a
sportsbook quote. Research → Players offers a game picker, search, team and
position filters. Player pages show recorded production, observed averages,
dated changes and source details. Historical clubs are not confirmed rosters.
Stable player IDs and strictly earlier dates prevent cross-player or future
records from filling the research view.

The visual system now uses bundled Inter 4.1, neutral charcoal, restrained blue
accents, compact unboxed fixtures, underline navigation and quieter typography.
Priced sample cards use borderless tonal surfaces; detail pages are constrained
on desktop. Inter's license and original source are included with the fonts.

## Price pilot status

`tools/publish_quotes.py` and public schema v2 prepare a small exact-identity
snapshot pilot: four prop markets, one scheduled game, protected quota limits,
source/collection timestamps and stable player mappings. Fixture publication is
explicitly rejected by the app. Tests exercise the adapter without paid calls.

Real price publication remains disabled. No provider key is configured. The
Pages workflow explicitly sets ODDS_PUBLISH_ENABLED=0 and makes no provider
request. Activation also requires durable private quota storage: disposable
Actions caches can restore an older ledger and cannot enforce spending limits.
Do not enable automated paid requests using cache-only state.

The private publisher requires explicit ledger initialization, reserves credits
before a potentially charged request, does not retry failed paid calls, and
keeps raw responses and credentials out of public artifacts. Historical player
metadata must pass date/season/freshness checks before any provider request.

When connected, player research labels observations as Saved prices. Old prices
are identified as outdated and may have changed; they are not current offers.
Observations expire at kickoff or after 18 hours. Core current-price eligibility
and model probability formulas remain unchanged.
