"""Player-prop projections from intertwined player ratings.

Every pass target is one observation of

    yards = average for the position + receiver rating + passer rating
            + the defense's rating against that position (WR, TE or RB)

so a receiver's rating is earned against the passers who threw to him and
the defenses that covered him, and a defense's rating is earned against the
receivers and passers it faced. Catches, passer yards per attempt and
rusher yards per carry work the same way. Opportunity is rated too: each
player's share of his team's targets, carries or attempts, and each team's
attempts and carries per game against each opponent.

Projection = share x team volume x efficiency, then a final scale for game
script (spread and total), fit on earlier seasons only. The chance of the
over comes from how actual results spread around projections of the same
size in earlier seasons.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

import numpy as np
import pandas as pd

from elo_ratings import RatingBook, kalman_update, week_index

POS_GROUP = {"WR": "WR", "TE": "TE", "RB": "RB", "FB": "RB", "QB": "QB"}
METRICS = ("receiving_yards", "receptions", "rushing_yards", "passing_yards")


@dataclass
class PropParams:
    keep: float = 0.7
    drift: float = 0.0
    sd_rec_ypt: float = 2.0       # receiver skill spread, yards per target
    sd_qb_ypt: float = 1.0
    sd_def_ypt: float = 0.8
    sd_catch: float = 0.08
    sd_def_catch: float = 0.03
    sd_ypc: float = 0.8
    sd_def_ypc: float = 0.4
    sd_share: float = 0.08
    sd_vol: float = 4.0
    target_sd: float = 10.5       # yards on a single target
    carry_sd: float = 6.0
    attempt_sd: float = 10.0


def player_positions(players_parquet) -> dict:
    p = pd.read_parquet(players_parquet, columns=["gsis_id", "position"]).dropna()
    return {r.gsis_id: POS_GROUP.get(r.position, "WR") for r in p.itertuples(index=False)}


def box_scores(plays: pd.DataFrame) -> pd.DataFrame:
    """Per (game, team, player): targets, receptions, receiving/rushing/passing yards, carries, attempts."""
    p = plays
    tgt = p[(p.is_pass == 1) & (p.sack != 1) & p.receiver_player_id.notna()]
    rec = tgt.assign(ry=tgt.yards_gained * tgt.complete_pass).groupby(
        ["game_id", "posteam", "receiver_player_id"]).agg(
        targets=("epa", "size"), receptions=("complete_pass", "sum"), receiving_yards=("ry", "sum"))
    rec.index.names = ["game_id", "team", "player"]
    rush = p[p.rusher_player_id.notna()].groupby(["game_id", "posteam", "rusher_player_id"]).agg(
        carries=("epa", "size"), rushing_yards=("yards_gained", "sum"))
    rush.index.names = ["game_id", "team", "player"]
    att = p[(p.is_pass == 1) & (p.sack != 1) & p.passer_player_id.notna() & p.rusher_player_id.isna()]
    pas = att.assign(py=att.yards_gained * att.complete_pass).groupby(
        ["game_id", "posteam", "passer_player_id"]).agg(attempts=("epa", "size"), passing_yards=("py", "sum"))
    pas.index.names = ["game_id", "team", "player"]
    box = rec.join(rush, how="outer").join(pas, how="outer").fillna(0).reset_index()
    return box


class PropRatings:
    def __init__(self, params: PropParams | None = None):
        p = self.p = params or PropParams()
        mk = lambda sd: RatingBook(sd**2, p.drift, p.keep)
        self.rec_ypt, self.qb_ypt, self.def_ypt = mk(p.sd_rec_ypt), mk(p.sd_qb_ypt), mk(p.sd_def_ypt)
        self.rec_catch, self.qb_catch, self.def_catch = mk(p.sd_catch), mk(p.sd_catch / 2), mk(p.sd_def_catch)
        self.qb_ypa, self.def_ypa = mk(p.sd_qb_ypt), mk(p.sd_def_ypt)
        self.ypc, self.def_ypc = mk(p.sd_ypc), mk(p.sd_def_ypc)
        self.tshare, self.cshare, self.ashare = mk(p.sd_share), mk(p.sd_share * 2), mk(0.3)
        self.vol_att_off, self.vol_att_def = mk(p.sd_vol), mk(p.sd_vol / 2)
        self.vol_car_off, self.vol_car_def = mk(p.sd_vol), mk(p.sd_vol / 2)
        self.mu = defaultdict(float)
        self.mu.update({"ypt_WR": 8.5, "ypt_TE": 7.5, "ypt_RB": 6.0, "catch_WR": 0.63, "catch_TE": 0.70,
                        "catch_RB": 0.77, "ypa": 6.9, "ypc": 4.3, "att": 34.0, "car": 26.0,
                        "tshare_WR": 0.14, "tshare_TE": 0.10, "tshare_RB": 0.07, "tshare_QB": 0.0,
                        "cshare_RB": 0.35, "cshare_QB": 0.08, "cshare_WR": 0.01, "cshare_TE": 0.0, "ashare": 0.6})

    def _drift_mu(self, key, y, rate=0.001):
        self.mu[key] += rate * (y - self.mu[key])

    # ---- projections -------------------------------------------------
    def project(self, player, pos, team, opp, qb, season, wi):
        g = lambda book, key: book.get(key, season, wi)[0]
        att = self.mu["att"] + g(self.vol_att_off, team) + g(self.vol_att_def, opp)
        car = self.mu["car"] + g(self.vol_car_off, team) + g(self.vol_car_def, opp)
        ts = max(0.0, self.mu[f"tshare_{pos}"] + g(self.tshare, player))
        cs = max(0.0, self.mu[f"cshare_{pos}"] + g(self.cshare, player))
        ypt = self.mu[f"ypt_{pos}"] + g(self.rec_ypt, player) + (g(self.qb_ypt, qb) if qb else 0) + g(self.def_ypt, (opp, pos))
        catch = self.mu[f"catch_{pos}"] + g(self.rec_catch, player) + (g(self.qb_catch, qb) if qb else 0) + g(self.def_catch, (opp, pos))
        ypc = self.mu["ypc"] + g(self.ypc, player) + g(self.def_ypc, opp)
        out = {
            "team_att": att, "team_car": car,
            "receiving_yards": ts * att * ypt,
            "receptions": ts * att * float(np.clip(catch, 0.2, 0.95)),
            "rushing_yards": cs * car * ypc,
        }
        if pos == "QB":
            share = float(np.clip(self.mu["ashare"] + g(self.ashare, player), 0, 1))
            ypa = self.mu["ypa"] + g(self.qb_ypa, player) + g(self.def_ypa, opp)
            out["passing_yards"] = share * att * ypa
        else:
            out["passing_yards"] = 0.0
        return out

    # ---- updates after a game ----------------------------------------
    def update_plays(self, plays: pd.DataFrame, pos: dict, season: int, wi: int):
        p = self.p
        tg = plays[(plays.is_pass == 1) & (plays.sack != 1) & plays.receiver_player_id.notna()]
        for r in tg.itertuples(index=False):
            ps = pos.get(r.receiver_player_id, "WR")
            if ps == "QB":
                continue
            yards = r.yards_gained * r.complete_pass
            keys = [(self.rec_ypt, r.receiver_player_id, 1), (self.def_ypt, (r.defteam, ps), 1)]
            ckeys = [(self.rec_catch, r.receiver_player_id, 1), (self.def_catch, (r.defteam, ps), 1)]
            if isinstance(r.passer_player_id, str):
                keys.append((self.qb_ypt, r.passer_player_id, 1))
                ckeys.append((self.qb_catch, r.passer_player_id, 1))
            kalman_update(keys, yards, self.mu[f"ypt_{ps}"], p.target_sd**2, season, wi)
            kalman_update(ckeys, r.complete_pass, self.mu[f"catch_{ps}"], 0.22, season, wi)
            self._drift_mu(f"ypt_{ps}", yards)
            self._drift_mu(f"catch_{ps}", r.complete_pass)
        at = plays[(plays.is_pass == 1) & (plays.sack != 1) & plays.passer_player_id.notna() & plays.rusher_player_id.isna()]
        for r in at.itertuples(index=False):
            y = r.yards_gained * r.complete_pass
            kalman_update([(self.qb_ypa, r.passer_player_id, 1), (self.def_ypa, r.defteam, 1)], y,
                          self.mu["ypa"], p.attempt_sd**2, season, wi)
            self._drift_mu("ypa", y)
        ru = plays[plays.rusher_player_id.notna()]
        for r in ru.itertuples(index=False):
            kalman_update([(self.ypc, r.rusher_player_id, 1), (self.def_ypc, r.defteam, 1)], r.yards_gained,
                          self.mu["ypc"], p.carry_sd**2, season, wi)
            self._drift_mu("ypc", r.yards_gained)

    def update_shares(self, box: pd.DataFrame, candidates: dict, pos: dict, opp_of: dict, season: int, wi: int):
        """box: this week's player rows; candidates: (game, team) -> players who took offensive snaps."""
        team_tot = box.groupby(["game_id", "team"])[["targets", "carries", "attempts"]].sum()
        by_player = {(r.game_id, r.team, r.player): r for r in box.itertuples(index=False)}
        for (gid, team), tot in team_tot.iterrows():
            opp = opp_of.get((gid, team))
            if opp is None:
                continue
            kalman_update([(self.vol_att_off, team, 1), (self.vol_att_def, opp, 1)], tot.attempts, self.mu["att"],
                          8.0**2, season, wi)
            kalman_update([(self.vol_car_off, team, 1), (self.vol_car_def, opp, 1)], tot.carries, self.mu["car"],
                          6.0**2, season, wi)
            self._drift_mu("att", tot.attempts, 0.01)
            self._drift_mu("car", tot.carries, 0.01)
            players = set(candidates.get((gid, team), ())) | {k[2] for k in by_player if k[0] == gid and k[1] == team}
            for pl in players:
                r = by_player.get((gid, team, pl))
                ps = pos.get(pl, "WR")
                t = r.targets if r is not None else 0.0
                c = r.carries if r is not None else 0.0
                a = r.attempts if r is not None else 0.0
                if tot.attempts > 0 and ps != "QB":
                    s = t / tot.attempts
                    m = self.mu[f"tshare_{ps}"]
                    kalman_update([(self.tshare, pl, 1)], s, m, max(s * (1 - s), 0.02) / tot.attempts, season, wi)
                if tot.carries > 0 and ps in ("RB", "QB", "WR"):
                    s = c / tot.carries
                    kalman_update([(self.cshare, pl, 1)], s, self.mu[f"cshare_{ps}"],
                                  max(s * (1 - s), 0.02) / tot.carries, season, wi)
                if ps == "QB" and tot.attempts > 0 and a > 0:
                    s = a / tot.attempts
                    kalman_update([(self.ashare, pl, 1)], s, self.mu["ashare"], 0.05, season, wi)


