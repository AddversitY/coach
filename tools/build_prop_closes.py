"""Build assets/prop-closes.json from a local PropLine sample.

The gzip stays in the cache. This file keeps the derived no-vig prior,
the line, the box-score result, and book counts. It does not keep raw
American prices or a book-by-book dump.

The Odds Gap file is one-sided, so vig cannot be removed. Bovada
2021-2022 cannot be scored: the bundled box scores start in 2023.
Those limits are recorded as notes, not as rows.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from prop_shares import (
    EXCLUDED_BOOKS,
    MARKET_METRICS,
    american_to_decimal,
    consensus_prior,
    norm_name,
    parse_time,
    team_code,
)


def load_players(path: Path) -> tuple[dict, dict]:
    payload = json.loads(path.read_text())
    keys = payload["statKeys"]
    index = {name: keys.index(name) for name in keys}
    by_name: dict = defaultdict(list)
    for row in payload["rows"]:
        if row.get("seasonType") != "REG":
            continue
        by_name[norm_name(row["name"])].append(row)
    return by_name, index


def stat_value(row: dict, index: dict, metric: str):
    stats = row["stats"]
    if metric == "anytime_td":
        rush = index.get("rushing_tds")
        receiving = index.get("receiving_tds")
        if rush is None or receiving is None:
            return None
        rush_value = stats[rush] if rush < len(stats) else None
        receiving_value = stats[receiving] if receiving < len(stats) else None
        if rush_value is None and receiving_value is None:
            return None
        return (rush_value or 0) + (receiving_value or 0)
    at = index.get(metric)
    if at is None or at >= len(stats):
        return None
    return stats[at]


def match_player(by_name: dict, name: str, home: str, away: str, commence: datetime):
    home_code = team_code(home)
    away_code = team_code(away)
    if home_code is None or away_code is None:
        return None
    clubs = {home_code, away_code}
    day = commence.astimezone(timezone.utc).date()
    found = []
    for row in by_name.get(norm_name(name), []):
        if row["team"] not in clubs:
            continue
        try:
            played = datetime.fromisoformat(row["date"]).date()
        except ValueError:
            continue
        if abs((played - day).days) > 1:
            continue
        found.append(row)
    ids = {row["playerId"] for row in found}
    if len(ids) != 1:
        return None
    found.sort(key=lambda row: abs((datetime.fromisoformat(row["date"]).date() - day).days))
    if len(found) > 1 and found[0]["date"] != found[1]["date"]:
        # Two different dates equally near the kickoff is ambiguous.
        gap0 = abs((datetime.fromisoformat(found[0]["date"]).date() - day).days)
        gap1 = abs((datetime.fromisoformat(found[1]["date"]).date() - day).days)
        if gap0 == gap1:
            return None
    return found[0]


def read_propline(path: Path) -> dict:
    groups: dict = {}
    with gzip.open(path, "rt", newline="") as handle:
        for row in csv.DictReader(handle):
            market = MARKET_METRICS.get(row.get("market") or "")
            if market is None:
                continue
            book = (row.get("bookmaker") or "").strip().lower()
            if not book or book in EXCLUDED_BOOKS or (row.get("dfs_odds_type") or "").strip():
                continue
            side = (row.get("outcome_name") or "").strip().lower()
            if side not in ("over", "under"):
                continue
            decimal = american_to_decimal(row.get("closing_price") or "")
            if decimal is None:
                continue
            try:
                line = float(row.get("closing_point") or row.get("line") or "")
            except ValueError:
                continue
            key = (row.get("event_id") or "", row.get("player_name") or "", market, book)
            slot = groups.setdefault(
                key,
                {
                    "event": row.get("event_id") or "",
                    "player": row.get("player_name") or "",
                    "home": row.get("home_team") or "",
                    "away": row.get("away_team") or "",
                    "commence": row.get("commence_time") or "",
                    "metric": market,
                    "book": book,
                    "actual_file": row.get("actual_value") or "",
                },
            )
            current = slot.get(side)
            stamp = parse_time(row.get("closing_at") or "")
            if current is None or (stamp is not None and (current["at"] is None or stamp > current["at"])):
                slot[side] = {"decimal": decimal, "line": line, "at": stamp}
    return groups


def derive(groups: dict, by_name: dict, index: dict) -> list[dict]:
    by_prop: dict = defaultdict(list)
    meta: dict = {}
    for slot in groups.values():
        over = slot.get("over")
        under = slot.get("under")
        if over is None or under is None:
            continue
        if abs(over["line"] - under["line"]) > 0.11:
            continue
        chance = no_vig(over["decimal"], under["decimal"])
        if chance is None:
            continue
        key = (slot["event"], slot["player"], slot["metric"])
        meta[key] = slot
        stamps = [stamp for stamp in (over["at"], under["at"]) if stamp is not None]
        by_prop[key].append(
            {
                "book": slot["book"],
                "novig": chance,
                "at": max(stamps) if stamps else None,
                "line": over["line"],
            }
        )
    rows = []
    for key, books in by_prop.items():
        lines: dict = defaultdict(list)
        for book in books:
            lines[round(book["line"], 1)].append(book)
        chosen_line = max(lines, key=lambda line: (len(lines[line]), -abs(line)))
        chosen = lines[chosen_line]
        summary = consensus_prior(chosen)
        if summary is None or summary["prior"] is None or summary["books"] < 2:
            continue
        slot = meta[key]
        commence = parse_time(slot["commence"])
        if commence is None:
            continue
        player = match_player(by_name, slot["player"], slot["home"], slot["away"], commence)
        if player is None:
            continue
        actual = stat_value(player, index, slot["metric"])
        if actual is None:
            continue
        if float(actual) == float(chosen_line):
            continue
        rows.append(
            {
                "season": player["season"],
                "week": player["week"],
                "playerId": player["playerId"],
                "team": player["team"],
                "opponent": player["opponent"],
                "metric": slot["metric"],
                "line": chosen_line,
                "actual": actual,
                "prior": round(summary["prior"], 6),
                "consensus": None if summary["consensus"] is None else round(summary["consensus"], 6),
                "pinnacle": None if summary["pinnacle"] is None else round(summary["pinnacle"], 6),
                "books": summary["books"],
                "stale": summary["stale"],
            }
        )
    rows.sort(key=lambda row: (row["season"], row["week"], row["playerId"], row["metric"], row["line"]))
    return rows


def no_vig(over_decimal: float, under_decimal: float):
    from prop_shares import no_vig_over

    return no_vig_over(over_decimal, under_decimal)


def odds_gap_note(path: Path | None) -> dict:
    if path is None or not path.exists():
        return {"source": "The Odds Gap", "rows": "unavailable", "noVig": "unavailable"}
    priced = 0
    total = 0
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            total += 1
            if (row.get("close_line") or "").strip() and (row.get("close_price") or "").strip():
                priced += 1
    return {
        "source": "The Odds Gap free CSV",
        "url": "https://theoddsgap.com/api/prop-summary.csv?league=nfl",
        "use": "research, with attribution; not a feed",
        "rows": total,
        "pricedRows": priced,
        "noVig": "unavailable",
        "reason": "The file posts one side, so the vig cannot be removed.",
    }


def bovada_note(folder: Path | None) -> dict:
    if folder is None or not folder.exists():
        return {"source": "xsportsbook Bovada", "scored": "unavailable"}
    counts = {}
    for path in sorted(folder.glob("*.csv")):
        with path.open(newline="", errors="replace") as handle:
            counts[path.name] = sum(1 for _ in handle) - 1
    return {
        "source": "xsportsbook Bovada 2021-2022",
        "rights": "all rights reserved; local test only; not committed",
        "rows": counts,
        "scored": "unavailable",
        "reason": "Bundled box scores start in 2023, so 2021 and 2022 cannot be scored.",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--propline", default="/tmp/prop-data/propline.csv.gz")
    parser.add_argument("--players", default="assets/nfl-player-stats.json")
    parser.add_argument("--oddsgap", default="/tmp/prop-data/oddsgap.csv")
    parser.add_argument("--bovada", default="/tmp/prop-data/bovada")
    parser.add_argument("--out", default="assets/prop-closes.json")
    args = parser.parse_args()
    by_name, index = load_players(Path(args.players))
    groups = read_propline(Path(args.propline))
    rows = derive(groups, by_name, index)
    payload = {
        "schema": 1,
        "source": "PropLine graded player props sample",
        "license": "CC BY 4.0",
        "licenseUrl": "https://creativecommons.org/licenses/by/4.0/",
        "sourceUrl": "https://huggingface.co/datasets/propline/graded-player-props-sample",
        "window": "NFL 2026-09-18 through 2026-09-29",
        "note": (
            "Derived no-vig prior, line, and box-score result. "
            "Raw prices are not included. "
            "2025 two-sided closes are unavailable in this sample."
        ),
        "rows": rows,
        "oddsGap": odds_gap_note(Path(args.oddsgap) if args.oddsgap else None),
        "bovada": bovada_note(Path(args.bovada) if args.bovada else None),
    }
    Path(args.out).write_text(json.dumps(payload, separators=(",", ":")))
    print(f"closes {len(rows)} -> {args.out}")


if __name__ == "__main__":
    main()
