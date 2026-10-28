#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sweep", ROOT / "scripts/weekly-org-branch-sweep.py")
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)

REPO, SHA = "qwickapps/example", "a" * 40
NOW = datetime(2026, 10, 28, tzinfo=timezone.utc)

class FakeApi:
    def __init__(self, responses):
        self.responses, self.calls = responses, []
    def request(self, endpoint, method="GET", fields=None, paginate=False):
        self.calls.append((endpoint, method, fields, paginate))
        response = self.responses.get((endpoint, method), self.responses.get(endpoint, (None, "HTTP 404")))
        return response() if callable(response) else response

def branch(name="feature/old", days=91):
    # Matches GET /repos/{owner}/{repo}/branches: commit has sha/url only.
    return {"name": name, "commit": {"sha": SHA, "url": f"https://api.github.com/repos/{REPO}/commits/{SHA}"}}

def endpoints(name="feature/old", pr_list=None, compare_ahead=2, days=91):
    encoded = name.replace("/", "%2F")
    return {
        f"repos/{REPO}/commits/{SHA}": ({"commit": {"author": {"date": (NOW - timedelta(days=days)).isoformat()}}}, ""),
        f"repos/{REPO}/branches/{encoded}/protection": (None, "HTTP 404"),
        f"repos/{REPO}/rules/branches/{encoded}": ([], ""),
        f"repos/{REPO}/compare/main...{SHA}": ({"ahead_by": compare_ahead}, ""),
        f"repos/{REPO}/issues/7/comments?per_page=100": ([], ""),
    }

def classify(api, item, prs=None):
    return sweep.classify(api, REPO, "main", item, prs or [], NOW)

class WeeklySweepTests(unittest.TestCase):
    def test_protected_patterns_are_untouchable(self):
        for name in ("main", "master", "dev", "develop", "release/1.0", "v1-stable"):
            with self.subTest(name=name):
                record = classify(FakeApi({}), branch(name))
                self.assertEqual("skipped", record["action"])
                self.assertEqual("protected branch name", record["reason"])

    def test_recent_commit_is_untouchable(self):
        record = classify(FakeApi(endpoints(days=13)), branch(days=13))
        self.assertEqual("skipped", record["action"])
        self.assertIn("14 days", record["reason"])

    def test_branch_protection_and_ruleset_are_untouchable(self):
        for response in (({"enabled": True}, ""), (None, "HTTP 404")):
            responses = endpoints()
            if response[0]:
                responses[f"repos/{REPO}/branches/feature%2Fold/protection"] = response
            else:
                responses[f"repos/{REPO}/rules/branches/feature%2Fold"] = ([{"id": 1}], "")
            record = classify(FakeApi(responses), branch())
            self.assertEqual("skipped", record["action"])

    def test_merged_or_ancestor_branch_deletes(self):
        record = classify(FakeApi(endpoints(compare_ahead=0)), branch())
        self.assertEqual("delete", record["action"])
        merged = {"state": "closed", "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "m" * 40, "number": 7, "head": {"ref": "feature/old"}}
        responses = endpoints(compare_ahead=2)
        responses[f"repos/{REPO}/compare/{'m'*40}...{SHA}"] = ({"ahead_by": 0}, "")
        record = classify(FakeApi(responses), branch(), [merged])
        self.assertEqual("delete", record["action"])

    def test_old_unmerged_or_no_pr_archives_before_delete(self):
        api = FakeApi(endpoints())
        record = classify(api, branch())
        self.assertEqual("archive_delete", record["action"])
        tag = "archive/feature/old"
        api.responses[(f"repos/{REPO}/git/refs", "POST")] = (None, "")
        api.responses[f"repos/{REPO}/git/ref/tags/archive%2Ffeature%2Fold"] = ({"object": {"sha": SHA}}, "")
        api.responses[(f"repos/{REPO}/git/refs/heads/feature%2Fold", "DELETE")] = (None, "")
        result = sweep.execute(api, record, dry_run=False)
        self.assertEqual("archived_deleted", result["action"])
        writes = [(call[0], call[1]) for call in api.calls if call[1] != "GET"]
        self.assertEqual([(f"repos/{REPO}/git/refs", "POST"), (f"repos/{REPO}/git/refs/heads/feature%2Fold", "DELETE")], writes)

    def test_archive_tag_must_verify_before_delete(self):
        api = FakeApi(endpoints())
        record = classify(api, branch())
        api.responses[(f"repos/{REPO}/git/refs", "POST")] = (None, "")
        api.responses[f"repos/{REPO}/git/ref/tags/archive%2Ffeature%2Fold"] = ({"object": {"sha": "b" * 40}}, "")
        result = sweep.execute(api, record, dry_run=False)
        self.assertEqual("skipped", result["action"])
        self.assertNotIn((f"repos/{REPO}/git/refs/heads/feature%2Fold", "DELETE"), [(c[0], c[1]) for c in api.calls])

    def test_stale_open_pr_warns_once_and_only_once(self):
        pr = {"state": "open", "number": 7, "head": {"ref": "feature/old"}}
        api = FakeApi(endpoints())
        record = classify(api, branch(days=31), [pr])
        self.assertEqual("warn", record["action"])
        result = sweep.execute(api, record, dry_run=True)
        self.assertEqual("would_warn", result["action"])
        responses = endpoints()
        responses[f"repos/{REPO}/issues/7/comments?per_page=100"] = ([{"body": sweep.MARKER}], "")
        self.assertEqual("skipped", classify(FakeApi(responses), branch(days=31), [pr])["action"])

    def test_dry_run_never_writes(self):
        api = FakeApi(endpoints(compare_ahead=0))
        result = sweep.execute(api, classify(api, branch()), dry_run=True)
        self.assertEqual("would_delete", result["action"])
        self.assertFalse(any(call[1] != "GET" for call in api.calls))

if __name__ == "__main__":
    unittest.main(verbosity=2)
