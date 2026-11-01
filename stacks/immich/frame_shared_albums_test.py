#!/usr/bin/env python3
"""Tests for frame_shared_albums.

The album shapes are trimmed copies of what GET /api/albums returned for
Milka's frame key on 2026-11-01 (Immich v3.3.5): the list carries no ownerId,
only albumUsers with a role, so ownership has to be read from there.

Run: python3 frame_shared_albums_test.py
"""

import unittest

from frame_shared_albums import render, shared_album_ids

ME = "b3755667-51ac-4a1e-ad6a-24884db48775"
VIKTOR = "2a2ab475-dc9b-48d5-9f47-9f60931a8bcf"
EMO = "8593371b-f18d-451f-a481-53c92429c7a4"
DROP = "0d174625-d279-49dd-a446-0eaeda03d7ff"
VEGAS = "3d91633b-876b-4e3d-aef7-234f2e1f0825"


def album(aid, owner, *others):
    users = [{"user": {"id": owner}, "role": "owner"}]
    users += [{"user": {"id": o}, "role": "editor"} for o in others]
    return {"id": aid, "albumUsers": users}


TEMPLATE = """\
General:
    Layout: single
Accounts:
    - ImmichServerUrl: https://immich.example
      ApiKey: k
      ImagesFromDays: 1825
      ExcludedAlbums:
        - %s
    # shared-albums-account
""" % DROP


class SharedAlbumIds(unittest.TestCase):
    def test_album_someone_else_owns_and_shared_with_her_is_included(self):
        self.assertEqual(shared_album_ids([album(VEGAS, VIKTOR, ME, EMO)], ME, []),
                         [VEGAS])

    def test_her_own_album_is_left_out(self):
        # Her own albums hold her own photos, which the library account shows.
        self.assertEqual(shared_album_ids([album(DROP, ME)], ME, []), [])

    def test_her_own_album_shared_with_others_is_left_out(self):
        self.assertEqual(shared_album_ids([album("a1", ME, VIKTOR)], ME, []), [])

    def test_excluded_album_is_left_out_even_when_shared(self):
        self.assertEqual(shared_album_ids([album(VEGAS, VIKTOR, ME)], ME, [VEGAS]), [])

    def test_result_is_sorted_and_deduplicated(self):
        albums = [album("b", VIKTOR, ME), album("a", EMO, ME), album("b", VIKTOR, ME)]
        self.assertEqual(shared_album_ids(albums, ME, []), ["a", "b"])

    def test_album_without_users_is_ignored(self):
        self.assertEqual(shared_album_ids([{"id": "x", "albumUsers": []}], ME, []), [])


class Render(unittest.TestCase):
    def test_no_shared_albums_leaves_the_library_account_alone(self):
        out = render(TEMPLATE, [], "https://immich.example", "k", [DROP])
        self.assertNotIn("Albums:\n", out.replace("ExcludedAlbums:\n", ""))
        self.assertIn("ImagesFromDays: 1825", out)

    def test_shared_albums_become_a_second_account_at_the_marker_indent(self):
        out = render(TEMPLATE, [VEGAS, "a2"], "https://immich.example", "k", [DROP])
        self.assertTrue(out.endswith(
            "    - ImmichServerUrl: https://immich.example\n"
            "      ApiKey: k\n"
            "      ExcludedAlbums:\n"
            "        - %s\n"
            "      Albums:\n"
            "        - %s\n"
            "        - a2\n" % (DROP, VEGAS)), out)

    def test_second_account_has_no_date_window(self):
        # A shared trip album from years ago should show in full, not be cut by
        # the library account's ImagesFromDays.
        out = render(TEMPLATE, [VEGAS], "https://immich.example", "k", [DROP])
        self.assertEqual(out.count("ImagesFromDays"), 1)

    def test_first_account_is_unchanged(self):
        out = render(TEMPLATE, [VEGAS], "https://immich.example", "k", [DROP])
        head = TEMPLATE.split("    # shared-albums-account")[0]
        self.assertTrue(out.startswith(head))

    def test_template_without_marker_is_an_error(self):
        with self.assertRaises(ValueError):
            render("Accounts:\n    - ImmichServerUrl: x\n", [VEGAS], "x", "k", [])


if __name__ == "__main__":
    unittest.main()
