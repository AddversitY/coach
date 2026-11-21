import unittest

from line_movement_backtest import (
    adopted,
    favorite_cover_rate,
    parse_archive_html,
)

SNIPPET = """
<table>
<tr><td>Date</td><td>Rot</td><td>VH</td><td>Team</td><td>1st</td><td>2nd</td><td>3rd</td><td>4th</td><td>Final</td><td>Open</td><td>Close</td><td>ML</td><td>2H</td></tr>
<tr><td>909</td><td>451</td><td>V</td><td>Dallas</td><td>7</td><td>9</td><td>10</td><td>3</td><td>29</td><td>52.5</td><td>52.5</td><td>375</td><td>27</td></tr>
<tr><td>909</td><td>452</td><td>H</td><td>TampaBay</td><td>7</td><td>14</td><td>7</td><td>3</td><td>31</td><td>7</td><td>10</td><td>-450</td><td>2</td></tr>
</table>
"""


ALIASES = """
<table>
<tr><td>918</td><td>279</td><td>V</td><td>Seattle</td><td>0</td><td>3</td><td>0</td><td>0</td><td>3</td><td>40.5</td><td>38</td><td>-240</td><td>20</td></tr>
<tr><td>918</td><td>280</td><td>H</td><td>LosAngeles</td><td>3</td><td>3</td><td>0</td><td>3</td><td>9</td><td>3</td><td>6</td><td>200</td><td>3</td></tr>
<tr><td>1108</td><td>453</td><td>V</td><td>Carolina</td><td>7</td><td>0</td><td>0</td><td>7</td><td>14</td><td>47</td><td>46.5</td><td>180</td><td>23</td></tr>
<tr><td>1108</td><td>454</td><td>H</td><td>KCChiefs</td><td>3</td><td>10</td><td>7</td><td>13</td><td>33</td><td>10</td><td>10</td><td>-220</td><td>7</td></tr>
<tr><td>1207</td><td>486</td><td>H</td><td>Pittsburgh</td><td>7</td><td>7</td><td>0</td><td>3</td><td>17</td><td>3</td><td>3</td><td>-170</td><td>3</td></tr>
<tr><td>1207</td><td>487</td><td>V</td><td>Washingtom</td><td>0</td><td>3</td><td>7</td><td>13</td><td>23</td><td>41.5</td><td>43.5</td><td>150</td><td>21</td></tr>
<tr><td>1110</td><td>210</td><td>H</td><td>NewYork</td><td>7</td><td>7</td><td>7</td><td>3</td><td>24</td><td>7</td><td>7</td><td>-325</td><td>6</td></tr>
<tr><td>1110</td><td>211</td><td>V</td><td>St.Louis</td><td>7</td><td>21</td><td>10</td><td>0</td><td>38</td><td>42</td><td>43</td><td>280</td><td>22</td></tr>
</table>
"""


class ArchiveTests(unittest.TestCase):
    def test_home_favorite_spread_is_positive_and_the_total_is_the_other_row(self):
        games, unknown, skipped = parse_archive_html(SNIPPET, 2021)
        self.assertEqual(unknown, [])
        self.assertEqual(skipped, 0)
        self.assertEqual(len(games), 1)
        game = games[0]
        self.assertEqual(game['away'], 'DAL')
        self.assertEqual(game['home'], 'TB')
        self.assertEqual(game['openSpread'], 7)
        self.assertEqual(game['closeSpread'], 10)
        self.assertEqual(game['openTotal'], 52.5)
        self.assertEqual(game['closeTotal'], 52.5)
        self.assertEqual(game['date'], '2021-09-09')
        rate, decided = favorite_cover_rate(games)
        self.assertEqual(decided, 1)
        self.assertEqual(rate, 0)

    def test_archive_spellings_map_only_when_the_club_is_clear(self):
        games, unknown, _skipped = parse_archive_html(ALIASES, 2016)
        codes = {(game['away'], game['home']) for game in games}
        self.assertIn(('SEA', 'LAR'), codes)
        self.assertIn(('CAR', 'KC'), codes)
        self.assertIn(('WAS', 'PIT'), codes)
        self.assertEqual(unknown, ['NewYork'])
        later, later_unknown, _skipped = parse_archive_html(ALIASES, 2017)
        self.assertNotIn('LAR', [game['home'] for game in later])
        self.assertIn('LosAngeles', later_unknown)
        self.assertIn('NewYork', later_unknown)

    def test_missing_test_seasons_are_not_adopted(self):
        self.assertFalse(adopted({}))
        self.assertFalse(adopted({'2021': {
            'coverModel': {'n': 200, 'brier': 0.2, 'logLoss': 0.5},
            'coverFlat': {'n': 200, 'brier': 0.25, 'logLoss': 0.69},
            'totalModel': {'n': 200, 'brier': 0.2, 'logLoss': 0.5},
            'totalFlat': {'n': 200, 'brier': 0.25, 'logLoss': 0.69},
            'moneyModel': {'n': 200, 'brier': 0.2, 'logLoss': 0.5},
            'moneyPrice': {'n': 200, 'brier': 0.25, 'logLoss': 0.69},
        }}))


if __name__ == '__main__':
    unittest.main()
