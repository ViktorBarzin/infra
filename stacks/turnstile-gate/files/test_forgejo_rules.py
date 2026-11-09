"""Unit tests for forgejo_rules.py. Run: python3 -m unittest discover -s stacks/turnstile-gate/files"""

import unittest

import forgejo_rules as fr

# Real URLs from the 2026-11 crawl (Traefik access log, 2026-11-08).
CRAWL_A = ("/viktor/infra/pulls?q=&type=all&sort=latest&state=open&labels=12%2C13%2C14%2C15%2C16%2C18%2C27"
           "&milestone=0&project=-1&assignee=&poster=0")
CRAWL_B = ("/viktor/infra/pulls?q=&type=all&sort=recentupdate&labels=13%2C14%2C16%2C18%2C19%2C27&state=open"
           "&milestone=-1&project=-1&assignee=1&poster=0")
# The links Forgejo itself renders on the issue list (state tabs): every filter
# at its default.
FORGEJO_DEFAULT = ("/viktor/infra/issues?q=&type=all&sort=relevance&state=closed&labels=&milestone=0&project=0"
                   "&assignee=0&poster=0&archived=false")


class FilteredListTest(unittest.TestCase):
    def test_crawler_urls_are_filtered_lists(self) -> None:
        for uri in (CRAWL_A, CRAWL_B):
            self.assertTrue(fr.is_filtered_list(uri), uri)

    def test_each_filter_on_its_own_counts(self) -> None:
        for query in ("labels=7", "labels=-7", "milestone=3", "milestone=-1", "project=-1", "assignee=1",
                      "assignee=-1", "poster=2"):
            for kind in ("issues", "pulls"):
                uri = f"/someone/repo/{kind}?{query}"
                self.assertTrue(fr.is_filtered_list(uri), uri)

    def test_defaults_and_non_filter_parameters_do_not_count(self) -> None:
        for uri in (FORGEJO_DEFAULT, "/viktor/infra/issues", "/viktor/infra/issues?state=closed",
                    "/viktor/infra/pulls?sort=oldest&type=all&q=", "/viktor/infra/issues?q=nfs&state=all",
                    "/viktor/infra/issues?labels=&milestone=0&project=0&assignee=0&poster=0"):
            self.assertFalse(fr.is_filtered_list(uri), uri)

    def test_html_escaped_ampersands_are_separators(self) -> None:
        # Traefik's JSON log escapes & as &; X-Forwarded-Uri arrives raw,
        # but the parser must not care which one it is handed.
        self.assertTrue(fr.is_filtered_list("/viktor/infra/issues?state=open\\u0026labels=4"))

    def test_only_repo_issue_and_pull_lists(self) -> None:
        for uri in ("/viktor/infra/issues/12?labels=4", "/viktor/infra/src/branch/master?labels=4",
                    "/viktor/issues?labels=4", "/issues?labels=4", "/viktor/infra/pulls/3/files?assignee=1",
                    "/api/v1/repos/viktor/infra/issues?labels=4", "/viktor/infra/milestones?state=open"):
            self.assertFalse(fr.is_filtered_list(uri), uri)


class ColdFilterOpenTest(unittest.TestCase):
    def test_refuses_a_filtered_list_not_referred_by_our_sites(self) -> None:
        refusal = fr.cold_filter_open(CRAWL_A, referred_by_us=False)
        assert refusal is not None
        self.assertEqual(refusal.reason, fr.COLD_FILTER_REASON)

    def test_allows_a_filtered_list_clicked_from_our_sites(self) -> None:
        self.assertIsNone(fr.cold_filter_open(CRAWL_A, referred_by_us=True))

    def test_allows_everything_that_is_not_a_filtered_list(self) -> None:
        for uri in (FORGEJO_DEFAULT, "/viktor/infra", "/viktor/infra/src/branch/master/README.md",
                    "/viktor/infra/issues/12", "/viktor/infra/commits/branch/master"):
            self.assertIsNone(fr.cold_filter_open(uri, referred_by_us=False), uri)

    def test_page_links_to_the_list_and_back_to_the_view(self) -> None:
        refusal = fr.cold_filter_open(CRAWL_B, referred_by_us=False)
        assert refusal is not None
        self.assertIn('href="/viktor/infra/pulls"', refusal.body)
        self.assertIn('href="/viktor/infra/pulls?q=&amp;type=all', refusal.body)
        # The links must carry a Referer back to us, whatever the browser default.
        self.assertIn('<meta name="referrer" content="same-origin">', refusal.body)

    def test_page_escapes_the_uri(self) -> None:
        refusal = fr.cold_filter_open('/a/b/issues?labels=1&x="><script>alert(1)</script>', referred_by_us=False)
        assert refusal is not None
        self.assertNotIn("<script>alert", refusal.body)
        self.assertIn("&lt;script&gt;", refusal.body)


if __name__ == "__main__":
    unittest.main()
