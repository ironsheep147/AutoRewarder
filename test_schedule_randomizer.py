import unittest

from schedule_randomizer import random_search_split


class SearchSplitTests(unittest.TestCase):
    def test_random_search_split_uses_one_total_and_splits_between_pc_and_mobile(self):
        class FixedRng:
            def __init__(self):
                self.calls = []

            def randint(self, minimum, maximum):
                self.calls.append((minimum, maximum))
                if len(self.calls) == 1:
                    return maximum
                return maximum

        rng = FixedRng()

        pc, mobile = random_search_split(rng)

        self.assertEqual((pc, mobile), (50, 0))
        self.assertEqual(
            rng.calls,
            [(40, 50), (0, 50)],
        )
        self.assertGreaterEqual(pc + mobile, 40)


if __name__ == "__main__":
    unittest.main()
