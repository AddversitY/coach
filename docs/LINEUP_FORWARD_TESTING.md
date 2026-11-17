# Lineup reliability and forward testing

Implemented 2026-11-16/17. Existing free-service, AI and odds limits remain unchanged. No personal bet history is collected.

## Official designations

The worker checks the free [NFL injury report](https://www.nfl.com/injuries/) at most once every ten minutes while indexed games are within seven days. Its parser requires the exact season, week, Eastern game day, ordered away/home codes, unique recorded player name/team, and compatible position. It accepts explicit Out, Doubtful and Questionable designations only. Missing/blank rows and practice participation never establish playing or starting status. Schema or identity failures remain unavailable.

The page does not expose individual publication timestamps. Coach records retrieval time separately, leaves publication time unknown, and never dates an injury report using its fetch time. Checks expire after twelve minutes, and downstream game context requires telemetry checked within five minutes. Near-kickoff named inactive checks continue independently.

Under Lineup & workload, official absences include source, checked time and earlier recorded opportunities when available. Prior workload is not a replacement projection, route estimate, expected snaps or proof of participation. Confirmed starters and expected playing time remain unavailable; no synthetic injury point adjustments were added.

## Clear decisions

Game answers now lead with a Pass/Wait headline and a deciding reason. A focused official Out/Inactive designation produces Pass; an official uncertain designation or relevant lineup conflict produces Wait. A missing matching price or an unvalidated model produces Pass. Consider is intentionally not enabled while the system has no demonstrated edge. Exact saved quotes remain separate from experimental break-even prices, with reassessment conditions and the counterargument preserved.

## Faster final-score grading

For captured games started within the preceding 72 hours, the worker checks the free ESPN scoreboard at most once every fifteen minutes. It requests up to three Eastern dates, bounds each response and matches season, exact ordered teams and kickoff within five minutes. Only a unique completed/post game with valid integer scores can grade a forecast. Wrong games, duplicate identities, in-progress games, missing scores and postponed kickoffs do not qualify.

Scoreboard results grade game markets only. Player props and workload outcomes remain unresolved until recorded player box scores arrive. Published nflverse final/box-score records take precedence. Existing correction logic reverses the previous contribution before applying a new result, preserving one graded game per model. Result provenance is retained; a fetch timestamp change alone does not trigger regrading.

Captured event identities are stored in a bounded internal registry; a one-time bounded migration covers existing forecasts. Source failure preserves previously collected finals. No manual invented outcomes or extra AI/odds requests are involved.

## Progress and publication

Coach performance → Forward testing shows captured/graded games, weeks with results, unresolved observations and the latest final-score check. These are coverage descriptions, not statistical sufficiency thresholds. Missing or late AI baselines still never count as wins; only matching pregame comparisons qualify.

Daily evidence refreshes can precede weekly model refits. The publisher now withholds unmatched optional football/regime/audit reports and emits researchAvailability rather than blocking all publication or using an unmatched trial. Strict build-time validation still applies to reports that are included. Existing stored cohorts/results remain intact, and the fixed trial resumes publication after a matching refit.

Tests cover stale/wrong official identities, empty designations, retrieval versus publication time, official Pass/Wait decisions, exact final matching, caching/failure preservation, separate model grading, later box-score resolution without double counting, daily/weekly source mismatch and phone layouts.
