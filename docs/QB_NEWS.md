# Quarterback news watch

Status: **watching and logging. Not a pick yet.**

## Why

The opening-line test ([OPENING_LINES.md](OPENING_LINES.md)) found that
quarterback changes are where NFL lines move most, and that betting the side a
change favors before the line moves had +2.3% to +4.4% closing line value in
2008–2021. Books react fast, so the only question that matters is whether a
free feed sees the news before the saved line moves.

## What runs

`tools/qb_news.py` runs with the price capture every 30 minutes:

1. Reads the free ESPN injury feed (no key).
2. Takes each team's current starter from `assets/elo-ratings.json`.
3. If the starter is Out, Doubtful, on injured reserve or suspended, writes an
   alert to `assets/qb-news.json` with the backup and both Coach skill
   ratings, the median spread saved before the report, the newest median
   spread, and the best spread price on the other team at the newest snapshot.
4. Keeps the first sighting of each alert (the price that could have been
   taken) and, after kickoff, scores it against Pinnacle's close with
   `tools/line_shop.py`.

The summary uses the same gate as line shopping: 200 scored alerts with the
low end of the 90% range of closing line value above zero.

## Limits

- Snapshots are sparse (the free Odds API budget allows about 16 game-line
  snapshots a month), so "before the report" is often missing or old.
- The ESPN feed lists many backups as Out every week. Only the team's current
  starter triggers an alert.
- A starter ruled out on Monday is usually priced in by Wednesday. Real value
  is likely late in the week and on game day, which needs the Worker's
  2-minute cron, not this 30-minute job.
