import unittest

from news_backtest import group_of, norm, practice_label


class NewsBacktestTests(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(practice_label('Did Not Participate In Practice'), 'did not practice')
        self.assertEqual(practice_label('Limited Participation in Practice'), 'limited')
        self.assertEqual(practice_label('Full Participation in Practice'), 'full')
        self.assertEqual(group_of('OLB'), 'LB')
        self.assertEqual(group_of('K'), None)
        self.assertEqual(norm('Odell Beckham Jr.'), norm('Odell Beckham'))


if __name__ == '__main__':
    unittest.main()