def run_prop_ratings(games: pd.DataFrame, plays: pd.DataFrame, snaps: pd.DataFrame, pos: dict,
                     want: set | None = None, params: PropParams | None = None):
    """Walk weeks in order. Before each week, project every skill player who took a snap
    (and every (game, player) in `want`). Returns projections with actual results."""
    pr = PropRatings(params)
    box = box_scores(plays)
    snaps = snaps.dropna(subset=["gsis_id"])
    snaps = snaps[snaps.offense_pct > 0]
    cand = defaultdict(list)
    team_alias = {}
    for r in snaps.itertuples(index=False):
        if POS_GROUP.get(r.position) in ("WR", "TE", "RB", "QB"):
            cand[(r.game_id, r.team)].append(r.gsis_id)
    # Map snap team codes onto play-by-play codes via side of the field.
    g = games.set_index("game_id")
    starters = {}
    for r in games.itertuples(index=False):
        starters[(r.game_id, r.home_team)] = r.home_qb_id
        starters[(r.game_id, r.away_team)] = r.away_qb_id
    cand_pbp = defaultdict(list)
    for (gid, team), pls in cand.items():
        if gid not in g.index:
            continue
        home = g.at[gid, "home_team"]
        side_home = team == gid.split("_")[-1]
        cand_pbp[(gid, home if side_home else g.at[gid, "away_team"])].extend(pls)
    opp_of = {}
    for r in games.itertuples(index=False):
        opp_of[(r.game_id, r.home_team)] = r.away_team
        opp_of[(r.game_id, r.away_team)] = r.home_team
    box_by_game = {k: v for k, v in box.groupby("game_id")}
    plays_by_week = {k: v for k, v in plays.groupby(["season", "week"])}
    rows = []
    actual = {(r.game_id, r.player): r for r in box.itertuples(index=False)}
    for (season, week), block in games.sort_values(["season", "week"]).groupby(["season", "week"], sort=True):
        season, week = int(season), int(week)
        wi = week_index(season, week)
        for gm in block.itertuples(index=False):
            for team, opp, sign in ((gm.home_team, gm.away_team, 1), (gm.away_team, gm.home_team, -1)):
                pls = set(cand_pbp.get((gm.game_id, team), ()))
                if want:
                    pls |= {pl for (gid, pl) in want if gid == gm.game_id}
                if gm.game_id in box_by_game:
                    b = box_by_game[gm.game_id]
                    pls |= set(b.loc[b.team == team, "player"])
                qb = starters.get((gm.game_id, team))
                qb = qb if isinstance(qb, str) else None
                spread_t = (gm.spread_line if sign == 1 else -gm.spread_line) if pd.notna(gm.spread_line) else 0.0
                itt = (gm.total_line / 2 + spread_t / 2) if pd.notna(gm.total_line) else 22.0
                for pl in pls:
                    ps = pos.get(pl, "WR")
                    proj = pr.project(pl, ps, team, opp, qb if ps != "QB" else pl, season, wi)
                    a = actual.get((gm.game_id, pl))
                    if a is not None and a.team != team:
                        continue
                    rows.append({"game_id": gm.game_id, "season": season, "week": week, "player": pl, "pos": ps,
                                 "team": team, "opp": opp, "spread_t": spread_t, "itt": itt,
                                 **{f"proj_{m}": proj[m] for m in METRICS},
                                 **{m: (getattr(a, m) if a is not None else 0.0) for m in METRICS},
                                 "played": a is not None or pl in set(cand_pbp.get((gm.game_id, team), ()))})
        wk = plays_by_week.get((season, week))
        if wk is not None:
            pr.update_plays(wk, pos, season, wi)
            wb = box[box.game_id.isin(set(block.game_id))]
            pr.update_shares(wb, cand_pbp, pos, opp_of, season, wi)
    return pd.DataFrame(rows), pr


