# Coach is the app

## Visual identity

The public Coach theme is paper-white, stone gray and graphite, with bundled
Fraunces for editorial headlines and Inter for reading and tabular figures.
A custom bracketed C mark, fine rules, numbered starting prompts, square
composer and underlined follow-ups replace the previous dark chat styling.
Question notes and research responses have different typographic roles;
charts use graphite and retain labeled warning states. The light theme is
scoped to Coach so the archived shell keeps its existing regression styling.
Phone, desktop and enlarged-text flows are checked before publishing.

The public entry point now opens one conversation. There is no Today, Research
or Tools navigation. A question retrieves matching upcoming NFL games, recorded
players and exact saved prices; results appear as interactive responses.
Game and player choices, charts, book comparisons, dated changes and recorded
games stay in the conversation. Follow-ups retain the selected player/stat/line;
actions on an older response restore that response's subject explicitly.

The initial release is clearly labeled **Guided data mode** when no model service
is configured. It uses supported question patterns and deterministic retrieval,
not an LLM. It does not pretend to answer unrestricted questions. No probabilities,
current rosters, injuries or weather are invented. Player evidence keeps the
existing date, season and identity boundaries. Prices retain source/collection
times and expire at kickoff or 18 hours. Quote cards recheck expiry while open.
Conversation state is held in memory only; no bet tracking was added.

Repository: https://github.com/AddversitY/coach

Public app: https://addversity.github.io/coach/

## Hosted tools and research calculations

The Cloudflare service in `hosting/` adds an allowlisted question planner,
source-grounded explanations, persistent usage caps and telemetry. See
[hosting setup and limitations](../hosting/README.md). The local development
server stays private. GitHub Pages uses the hosted service only when the
nonsecret `COACH_API_BASE_URL` Actions variable is configured and rebuilt.

Explicit selections can run Gaussian-copula joint research with 10,000 seeded
Monte Carlo draws, nine fixed stress scenarios, and bounded candidate ranking.
Separate candidate tickets with `versus`. Every leg needs an exact full player
name, supported stat, over/under and half-line. Whole-number push lines are
unsupported. The model has no validated betting edge. Usage floors and variation
are descriptive inputs, not participation guarantees. Manual `ticket odds`
only enables conditional arithmetic, never a verified offered SGP or value claim.

Analysis is withdrawn at kickoff, on affected reported scratches, stale telemetry,
or changed inputs. Eligible latest analyses recompute when prices/evidence change;
manual ticket quotes are discarded. Hosted interpretation uses server-retrieved
records and explicitly labels device calculation output as unverified research.
No personal bet history is recorded.

## Whole-game analysis

Coach now supports a shared score outlook, spread/total/moneyline pricing,
player workload projections and automatic internal evaluation. See
[game analysis](GAME_ANALYSIS.md) for the failed score-candidate adoption test,
market anchoring, free-budget price coverage and forward benchmark protocol.
No predictive superiority or betting edge is claimed.

## Migration and checks

`lib/main.dart` is the new application entry point. `lib/legacy_workspace.dart`
preserves the previous shell only for internal regression testing of existing
components. It is not linked from the public app. Those regression tests now
import it explicitly; new session/workspace tests exercise the real entry flow.
The underlying data pipeline and credit caps are unchanged.
