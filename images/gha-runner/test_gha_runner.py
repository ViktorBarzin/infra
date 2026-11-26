"""Run: python3 -m unittest discover -s images/gha-runner"""

import unittest

import gha_runner


class WaitingJobs(unittest.TestCase):
    def test_only_queued_homelab_jobs_wait(self):
        runs = {
            1: [
                {"id": 10, "status": "queued", "labels": ["homelab"]},
                {"id": 11, "status": "queued", "labels": ["ubuntu-latest"]},
                {"id": 12, "status": "in_progress", "labels": ["homelab"]},
            ],
            2: [{"id": 20, "status": "completed", "labels": ["homelab"]}],
        }
        self.assertEqual([j["id"] for j in gha_runner.waiting_jobs(runs)], [10])

    def test_nothing_waits_when_there_are_no_runs(self):
        self.assertEqual(gha_runner.waiting_jobs({}), [])


if __name__ == "__main__":
    unittest.main()
