# Daily research evidence

The `Refresh research evidence` GitHub workflow runs daily at 10:00 UTC and
can also be started manually. It uses the existing public nflverse sources,
without sportsbook requests or credentials. A successful run checks the app,
commits four validated assets, then triggers the public preview publication.
The deploy records the checked-out commit and each evidence file's SHA-256.

## What refreshes

- Player box scores: the latest season with a completed game plus three
  earlier seasons. Historical identity, team, season type and missing values
  remain intact.
- Final scores: five seasons of completed regular-season games.
- Snap counts: the selected season, matched to completed schedule records.
- Stored injuries: the selected season's listed records. A successful fetch
  is not a current availability check. The current CSV has no report dates,
  so its calendar coverage remains unknown even when retrieval succeeds.
- The experimental parlay dependence report is regenerated from the exact
  player and score files. Its adoption rules and formulas do not change.

The default cutoff is yesterday in Eastern time. Source coverage is the
latest eligible observation, not the requested cutoff or download time.
During the offseason the importers keep the latest played season instead
of requesting a nonexistent new-season file.

## Failure behavior

`tools/refresh_research.py` works on temporary copies. Importers validate
source schemas, identity joins, finite values, coverage and suspicious row
loss. All source processing, report calculation and consistency checks must
finish before the four files replace the previous batch. Replacement errors
restore the earlier files. A required-source failure produces a failed
workflow without committing or replacing the previous assets.

An optional injury-source failure retains its original records, season,
coverage and retrieval time. Separate metadata records the unsuccessful
attempt; the app labels the refresh incomplete. Explicitly retained records
from another season cannot become current-season injury context.

Hard refresh failures are visible in GitHub Actions. The public app keeps
the last published evidence, shows its actual coverage, and suppresses old
insights. A fresh schedule check never refreshes the evidence dates.

## What changed

Player prop details compare the last three recorded games with the previous
three for workload and the selected production metric. At most two neutral
comparisons appear. Each includes sample counts, the most recent game date,
and an expandable view of both date ranges.

The six games must be a contiguous same-player, same-team, same-season and
same REG/POST segment. Missing observations cannot be replaced by zeros or
older games. Actual time, event date and the data cutoff constrain the
window. Invalid/future provenance, fewer than six observed games, or
coverage/player observations older than 21 days hide the comparisons.
Comparisons recompute from the dataset; no stored editorial statement can
outlive its inputs. They do not change probabilities or claim causation.

## Run and verify

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tools -p 'test_*.py'
.\.venv\Scripts\python.exe tools/refresh_research.py
.\tools\flutter.ps1 analyze --no-pub
.\tools\flutter.ps1 test --no-pub
```

Use `--as-of YYYY-MM-DD` for an explicit completed Eastern date, or
`--asset-dir PATH` for a separate copy of all four existing research assets.
The lower-level `import_evidence.py` also accepts an offline source directory.
The normal workflow validates and builds before committing. Shared data-job
concurrency prevents simultaneous model/evidence pushes; queued non-PR runs
check out current `main`. Workflow completion publication accepts successful
trusted `main` runs only. Scheduled Pages refreshes continue independently.

First successful refresh on 15 November 2026: player, final-score and snap
coverage through **2026-11-12**, snaps through **2026 W10**. Stored injury
coverage is **2026 W10**, with calendar cutoff unknown. These are observed
values, not permanent expectations.

Sources: [nflverse player statistics](https://nflreadr.nflverse.com/articles/dictionary_player_stats.html),
[snap counts](https://nflreadr.nflverse.com/articles/dictionary_snap_counts.html),
[injury data dictionary](https://nflreadr.nflverse.com/articles/dictionary_injuries.html).
The exporter records the exact release URLs and content hashes. Data is
attributed to nflverse under CC BY 4.0.
