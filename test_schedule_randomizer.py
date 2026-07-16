import unittest

from schedule_randomizer import SEARCH_TOTAL_MAX, SEARCH_TOTAL_MIN, random_search_split


class SearchSplitTests(unittest.TestCase):
    def test_random_search_split_uses_one_total_and_splits_between_pc_and_mobile(self):
        class FixedRng:
            def __init__(self):
                self.calls = []

            def randint(self, minimum, maximum):
                self.calls.append((minimum, maximum))
                if len(self.calls) == 1:
                    return SEARCH_TOTAL_MAX
                return maximum

        rng = FixedRng()

        pc, mobile = random_search_split(rng)

        self.assertEqual((pc, mobile), (SEARCH_TOTAL_MAX, 0))
        self.assertEqual(
            rng.calls,
            [(SEARCH_TOTAL_MIN, SEARCH_TOTAL_MAX), (0, SEARCH_TOTAL_MAX)],
        )
        self.assertGreaterEqual(pc + mobile, 20)


if __name__ == "__main__":
    unittest.main()