def fit_scale(train: pd.DataFrame, metric: str) -> np.ndarray:
    """actual ~ proj x (a + b x spread + c x (implied team total - 22)), least squares."""
    t = train[train[f"proj_{metric}"] > 0]
    pj = t[f"proj_{metric}"].values
    x = np.column_stack([pj, pj * t.spread_t.values, pj * (t.itt.values - 22)])
    beta, *_ = np.linalg.lstsq(x, t[metric].values, rcond=None)
    return beta


def apply_scale(beta, df, metric):
    pj = df[f"proj_{metric}"].values
    return np.maximum(0, pj * (beta[0] + beta[1] * df.spread_t.values + beta[2] * (df.itt.values - 22)))


def over_chance(proj: float, line: float, hist_proj: np.ndarray, hist_actual: np.ndarray, k: int = 600) -> float:
    """Share of earlier results, rescaled to this projection, that went over the line."""
    if proj <= 0 or len(hist_proj) == 0:
        return float("nan")
    idx = np.argsort(np.abs(np.log(hist_proj) - np.log(proj)))[:k]
    ratio = hist_actual[idx] / hist_proj[idx]
    sims = proj * ratio
    over = (sims > line).mean()
    # Laplace-style smoothing so a chance is never exactly 0 or 1.
    return float((over * len(idx) + 1) / (len(idx) + 2))
