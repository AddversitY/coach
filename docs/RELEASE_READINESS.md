# Coach release readiness

Owner: Codex. Updated 2026-11-17. This is the working completion checklist, not a claim of predictive superiority.

## Product contract

One light, editorial Coach workspace. A user asks about a matchup, spread, total, moneyline, player prop or explicit parlay. Coach resolves the exact game and selection, leads with relevant recorded charts, explains source-backed analysis, and asks a focused question when essential inputs are missing. No personal bet logging. Missing data never becomes an invented prediction or quote.

## Release checks

| Area | Current evidence | Remaining acceptance condition |
| --- | --- | --- |
| Core questions | Thirty-seven fixed requests plus shorthand, follow-up, book, line, date, unknown-player and stale-source regression cases | Hosted shorthand spread and passing-yard requests verified; unknown/ambiguous subjects retain clarification |
| Visual research | Team margin/total/scoring charts, player production/workload, exact book comparisons, raw observations and phone tests | Desktop and 390 × 844 phone review passed for margin and player charts |
| Price reliability | Free pilot uses saved snapshots, an 18-hour lifetime, six-hour pregame acquisition window and persistent quota reservations | Confirmed on hosted release 9a1e1b5; price acquisition remains intentionally limited |
| Source context | Dated historical records, weather, unofficial injuries, named official injury/inactive checks and invalidation | Confirm failure states; full active lists and confirmed starters remain unavailable |
| Automatic operation | Live scheduled job completes; first captured game graded automatically | Serving player outcomes resolved after free-source refresh; preserve missing trial appearances and failed AI baselines |
| Hosting | Public Pages app and private-key Worker; automatic build/deploy checks | Release f36a923 deployed and inspected; automatic post-publication verification added |
| Costs | Existing free caps and reserve are unchanged | No paid service without explicit approval; do not erase or reinitialize private usage records |

## Research completion is separate

Live audit on 2026-11-17: one game captured and graded in the serving cohort, initially fifteen player observations unresolved, zero qualified fair AI comparisons. The frozen AI baseline for that game failed; it cannot be regenerated after kickoff. Published free-source records through November 16 resolved all fifteen serving observations. Some separate workload/production observations remain absent or mismatched and correctly unresolved. The first game's outcome is not evidence of general skill.

Future pregame captures must retain exact selection/line, source age, frozen facts, model/protocol and completion deadlines. Market and configured-AI comparisons must use the same settled observations, average within games and report missing coverage. Historical challengers remain unadopted. No model currently has a demonstrated betting edge. A future result that fails to beat the reference must remain visible.

The release can be made dependable through engineering. Predictive superiority requires future evidence and may never be achieved. It cannot be checked off by adding features, replaying already-seen outcomes or spending more API quota.


## Current report refit

The November 16 evidence batch now has matching fixed score, shadow, error/regime, football, workload and production reports. Football inputs include 2,474 sourced team-games and all 29 currently scheduled events. The historical challengers still trail market baselines; no adoption or predictive-superiority claim follows from the refresh. Future frozen captures remain untouched. Automatic outputs are preserved as bounded public artifacts before publication; changed input evidence blocks publishing an old fit.


## Verified release baseline

Release f36a923 passed hosted build/deployment, local app analysis and 393 app tests, 67 model tests and 85 tool tests at publication. The source-budget regression passed subsequently. The new release verifier and its failure-case tests bring the tool suite to 88 tests. A real read-back verified all four deployed evidence hashes, 29 matching schedule/index identities, November 16 player coverage and a recent completed scheduled service refresh. Phone review confirmed signed-spread margin thresholds and passing-yard shorthand with the requested line, readable controls and separate workload context. Screenshots are retained locally as release evidence.

The release verifier makes only bounded public file and health requests. It never invokes AI, pricing or forecast capture. It fails on mixed releases, changed evidence bytes, mismatched kickoff times, stale/future schedule or player research and failed/stalled scheduled collection. CDN propagation gets three bounded read-only attempts.


## Free interpretation budget

Standard structured game research no longer makes a second AI request merely to restate the charts and decision. Users can ask why or use Explain this research for an evidence-grounded interpretation. Existing global/per-IP caps, two-baseline automatic daily ceiling and provider cooldown remain unchanged. No inference model was switched. Cloudflare documents the shared [10,000-neuron daily allocation and UTC reset](https://developers.cloudflare.com/workers-ai/platform/pricing/); this is still a limited free prototype allowance, not unlimited public-user capacity. The app keeps its calculated research available when interpretation is unavailable.


## Selection-boundary audit

An additional pass reproduces and fixes incomplete side/line selection, unsupported-scope substitution, unknown-subject context reuse, surname identity guesses and date/odds fragments in spread memory. Short clarification replies complete only the missing detail and preserve event dates. The current checks pass 401 app and 138 hosted tests, with clean analysis. Book-preference transitions and follow-ups after joint/global-live research remain targeted conversational audits; they must be checked before claiming the broader conversation experience is complete.


## Sportsbook transition audit

Specific-to-multiple-to-all-book transitions are now implemented and covered end to end. The visible all-books action replaces the original query’s operator instead of reapplying it. Price tables and interpretation receive only the requested book set; reports reject out-of-scope rows. The current checks pass 406 app and 142 hosted tests with clean app analysis. Remaining audits include joint/global-live conversational follow-ups and additional sportsbook language qualifiers. Future predictive comparisons remain incomplete.
