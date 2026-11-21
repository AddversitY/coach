"""Pure helpers for derived prop shares and closing no-vig prices.

The raw nflverse files and the third-party odds dumps stay off the public
repo. These functions only turn rows the caller already has into shares
and a no-vig prior.
"""

from __future__ import annotations

import math
from datetime import datetime, timezone

NFL_TEAMS = {
    "Arizona Cardinals": "ARI",
    "Atlanta Falcons": "ATL",
    "Baltimore Ravens": "BAL",
    "Buffalo Bills": "BUF",
    "Carolina Panthers": "CAR",
    "Chicago Bears": "CHI",
    "Cincinnati Bengals": "CIN",
    "Cleveland Browns": "CLE",
    "Dallas Cowboys": "DAL",
    "Denver Broncos": "DEN",
    "Detroit Lions": "DET",
    "Green Bay Packers": "GB",
    "Houston Texans": "HOU",
    "Indianapolis Colts": "IND",
    "Jacksonville Jaguars": "JAX",
    "Kansas City Chiefs": "KC",
    "Las Vegas Raiders": "LV",
    "Los Angeles Chargers": "LAC",
    "Los Angeles Rams": "LAR",
    "Miami Dolphins": "MIA",
    "Minnesota Vikings": "MIN",
    "New England Patriots": "NE",
    "New Orleans Saints": "NO",
    "New York Giants": "NYG",
    "New York Jets": "NYJ",
    "Philadelphia Eagles": "PHI",
    "Pittsburgh Steelers": "PIT",
    "San Francisco 49ers": "SF",
    "Seattle Seahawks": "SEA",
    "Tampa Bay Buccaneers": "TB",
    "Tennessee Titans": "TEN",
    "Washington Commanders": "WAS",
}

TEAM_ALIASES = {"JAC": "JAX", "GBP": "GB", "KCC": "KC", "SFO": "SF", "WSH": "WAS"}

MARKET_METRICS = {
    "player_pass_yds": "passing_yards",
    "player_rush_yds": "rushing_yards",
    "player_reception_yds": "receiving_yards",
    "player_receptions": "receptions",
    "player_anytime_td": "anytime_td",
}

# Fantasy apps and one-way products are not two-sided books.
EXCLUDED_BOOKS = {
    "prizepicks",
    "underdog",
    "underdog_fantasy",
    "sleeper",
    "parlayplay",
    "dabble",
    "pick6",
    "betr",
}

SKILL_POSITIONS = {"QB", "RB", "FB", "WR", "TE"}


def norm_name(name: str) -> str:
    text = name.lower().replace(".", "").replace("'", "").replace("-", " ")
    text = "".join(ch if ch.isalnum() or ch == " " else " " for ch in text)
    text = " ".join(text.split())
    for suffix in (" jr", " sr", " iii", " ii", " iv"):
        if text.endswith(suffix):
            text = text[: -len(suffix)].strip()
    return text


def team_code(name: str) -> str | None:
    cleaned = " ".join(name.strip().split())
    if cleaned in NFL_TEAMS:
        return NFL_TEAMS[cleaned]
    upper = cleaned.upper()
    if upper in TEAM_ALIASES:
        return TEAM_ALIASES[upper]
    if upper in NFL_TEAMS.values():
        return upper
    return None


def share(part: float, whole: float) -> float | None:
    if whole <= 0 or part < 0 or not math.isfinite(part) or not math.isfinite(whole):
        return None
    value = part / whole
    if not math.isfinite(value) or value < 0 or value > 1.5:
        return None
    return round(min(value, 1.0), 4)


def american_to_decimal(price: str) -> float | None:
    text = price.strip()
    if not text:
        return None
    try:
        odds = float(text)
    except ValueError:
        return None
    if not math.isfinite(odds) or odds == 0:
        return None
    if odds >= 100:
        decimal = 1 + odds / 100
    elif odds <= -100:
        decimal = 1 + 100 / (-odds)
    else:
        return None
    if not math.isfinite(decimal) or decimal <= 1 or decimal >= 20:
        return None
    return decimal


def no_vig_over(over_decimal: float, under_decimal: float) -> float | None:
    if not (1 < over_decimal < 20 and 1 < under_decimal < 20):
        return None
    over_implied = 1 / over_decimal
    under_implied = 1 / under_decimal
    total = over_implied + under_implied
    if total <= 0 or not math.isfinite(total):
        return None
    chance = over_implied / total
    if not math.isfinite(chance) or chance <= 0 or chance >= 1:
        return None
    return chance


def parse_time(text: str) -> datetime | None:
    cleaned = text.strip()
    if not cleaned:
        return None
    if cleaned.endswith("Z"):
        cleaned = cleaned[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(cleaned)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def consensus_prior(books: list[dict]) -> dict | None:
    """books items: book, novig, at (datetime or None), line.

    A book is stale only when it is at least 8 points from the median of
    the others and at least 3 hours older than the newest timestamp.
    No timestamp is never stale. The prior is half Pinnacle and half the
    mean of the other remaining books.
    """
    if len(books) < 2:
        return None
    newest = None
    for book in books:
        stamp = book.get("at")
        if stamp is not None and (newest is None or stamp > newest):
            newest = stamp
    fresh = []
    stale = []
    for book in books:
        others = [row["novig"] for row in books if row is not book]
        others.sort()
        median = others[len(others) // 2]
        stamp = book.get("at")
        old = (
            newest is not None
            and stamp is not None
            and (newest - stamp).total_seconds() >= 3 * 3600
        )
        off = abs(book["novig"] - median) >= 0.08 - 1e-12
        if old and off:
            stale.append(book["book"])
        else:
            fresh.append(book)
    if len(fresh) < 2 and not any(row["book"] == "pinnacle" for row in fresh):
        return None
    pinnacle = next((row["novig"] for row in fresh if row["book"] == "pinnacle"), None)
    others = [row["novig"] for row in fresh if row["book"] != "pinnacle"]
    others_mean = sum(others) / len(others) if others else None
    if pinnacle is not None and others_mean is not None:
        prior = 0.5 * pinnacle + 0.5 * others_mean
    elif pinnacle is not None:
        prior = pinnacle
    elif others_mean is not None and len(others) >= 2:
        prior = others_mean
    else:
        return None
    return {
        "prior": prior,
        "pinnacle": pinnacle,
        "consensus": others_mean,
        "books": len(fresh),
        "stale": len(stale),
    }
