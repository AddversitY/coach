"""Player ratings: every player who takes a snap gets an Elo-style rating.

Each game, a team's pass EPA per play is modeled as

    league average + sum(offense players' pass ratings x their snap share)
                   - sum(defense players' pass ratings x their snap share)

and the same for runs. After the game, every player on the field moves
toward what happened, by his share of the snaps and by how unsure we were
about him (a weighted Kalman update). So a receiver's rating is earned
against the defenders he faced, and a corner's rating against the
receivers and quarterbacks he faced: the ratings are solved together.

A team's strength for an upcoming game is the sum over the players
expected to play (active players, weighted by their recent snap share).
That is how an injury or a benching changes the team number.

Snap counts come from nflverse (Pro Football Reference), 2013 onward.
"""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass

import numpy as np
import pandas as pd

from elo_ratings import RatingBook, week_index


@dataclass
class PlayerParams:
    prior_sd: float = 0.025
    prior_sd_qb: float = 0.10
    play_sd_pass: float = 1.45
    play_sd_run: float = 1.05
    weekly_drift: float = 0.01
    season_keep: float = 0.8
    recent_games: int = 4


def side_of(game_id: str, team: str) -> str:
    home = game_id.split("_")[-1]
    return "home" if team == home else "away"


def build_lineups(snaps: pd.DataFrame) -> dict:
    """(game_id, side, unit) -> list of (player, share, position)."""
    s = snaps.dropna(subset=["gsis_id"])
    s = s[s["game_type"].isin(["REG", "WC", "DIV", "CON", "SB", "POST"])]
    lineups: dict = defaultdict(list)
    for r in s.itertuples(index=False):
        side = side_of(r.game_id, r.team)
        if r.offense_pct and r.offense_pct > 0:
            lineups[(r.game_id, side, "off")].append((r.gsis_id, float(r.offense_pct), r.position))
        if r.defense_pct and r.defense_pct > 0:
            lineups[(r.game_id, side, "def")].append((r.gsis_id, float(r.defense_pct), r.position))
    return lineups


def unit_epa(plays: pd.DataFrame) -> dict:
    """(game_id, side) -> (pass_epa_mean, pass_n, run_epa_mean, run_n) for that side's offense."""
    p = plays.copy()
    home = p["game_id"].str.split("_").str[-1]
    # nflverse team codes can differ from the game id (e.g. old STL/SD); use home_team column.
    p["side"] = np.where(p["posteam"] == p["home_team"], "home", "away")
    g = p.groupby(["game_id", "side", "is_pass"])["epa"].agg(["mean", "size"])
    out = {}
    for (gid, side, is_pass), row in g.iterrows():
        cur = out.setdefault((gid, side), [0.0, 0, 0.0, 0])
        if is_pass:
            cur[0], cur[1] = row["mean"], int(row["size"])
        else:
            cur[2], cur[3] = row["mean"], int(row["size"])
    return out


class PlayerRatings:
    def __init__(self, params: PlayerParams | None = None):
        self.p = params or PlayerParams()
        p = self.p
        self.books = {
            ("off", "pass"): RatingBook(p.prior_sd**2, p.weekly_drift, p.season_keep),
            ("off", "run"): RatingBook(p.prior_sd**2, p.weekly_drift, p.season_keep),
            ("def", "pass"): RatingBook(p.prior_sd**2, p.weekly_drift, p.season_keep),
            ("def", "run"): RatingBook(p.prior_sd**2, p.weekly_drift, p.season_keep),
        }
        self.qb_book = RatingBook(p.prior_sd_qb**2, p.weekly_drift, p.season_keep)
        self.recent = defaultdict(lambda: deque(maxlen=self.p.recent_games))
        self.mu = {"pass": 0.05, "run": -0.05}
        self.position = {}

    def book(self, unit, kind, pos):
        if unit == "off" and kind == "pass" and pos == "QB":
            return self.qb_book
        return self.books[(unit, kind)]

    def expected_share(self, player, this_game_share):
        hist = self.recent[player]
        return float(np.mean(hist)) if hist else 0.5 * this_game_share

    def strength(self, lineup, unit, kind, season, wi, expected=True):
        total = 0.0
        for player, share, pos in lineup:
            w = self.expected_share(player, share) if expected else share
            total += w * self.book(unit, kind, pos).get(player, season, wi)[0]
        return total

    def update(self, off_lineup, def_lineup, kind, y, n, season, wi):
        if n == 0:
            return
        noise = (self.p.play_sd_pass if kind == "pass" else self.p.play_sd_run) ** 2 / n
        entries = []
        pred = self.mu[kind]
        total = noise
        for lineup, unit, sign in ((off_lineup, "off", 1.0), (def_lineup, "def", -1.0)):
            for player, share, pos in lineup:
                book = self.book(unit, kind, pos)
                m, v = book.get(player, season, wi)
                w = sign * share
                entries.append((book, player, w, m, v))
                pred += w * m
                total += w * w * v
        err = y - pred
        for book, player, w, m, v in entries:
            gain = w * v / total
            book.set(player, season, wi, m + gain * err, v - gain * w * v)
        self.mu[kind] += 0.002 * (y - self.mu[kind])

    def remember(self, lineup):
        for player, share, pos in lineup:
            self.recent[player].append(share)
            self.position[player] = pos


def run_player_ratings(games: pd.DataFrame, lineups: dict, epa: dict, params: PlayerParams | None = None):
    """Pregame lineup strengths per game (home minus away), then update after each week."""
    pr = PlayerRatings(params)
    games = games.sort_values(["season", "week", "gameday", "game_id"])
    rows = []
    for (season, week), block in games.groupby(["season", "week"], sort=True):
        season, week = int(season), int(week)
        wi = week_index(season, week)
        done = []
        for g in block.itertuples(index=False):
            lu = {(side, unit): lineups.get((g.game_id, side, unit), []) for side in ("home", "away") for unit in ("off", "def")}
            if not lu[("home", "off")] or not lu[("away", "off")]:
                continue
            s = {}
            for side, other in (("home", "away"), ("away", "home")):
                for kind in ("pass", "run"):
                    s[(side, kind)] = (pr.strength(lu[(side, "off")], "off", kind, season, wi)
                                       - pr.strength(lu[(other, "def")], "def", kind, season, wi))
            rows.append({
                "game_id": g.game_id,
                "p_pass": s[("home", "pass")] - s[("away", "pass")],
                "p_run": s[("home", "run")] - s[("away", "run")],
                "p_pass_sum": s[("home", "pass")] + s[("away", "pass")],
                "p_run_sum": s[("home", "run")] + s[("away", "run")],
            })
            if pd.notna(g.result):
                done.append((g.game_id, lu))
        for gid, lu in done:
            for side, other in (("home", "away"), ("away", "home")):
                e = epa.get((gid, side))
                if not e:
                    continue
                pr.update(lu[(side, "off")], lu[(other, "def")], "pass", e[0], e[1], season, wi)
                pr.update(lu[(side, "off")], lu[(other, "def")], "run", e[2], e[3], season, wi)
            for key, lineup in lu.items():
                pr.remember(lineup)
    return pd.DataFrame(rows), pr
