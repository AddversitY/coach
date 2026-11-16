# Conditional workload forecasts

Coach now has a separate workload trial for QB passing attempts and carries,
RB carries and targets, and WR/TE targets. It does not replace serving prop
estimates, change yardage probabilities, or claim a betting advantage.

Ask **Analyze the Bills**, then open **Workload trial**. For the historical
comparison, ask **Coach performance**, then open **Workload forecast research**.
Upcoming-game results appear in the separate workload trial record.

## What is predicted

Expected opportunities conditional on a recorded player appearance. Six prior
same-team/position records are required, with the latest no more than 35 days
earlier. Inputs include earlier workload, variability, recorded opportunity
share, team and opponent opportunities, home/away, scheduled rest, participation
gaps and changes in the previously observed passing leader. Unconfirmed future
starter names and undated historical injury files are not training features.

A player pool is formed before each whole test week, including players who
subsequently have no recorded appearance. Those absent or mismatched-team rows
remain unresolved; they are not dropped from coverage counts or imputed as zero.
Actual recorded zero workloads are valid outcomes. The live calculation uses
the same feature order and date arithmetic as the Python trainer; fixed QB and
WR fixtures verify parity across runtimes.

The three baselines are last-three and last-six recorded means and the serving
recency-weighting formula applied to workload records. This weighted comparator
is not a claim about live yardage probabilities: yardage-serving record filters
and objectives differ. The challenger fits a ridge residual around this baseline
using earlier labels only, a 730-day window and a 365-day weighting half-life.
Ridge is selected from 1, 10 and 100 using only development seasons before 2025.
Each group's later-season results use whole-week walk-forward fits.

## Initial retrospective results

Evidence cutoff: **2026-11-12**. Mean absolute errors are in the named workload's
units, on matched recorded player appearances from 2025 onward. Lower is better.

| Group | Recorded | Unresolved | Challenger | Weighted | Last 3 | Last 6 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| QB attempts | 625 | 208 | 7.28 | 7.84 | 8.14 | 7.89 |
| QB carries | 625 | 208 | 1.77 | 1.83 | 1.90 | 1.80 |
| RB carries | 1,575 | 351 | 3.44 | 3.50 | 3.60 | 3.58 |
| RB targets | 1,547 | 333 | 1.32 | 1.33 | 1.37 | 1.34 |
| WR targets | 2,398 | 692 | 1.98 | 2.01 | 2.07 | 1.99 |
| TE targets | 1,326 | 433 | 1.57 | 1.62 | 1.69 | 1.59 |

Four groups cleared the exploratory historical point-error criteria: at least
200 recorded outcomes, better MAE than all three baselines, lower RMSE than the
weighted baseline, and a paired week-block bootstrap upper bound below zero
for the MAE difference. RB and WR target gains did not clear that gate. These
are six exploratory groups with no multiple-comparison adjustment, not proof
of a general advantage. All six remain research candidates with `adopted:false`
and `hasEdge:false`; no promotion occurs automatically.

The reported central 80% ranges use only earlier out-of-sample errors, frozen
before a whole evaluation week. Observed coverage is roughly 79–82% across the
groups. It does not include uncertainty about participation, future roles,
injuries, model selection or changed coaching plans. The archive is a current
retrospective data/schedule vintage, not a historical point-in-time feed.

## Automatic prospective trial

The existing coordinator captures the first available conditional forecasts
within 24 hours of kickoff under `workload-ridge-v1`. Candidate means, three
baselines, ranges, source dates, player/team identities and review flags are
frozen. Known role/availability concerns are retained rather than interpreted
as confirmed replacements or zero workloads. No user, question, stake or personal
bet record is captured. The trial makes no odds-provider or extra AI calls.

Published workload outcomes and exact player/team identities grade these rows.
Missing appearance/metric/team information stays unresolved. Corrections replace
prior errors without double counting. Prospective errors are averaged within
each game before averaging games, so many same-game player rows are not treated
as independent evidence. The retrospective table above is per observation;
the forward report explicitly shows both game and observation counts.

The weekly model workflow refreshes `assets/workload-model.json`. Its source
hashes, development scores, season slices, interval coverage, bias, RMSE and
paired uncertainty are retained. `model/workload_forecast.py --schedule <CSV>`
reproduces the report without an odds key. Newer daily evidence can be used as
input to an earlier trained model; both training and input cutoffs are displayed.
