import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "files" / "mam-farming-janitor.py"
SPEC = importlib.util.spec_from_file_location("mam_farming_janitor", SCRIPT)
JANITOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(JANITOR)


class ClassifyTest(unittest.TestCase):
    def test_tracker_margin_preserves_torrent_after_site_minimum(self):
        torrent = {
            "added_on": 0,
            "progress": 1.0,
            "downloaded": 1,
            "uploaded": 1,
            "seeding_time": 72 * 3600 + 1,
            "state": "stalledUP",
            "num_complete": 20,
            "tags": "mam, freeleech",
        }

        self.assertEqual(JANITOR.classify(torrent, 4 * 86400, ""), "hnr_window")

    def test_recovery_torrent_is_held_while_rebuilding(self):
        torrent = {
            "added_on": 0,
            "progress": 0.0,
            "downloaded": 0,
            "uploaded": 0,
            "seeding_time": 0,
            "state": "queuedDL",
            "num_complete": 20,
            "tags": "mam, recovery",
        }

        self.assertEqual(JANITOR.classify(torrent, 2 * 86400, ""), "recovery_hold")

    def test_recovery_hold_expires_after_a_week_of_seeding(self):
        torrent = {
            "added_on": 0,
            "progress": 1.0,
            "downloaded": 1,
            "uploaded": 1,
            "seeding_time": 7 * 86400 + 1,
            "state": "stalledUP",
            "num_complete": 20,
            "tags": "mam, recovery",
        }

        self.assertEqual(
            JANITOR.classify(torrent, 8 * 86400, ""), "satisfied_redundant"
        )


if __name__ == "__main__":
    unittest.main()
