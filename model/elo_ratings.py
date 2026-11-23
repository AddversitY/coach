"""Coach ratings: Elo-style strength numbers for every team and player.

Each rating is a mean and a variance (a Kalman filter, which is Elo with an
uncertainty attached). After every game, each rating that took part moves
toward what happened, by an amount set by how unsure we were about it and
how many plays the game gave us. Between weeks every variance grows a
little, and between seasons ratings are pulled part of the way back to
average, so old seasons fade.

Team pieces, all in EPA per play unless stated:
- pass offense "cast" (everything but the quarterback), plus the
  quarterback's own rating, against the opponent's pass defense
- run offense against run defense
- special teams EPA per game
- a points rating (margin Elo, in points)

Ratings interact: a pass play's result updates the passer, the team's cast
and the opposing pass defense together, each by its own share.

Only data from before a game is used to predict that game.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
import pandas as pd


@dataclass
class Params:
    # Tuned on 2009-2014 margin error only (later seasons untouched).
    # Starting (unknown team) spread of each rating.
    prior_sd_pass: float = 0.09
    prior_sd_run: float = 0.12
    prior_sd_qb: float = 0.06
    prior_sd_st: float = 1.0
    prior_sd_pts: float = 5.0
    # Per-play noise (EPA standard deviation of a single play).
    play_sd_pass: float = 1.45
    play_sd_run: float = 1.05
    st_game_sd: float = 4.0
    margin_sd: float = 13.0
    # Variance added per week, as a share of the prior variance.
    weekly_drift: float = 0.0
    # Share of a rating kept from one season to the next.
    season_keep: float = 0.5
    qb_season_keep: float = 0.8


class RatingBook:
    """Ratings keyed by name, each a (mean, variance) with time drift."""

    def __init__(self, prior_var: float, drift: float, keep: float):
        self.prior_var = prior_var
        self.drift = drift * prior_var
        self.keep = keep
        self.mean: dict = {}
        self.var: dict = {}
        self.week: dict = {}
        self.season: dict = {}

    def get(self, key, season: int, week_index: int) -> tuple[float, float]:
        if key not in self.mean:
            return 0.0, self.prior_var
        m, v = self.mean[key], self.var[key]
        gap = self.season.get(key, season)
        if gap < season:
            years = season - gap
            m *= self.keep**years
            # Shrink toward the prior variance as the rating is regressed.
            v = (self.keep ** (2 * years)) * v + (1 - self.keep ** (2 * years)) * self.prior_var
        weeks = max(0, week_index - self.week.get(key, week_index))
        v = min(self.prior_var, v + self.drift * min(weeks, 4))
        return m, v

    def set(self, key, season: int, week_index: int, m: float, v: float) -> None:
        self.mean[key], self.var[key] = m, v
        self.season[key], self.week[key] = season, week_index


def kalman_update(books_keys_signs, y: float, base: float, noise_var: float, season: int, week_index: int):
    """One observation y = base + sum(sign * rating) + noise; update every rating in it."""
    states = []
    pred = base
    total_var = noise_var
    for book, key, sign in books_keys_signs:
        m, v = book.get(key, season, week_index)
        states.append((book, key, sign, m, v))
        pred += sign * m
        total_var += v
    err = y - pred
    for book, key, sign, m, v in states:
        gain = v / total_var
        book.set(key, season, week_index, m + sign * gain * err, v * (1 - gain))
    return pred


def team_game_table(plays: pd.DataFrame, st: pd.DataFrame) -> pd.DataFrame:
    """One row per (game, offense): pass and run EPA sums and counts, passer."""
    p = plays
    pass_ = p[p["is_pass"] == 1]
    run = p[p["is_pass"] == 0]
    g = pd.DataFrame({
        "pass_epa": pass_.groupby(["game_id", "posteam"])["epa"].sum(),
        "pass_n": pass_.groupby(["game_id", "posteam"])["epa"].size(),
        "run_epa": run.groupby(["game_id", "posteam"])["epa"].sum(),
        "run_n": run.groupby(["game_id", "posteam"])["epa"].size(),
    }).fillna(0)
    # Main passer = most dropbacks with a named passer.
    named = pass_.dropna(subset=["passer_player_id"])
    counts = named.groupby(["game_id", "posteam", "passer_player_id"]).size().rename("n").reset_index()
    counts = counts.sort_values("n").drop_duplicates(["game_id", "posteam"], keep="last")
    g = g.reset_index().rename(columns={"posteam": "team"})
    g = g.merge(counts.rename(columns={"posteam": "team", "passer_player_id": "passer"})[["game_id", "team", "passer"]],
                on=["game_id", "team"], how="left")
    g = g.merge(st, on=["game_id", "team"], how="left").fillna({"st_epa": 0.0})
    return g


@dataclass
class TeamRatings:
    params: Params = field(default_factory=Params)

    def __post_init__(self):
        p = self.params
        self.cast = RatingBook(p.prior_sd_pass**2, p.weekly_drift, p.season_keep)
        self.qb = RatingBook(p.prior_sd_qb**2, p.weekly_drift, p.qb_season_keep)
        self.dpass = RatingBook(p.prior_sd_pass**2, p.weekly_drift, p.season_keep)
        self.orun = RatingBook(p.prior_sd_run**2, p.weekly_drift, p.season_keep)
        self.drun = RatingBook(p.prior_sd_run**2, p.weekly_drift, p.season_keep)
        self.st = RatingBook(p.prior_sd_st**2, p.weekly_drift, p.season_keep)
        self.pts = RatingBook(p.prior_sd_pts**2, p.weekly_drift, p.season_keep)
        # League averages, updated slowly.
        self.mu_pass = 0.05
        self.mu_run = -0.05
        self.hfa_pts = 2.0

    def snapshot(self, team: str, qb, season: int, wi: int) -> dict:
        cast, cv = self.cast.get(team, season, wi)
        q, qv = self.qb.get(qb, season, wi) if qb else (0.0, self.params.prior_sd_qb**2)
        return {
            "pass_off": cast + q, "qb": q, "cast": cast,
            "pass_def": self.dpass.get(team, season, wi)[0],
            "run_off": self.orun.get(team, season, wi)[0],
            "run_def": self.drun.get(team, season, wi)[0],
            "st": self.st.get(team, season, wi)[0],
            "pts": self.pts.get(team, season, wi)[0],
            "qb_var": qv,
        }

    def update_game(self, row: dict, home: dict, away: dict, season: int, wi: int, neutral: bool) -> None:
        p = self.params
        for off, de, stats in ((home["team"], away["team"], home), (away["team"], home["team"], away)):
            if stats["pass_n"] > 0:
                y = stats["pass_epa"] / stats["pass_n"]
                keys = [(self.cast, off, 1), (self.dpass, de, 1)]
                if isinstance(stats.get("passer"), str):
                    keys.append((self.qb, stats["passer"], 1))
                kalman_update(keys, y, self.mu_pass, p.play_sd_pass**2 / stats["pass_n"], season, wi)
                self.mu_pass += 0.002 * (y - self.mu_pass)
            if stats["run_n"] > 0:
                y = stats["run_epa"] / stats["run_n"]
                kalman_update([(self.orun, off, 1), (self.drun, de, 1)], y, self.mu_run,
                              p.play_sd_run**2 / stats["run_n"], season, wi)
                self.mu_run += 0.002 * (y - self.mu_run)
        # Special teams: net EPA, home minus away is two-sided; update each side.
        kalman_update([(self.st, home["team"], 1), (self.st, away["team"], -1)],
                      home["st_epa"], 0.0, p.st_game_sd**2, season, wi)
        hfa = 0.0 if neutral else self.hfa_pts
        margin = row["home_score"] - row["away_score"]
        # Cap blowouts the way margin-Elo systems do.
        margin = float(np.clip(margin, -28, 28))
        pred = kalman_update([(self.pts, home["team"], 1), (self.pts, away["team"], -1)],
                             margin, hfa, p.margin_sd**2, season, wi)
        if not neutral:
            self.hfa_pts += 0.003 * (margin - pred)


def week_index(season: int, week: int) -> int:
    return season * 25 + week


def run_team_ratings(games: pd.DataFrame, team_games: pd.DataFrame, params: Params | None = None):
    """Walk the schedule in order. Returns one pregame feature row per game, and the final ratings."""
    tr = TeamRatings(params or Params())
    tg = {(r.game_id, r.team): r._asdict() for r in team_games.itertuples(index=False)}
    games = games.sort_values(["season", "week", "gameday", "game_id"])
    rows = []
    for (season, week), block in games.groupby(["season", "week"], sort=True):
        wi = week_index(int(season), int(week))
        pending = []
        for g in block.itertuples(index=False):
            neutral = str(g.location) == "Neutral"
            h = tr.snapshot(g.home_team, g.home_qb_id if isinstance(g.home_qb_id, str) else None, season, wi)
            a = tr.snapshot(g.away_team, g.away_qb_id if isinstance(g.away_qb_id, str) else None, season, wi)
            feat = {
                "game_id": g.game_id, "season": int(season), "week": int(week),
                "home_team": g.home_team, "away_team": g.away_team,
                "home": 0.0 if neutral else 1.0,
                "f_pass": (h["pass_off"] - a["pass_def"]) - (a["pass_off"] - h["pass_def"]),
                "f_run": (h["run_off"] - a["run_def"]) - (a["run_off"] - h["run_def"]),
                "f_pass_sum": (h["pass_off"] - a["pass_def"]) + (a["pass_off"] - h["pass_def"]),
                "f_run_sum": (h["run_off"] - a["run_def"]) + (a["run_off"] - h["run_def"]),
                "f_qb": h["qb"] - a["qb"],
                "f_st": h["st"] - a["st"],
                "f_pts": h["pts"] - a["pts"] + (0.0 if neutral else tr.hfa_pts),
                "f_rest": float((g.home_rest or 7) - (g.away_rest or 7)) if not pd.isna(g.home_rest) else 0.0,
                "div": float(g.div_game or 0),
                "dome": 1.0 if str(g.roof) in ("dome", "closed") else 0.0,
                "wind": 0.0 if str(g.roof) in ("dome", "closed") or pd.isna(g.wind) else float(g.wind),
                "temp": 60.0 if str(g.roof) in ("dome", "closed") or pd.isna(g.temp) else float(g.temp),
                "spread_line": g.spread_line, "total_line": g.total_line,
                "home_ml": g.home_moneyline, "away_ml": g.away_moneyline,
                "result": g.result, "total": g.total,
                "home_score": g.home_score, "away_score": g.away_score,
            }
            rows.append(feat)
            if pd.notna(g.result):
                hs, as_ = tg.get((g.game_id, g.home_team)), tg.get((g.game_id, g.away_team))
                if hs and as_:
                    pending.append((g._asdict(), hs, as_, neutral))
        # Update only after the whole week is predicted (no same-week leakage).
        for row, hs, as_, neutral in pending:
            tr.update_game(row, hs, as_, int(season), wi, neutral)
    return pd.DataFrame(rows), tr


def no_vig_home(home_ml, away_ml):
    def implied(ml):
        return 100 / (ml + 100) if ml > 0 else -ml / (-ml + 100)
    if pd.isna(home_ml) or pd.isna(away_ml):
        return math.nan
    h, a = implied(home_ml), implied(away_ml)
    return h / (h + a)
