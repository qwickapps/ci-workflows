#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("settings", ROOT / "scripts/configure-org-merge-settings.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

class FakeApi:
    def __init__(self, prs, commits): self.prs, self.commits = prs, commits
    def request(self, endpoint, method="GET", fields=None, paginate=False):
        if endpoint.endswith("/pulls?state=closed&per_page=100"): return self.prs, ""
        return self.commits.get(endpoint, (None, "HTTP 404"))

class MergeExceptionTests(unittest.TestCase):
    def test_two_parent_merge_to_nondefault_does_not_preserve_merge_commits(self):
        sha = "a" * 40
        prs = [{"number": 31, "base": {"ref": "release/1.0"}, "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": sha}]
        api = FakeApi(prs, {f"repos/qwickapps/example/git/commits/{sha}": ({"parents": [{}, {}]}, "")})
        cutoff = datetime(2026, 9, 1, tzinfo=timezone.utc)
        self.assertFalse(settings.has_recent_true_merge(api, "qwickapps/example", "main", cutoff))

    def test_two_parent_merge_to_default_is_exception(self):
        sha = "b" * 40
        prs = [{"number": 32, "base": {"ref": "main"}, "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": sha}]
        api = FakeApi(prs, {f"repos/qwickapps/example/git/commits/{sha}": ({"parents": [{}, {}]}, "")})
        cutoff = datetime(2026, 9, 1, tzinfo=timezone.utc)
        self.assertEqual(32, settings.has_recent_true_merge(api, "qwickapps/example", "main", cutoff))

    def test_incomplete_pr_metadata_is_ignored(self):
        prs = [
            {"number": 33, "base": {"ref": "main"}, "merged_at": None, "merge_commit_sha": "c" * 40},
            {"number": 34, "base": {"ref": "main"}, "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": None},
        ]
        api = FakeApi(prs, {})
        cutoff = datetime(2026, 9, 1, tzinfo=timezone.utc)
        self.assertFalse(settings.has_recent_true_merge(api, "qwickapps/example", "main", cutoff))

if __name__ == "__main__": unittest.main(verbosity=2)
