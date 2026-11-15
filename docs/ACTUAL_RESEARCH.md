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

The provider key is configured as an encrypted Actions secret. Publication is
bounded to four credits per UTC day and sixty per calendar month, preserving
fifty provider credits. Initialization is a one-time manual workflow input.
Missing state fails closed. Before every charged request the provider's durable
account-usage counter must equal the saved checkpoint: restored older caches,
other account usage, or a billing reset block new requests for reconciliation.
Reservations and the expected counter are saved before a charged call; actual
usage is checked afterward. Cache reuse never changes price timestamps.

The private publisher requires explicit ledger initialization, reserves credits
before a potentially charged request, does not retry failed paid calls, and
keeps raw responses and credentials out of public artifacts. Historical player
metadata must pass date/season/freshness checks before any provider request.

When connected, player research labels observations as Saved prices. Old prices
are identified as outdated and may have changed; they are not current offers.
Observations expire at kickoff or after 18 hours. Core current-price eligibility
and model probability formulas remain unchanged.

## Comparison and coverage

Each exact side/line/market group now leads with its highest saved sportsbook
price and collection age, with a visible older-snapshot warning when needed.
Expand the group for every book's source and collection timestamps. Prices
with different selections or settlement rules are never ranked together.
The Today slate marks games with saved price coverage; other games say
Research only and still open recorded player research.

The publisher checks at 10:20, 16:20, 20:20 and 22:20 UTC. Paid collection is
considered only within six hours of the next kickoff. Existing cached snapshots
are reused without calls, preserving timestamps. The four-credit daily and
sixty-credit monthly caps still apply: four checks do not mean four paid pulls,
and this pilot does not offer continuous or all-game coverage.

## Research polish

Actual Research → Games shares Today's date strip and compact fixture rows,
including saved-price coverage. It opens player research directly; empty game
spread cards and unavailable model comparisons are kept out of this flow.
Player pages lead with the selected stat and saved prices. When multiple lines
exist, a line selector keeps exact over/under comparisons together, with the
highest saved book price and age visible before expanding book timestamps.
Performance charts follow prices; recorded appearances expand on request.
Missing prices explain that recorded performance remains available. Snapshot
expiry, player identity, provenance and settlement safeguards are unchanged.
