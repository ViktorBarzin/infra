#!/usr/bin/env python3
"""Tests for frame_sync_viktor.

Asset shapes are trimmed copies of what POST /api/search/metadata with
withPeople=true returned for Viktor's frame key on 2026-11-25 (Immich v3.4.2).
That response carries `people` (faces assigned to a person) but no unassigned
faces, which is why plan() needs a faces lookup for assets with no people.

Run: python3 frame_sync_viktor_test.py
"""

import unittest
from datetime import datetime, timezone

from frame_sync_viktor import plan

VIKTOR = "409ea64b-7163-4189-a211-ab55651f645b"
ANCA = "fc207035-ae2a-4baa-9aa5-f0082846777e"
HIMANI = "ff9cb394-509b-4561-83f7-19d0462b2336"
US = {VIKTOR, ANCA}
NOW = datetime(2026, 11, 25, tzinfo=timezone.utc)
OLD = "2026-01-01T10:00:00.000Z"
NEW = "2026-11-24T10:00:00.000Z"


def asset(aid, *people, created=OLD):
    return {"id": aid, "createdAt": created,
            "people": [{"id": p} for p in people] or None}


def run(assets, in_album=(), faces=None, window_days=14):
    faces = faces or {}
    looked_up = []

    def has_faces(aid):
        looked_up.append(aid)
        return faces.get(aid, False)

    add, remove = plan(assets, set(in_album), US, has_faces, NOW, window_days)
    return add, remove, looked_up


class Plan(unittest.TestCase):
    def test_photo_with_viktor_is_shown(self):
        self.assertEqual(run([asset("a", VIKTOR)])[:2], (set(), set()))

    def test_photo_with_anca_and_a_stranger_is_shown(self):
        self.assertEqual(run([asset("a", ANCA, HIMANI)])[:2], (set(), set()))

    def test_photo_of_only_other_people_is_hidden(self):
        self.assertEqual(run([asset("a", HIMANI)])[:2], ({"a"}, set()))

    def test_hidden_photo_now_recognised_as_us_comes_back(self):
        # A face that was unassigned when the photo was hidden can later be
        # clustered into Viktor or Anca; the photo must return to the frame.
        self.assertEqual(run([asset("a", ANCA)], in_album={"a"})[:2],
                         (set(), {"a"}))

    def test_new_photo_with_only_unassigned_faces_is_hidden(self):
        add, remove, looked = run([asset("a", created=NEW)], faces={"a": True})
        self.assertEqual((add, remove, looked), ({"a"}, set(), ["a"]))

    def test_new_landscape_is_shown(self):
        add, remove, looked = run([asset("a", created=NEW)], in_album={"a"})
        self.assertEqual((add, remove, looked), (set(), {"a"}, ["a"]))

    def test_old_photo_without_people_is_left_as_it_is(self):
        # Outside the window the faces lookup is skipped, so membership stands:
        # a stranger hidden at seed time stays hidden, a landscape stays shown.
        add, remove, looked = run([asset("a"), asset("b")], in_album={"a"})
        self.assertEqual((add, remove, looked), (set(), set(), []))

    def test_album_member_no_longer_in_the_library_is_left_alone(self):
        # Trashed or archived assets drop out of the search; the frame never
        # shows them, so there is nothing to undo.
        self.assertEqual(run([], in_album={"gone"})[:2], (set(), set()))


if __name__ == "__main__":
    unittest.main()
