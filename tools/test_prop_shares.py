import unittest
from datetime import datetime, timedelta, timezone

from prop_shares import (
    american_to_decimal,
    consensus_prior,
    no_vig_over,
    norm_name,
    share,
    team_code,
)


class PropShareTests(unittest.TestCase):
    def test_name_and_team(self):
        self.assertEqual(norm_name("D.J. Moore Jr."), "dj moore")
        self.assertEqual(team_code("Jacksonville Jaguars"), "JAX")
        self.assertEqual(team_code("WSH"), "WAS")
        self.assertIsNone(team_code("Not A Club"))

    def test_share_and_price(self):
        self.assertEqual(share(4, 10), 0.4)
        self.assertIsNone(share(1, 0))
        self.assertAlmostEqual(american_to_decimal("-110"), 1 + 100 / 110)
        self.assertIsNone(american_to_decimal("9900"))
        self.assertIsNone(american_to_decimal(""))

    def test_no_vig_splits_a_balanced_pair(self):
        chance = no_vig_over(1.909, 1.909)
        self.assertIsNotNone(chance)
        self.assertAlmostEqual(chance, 0.5, places=3)

    def test_stale_book_is_old_and_far(self):
        now = datetime(2026, 9, 20, tzinfo=timezone.utc)
        books = [
            {"book": "pinnacle", "novig": 0.52, "at": now, "line": 49.5},
            {"book": "draftkings", "novig": 0.50, "at": now, "line": 49.5},
            {"book": "betmgm", "novig": 0.48, "at": now, "line": 49.5},
            {
                "book": "oldbook",
                "novig": 0.70,
                "at": now - timedelta(hours=4),
                "line": 49.5,
            },
        ]
        summary = consensus_prior(books)
        self.assertEqual(summary["stale"], 1)
        self.assertAlmostEqual(summary["pinnacle"], 0.52)
        self.assertAlmostEqual(summary["prior"], 0.5 * 0.52 + 0.5 * ((0.50 + 0.48) / 2))

    def test_missing_time_is_not_stale(self):
        now = datetime(2026, 9, 20, tzinfo=timezone.utc)
        books = [
            {"book": "pinnacle", "novig": 0.40, "at": None, "line": 19.5},
            {"book": "draftkings", "novig": 0.55, "at": now, "line": 19.5},
            {"book": "fanduel", "novig": 0.57, "at": now, "line": 19.5},
        ]
        summary = consensus_prior(books)
        self.assertEqual(summary["stale"], 0)
        self.assertEqual(summary["books"], 3)


if __name__ == "__main__":
    unittest.main()
