# Coach is the app

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

## Real AI connection

`POST /v1/coach` accepts a bounded question, explain/challenge mode and bounded
team/player evidence. Unlike the legacy research endpoint, it requires no
placeholder price, assumptions or baseline probability. The server-only xAI
adapter receives the retrieved evidence, limits citations to provided sources,
disables provider storage and redacts credentials. Model failure returns an
explicit unavailable result; the UI retains its labeled evidence response.
AI text is interpretation, not a verified model forecast. Response numbers still
require user verification; structured evidence cards are computed separately.

The existing development server remains loopback-only. **It has not been exposed
to the internet.** Next, deploy a separate protected hosted service with server
secrets, request rate limits, spending caps and an allowed-origin policy. The
current unrestricted development CORS policy is not production access control.
Do not publish that server unmodified. The model key belongs only on the hosted
server. Set the nonsecret GitHub Actions variable `COACH_API_BASE_URL` to the
resulting HTTPS service URL and rebuild. GitHub Pages cannot run this service.
With the variable unset, no model calls or model charges occur.

The owner requested hosting setup as the next step. A hosting account and model
provider credential still need to be connected; no new account or subscription
was created during the UI release.

## Migration and checks

`lib/main.dart` is the new application entry point. `lib/legacy_workspace.dart`
preserves the previous shell only for internal regression testing of existing
components. It is not linked from the public app. Those regression tests now
import it explicitly; new session/workspace tests exercise the real entry flow.
The underlying data pipeline and credit caps are unchanged.
