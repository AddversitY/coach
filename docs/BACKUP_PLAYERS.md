# Backups stepping in

Status: **projection built, live logging on. Not a pick yet.** The idea: when
a starter is ruled out, his backup's props may open late and soft. Coach
projects the backup, keeps the first price it sees after the news, and grades
it against the close, like the other live edge tests.

All data is free: nflverse weekly stats, snap counts and injury reports (CC BY
4.0), the PropLine graded-props sample (CC BY 4.0), ESPN's injury feed, and the
logged-out FanDuel, Bovada and BetRivers prices the Worker already collects.

## Who counts

- **Starter:** a QB, WR or TE with at least 70% of snaps over his previous
  games (RB: 50%), listed Out or Doubtful (live: also injured reserve or
  suspended). For quarterbacks, the ratings' listed starter always counts.
- **Fresh news only:** he played his team's previous game. After one missed
  game the backup's own numbers, and the books, already include the absence.
- **Backup:** the same-position teammate with the most recent snaps who is not
  a starter and is not ruled out himself.

## The projection

Backup's recent share of team targets (or carries, or pass attempts), plus a
fitted fraction of the missing starter's share, times the team's recent
volume, times the backup's career efficiency shrunk toward the position
average. The shrink sizes (60 targets, 80 carries, 150 attempts) were set
before testing. `model/backup_backtest.py` fits the fraction; the live
constants are in `research/backup/params.json`.

Fraction of the missing starter's share the backup takes (fit on 2016–2025):

| QB attempts | RB carries | RB targets | WR targets | TE targets |
| --- | --- | --- | --- | --- |
| 0.72 | 0.43 | 0.38 | 0.20 | 0.31 |

A WR's targets mostly spread across the other receivers, so the WR2/WR3 who
"steps in" only gains about a fifth of them.

## Test 1: projections, 2016–2020 fit, 2021–2025 check

265 fresh step-ins in the test seasons. "Own recent" is the backup's own
average over his previous games, which is what a lazy line would copy.

| Backup | Market | Actual (avg) | Own recent | Coach projection | Error, own recent | Error, projection | Beat own recent |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| QB (64) | Passing yards | 166 | 49 | 207 | 151 | 99 | 88% |
| RB (64) | Rushing yards | 44 | 21 | 51 | 44 | 38 | 67% |
| RB | Receiving yards | 15 | 9 | 21 | 16.1 | 16.2 | 63% |
| WR (105) | Receiving yards | 34 | 21 | 35 | 36 | 34 | 61% |
| WR | Receptions | 2.8 | 1.8 | 2.8 | 2.5 | 2.3 | 61% |
| TE (32) | Receiving yards | 19 | 8 | 20 | 21 | 19 | 72% |
| TE | Receptions | 2.3 | 0.9 | 1.9 | 2.5 | 2.1 | 75% |

Error is root mean squared error. What this shows:

- Backups beat their own recent averages 61–90% of the time. A book that
  copied a backup's history would be beatable. Books don't do that, so this
  is not an edge by itself.
- The projection is closer than the backup's own history in every market but
  RB receiving yards (a tie).
- It ran **high** for backup QBs and RBs in 2021–2025 (207 vs 166 passing
  yards, 51 vs 44 rushing). The live fit uses all ten seasons, which pulls
  QB and RB shares down, but this is the first thing to watch.

## Test 2: real prices (PropLine, Sep 18–29, 2026)

Only 6 backup props had opening and closing prices from three or more books
(Case Keenum, Marcus Mariota, Chris Bell). Opening overs on them lost 5.2% to
the close, against 0.5% for every other prop's opening over (1,214 props), and
opening unders broke even. With 6 props this says nothing either way. There
is no other free source of opening prop prices, so the live log is the real
test.

## Live

`tools/backup_watch.py` runs in the 10-minute news watch
(`.github/workflows/news-watch.yml`) and writes `assets/backup-watch.json`:

- `current`: each fresh step-in, the backup's Coach rating and projection,
  and every two-sided price on his props with Coach's over chance and the
  edge on each side. The over chance comes from the fitted spread of
  actual / projected, so it reflects how wide backup outcomes really are.
- `bets`: the first price seen per book and market after the news. The Worker
  only collects inside 24 hours of kickoff, so that is usually the first
  price Coach can see.
- `summary`: closing line value against the same book's last price before
  kickoff, for the side Coach's chance favors, and for all overs and unders.
  Profit is added once the box score arrives.

The gate is the same as line shopping: 200 scored bets with the low end of the
90% range of closing line value above zero. Until then, game answers show a
"Next man up" line under Coach ratings, with the projection and price, marked
as research.

Team impact is not re-fit here. `research/news/backtest.json` already showed
that a non-QB starter out moves the spread by 0.5 points or less and betting
against his team at the opener lost to the close. The QB case stays in
`tools/qb_news.py`.

## Rerun

```
python model/backup_backtest.py      # needs model/requirements.txt; downloads nflverse and PropLine
python tools/backup_watch.py         # standard library only
```
