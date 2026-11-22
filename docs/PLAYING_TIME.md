# Playing time

Checked November 22, 2026. The question was whether free snap, route, and injury-role information should move the yard and reception projection. The card already uses the player's own recent target share, carry share, or dropback share. This test puts nflverse playing time on top of that card. It does not replace the card. A lower score is a closer chance or a closer yardage number. It is a comparison, not a pick, and it is not a betting edge.

## What the test added

The shares are the derived file `assets/prop-usage.json`, built from public nflverse releases (CC BY 4.0). No new feed and no account.

- Snap share, from snap counts.
- Route share: the share of team dropbacks on which the player was on the field. That file exists for 2023–2025. 2026 route share is unavailable because participation was not published. A receiver week with no route share uses snap share when a snap share exists. If neither share exists, the projection stays on the current card.
- Target share and carry share stay the card's own recent volume. They move only when a teammate is newly listed Out. The teammate has to have played the team's previous game and to have had a real target share or carry share. Part of that share is split by playing time and shrunk toward no extra share. A quarterback listed Out moves the other quarterback's dropback share part of the way toward a starter's share, then shrinks it. When that teammate is no longer listed Out, the recent share is pulled back toward the games they played.

The Out list is `assets/nfl-outs.json`, the nflverse weekly report, used as the pregame list. Doubtful and questionable are not Out. The box score of the week being scored is not an input. Every playing-time input is an earlier week.

The sizes were written down before this run. They are the constants in `lib/domain/playing_time.dart`. They were not searched on 2025 or 2026.

## The walk-forward

Same player-games as the card. To score a week, only earlier weeks are used. The line is last season's median. The anchor is a fair 50%, because this repo does not have two-sided 2025 prop prices. The shown chance is the card's curve, the 32-game shrink, and the gap cap. Projection error is the average of |projection − actual| divided by a fixed scale: passing yards 70, rushing yards 25, receiving yards 30, receptions 2. Each prop counts once. Lower is closer. 2024 is context. It is not the adoption test.

The current row is the card as it stands: recent games weighted more, lognormal yards, and the unit matchup. Its 2025 and 2026 Brier and log loss match `docs/PROP_SPECIALIST.md`.

| Season | Path | Games | Brier | Log loss | Projection error |
| --- | --- | ---: | ---: | ---: | ---: |
| 2024 | Current card | 6,996 | 0.234306 | 0.661460 | 0.855385 |
| 2024 | Playing time | 6,996 | 0.233484 | 0.659794 | 0.852801 |
| 2025 | Current card | 6,924 | 0.228901 | 0.650173 | 0.832628 |
| 2025 | Playing time | 6,924 | 0.227779 | 0.647882 | 0.828701 |
| 2026 | Current card | 3,972 | 0.235611 | 0.663996 | 0.858517 |
| 2026 | Playing time | 3,972 | 0.235248 | 0.663249 | 0.858628 |

Mean absolute error, in yards or catches:

| Season | Stat | Games | Current | Playing time |
| --- | --- | ---: | ---: | ---: |
| 2025 | Passing yards | 477 | 69.2545 | 69.1718 |
| 2025 | Rushing yards | 1,142 | 23.0125 | 22.9463 |
| 2025 | Receiving yards | 2,640 | 22.4958 | 22.4281 |
| 2025 | Receptions | 2,665 | 1.6978 | 1.6846 |
| 2026 | Passing yards | 290 | 67.9316 | 68.1951 |
| 2026 | Rushing yards | 641 | 23.2929 | 23.1886 |
| 2026 | Receiving yards | 1,515 | 23.5909 | 23.6185 |
| 2026 | Receptions | 1,526 | 1.7563 | 1.7571 |

Playing time moved 3,215 of 6,924 games in 2025 and 1,944 of 3,972 games in 2026. Route share was the playing-time series on 5,286 games in 2025 and on 842 games in 2026. Snap share was the series on 1,580 games in 2025 and on 3,013 games in 2026. Playing time was unavailable on 58 games in 2025 and on 117 games in 2026; those projections stay on the current card. Route share was unavailable on 2,199 games in 2026.

Brier and log loss were lower in both 2025 and 2026. Projection error was lower in 2025 and higher in 2026. Passing yards, receiving yards, and receptions were also a little farther from the result in 2026. The rule is a lower Brier, a lower log loss, and a lower projection error in both seasons. One miss is enough. The card stays on the current projection. `playingTimeAdopted` is false.

Re-run from the repository root:

```bash
flutter test test/playing_time_test.dart --name walk-forward
```

`tools/playing_time_walkforward.dart` prints the same report.
