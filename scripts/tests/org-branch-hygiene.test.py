#!/usr/bin/env python3
"""Regression tests for the closed-unmerged-PR branch cleanup safety predicate."""
import importlib.util
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hygiene", ROOT / "scripts/org-branch-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class FakeGitHub:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def request(self, endpoint, method="GET", paginate=False):
        self.calls.append((endpoint, method, paginate))
        value = self.responses.get((endpoint, method), self.responses.get(endpoint))
        if isinstance(value, hygiene.Result):
            return value
        if value is None:
            return hygiene.Result(False, error="unmocked endpoint")
        return hygiene.Result(True, value)


REPO = "qwickapps/example"
BRANCH = "feature/clean-me"
SHA = "a" * 40
PR_ENDPOINT = f"repos/{REPO}/pulls/42"
REF_ENDPOINT = f"repos/{REPO}/{hygiene.endpoint_ref(BRANCH)}"
PROTECTION_ENDPOINT = f"repos/{REPO}/branches/feature%2Fclean-me/protection"
OPEN_ENDPOINT = f"repos/{REPO}/pulls?state=open&per_page=100"
DELETE_ENDPOINT = f"repos/{REPO}/git/refs/heads/feature%2Fclean-me"


def baseline():
    return {
        PR_ENDPOINT: {"state": "closed", "merged": False, "head": {"ref": BRANCH, "sha": SHA, "repo": {"full_name": REPO}}, "base": {"repo": {"full_name": REPO}}},
        f"repos/{REPO}": {"default_branch": "main"},
        REF_ENDPOINT: {"object": {"sha": SHA}},
        PROTECTION_ENDPOINT: hygiene.Result(False, error="HTTP 404", not_found=True),
        OPEN_ENDPOINT: [],
        (DELETE_ENDPOINT, "DELETE"): {},
    }


class CleanupSafetyTests(unittest.TestCase):
    def run_candidate(self, responses=None, allow=(), enforce=True):
        api = FakeGitHub(responses or baseline())
        record = hygiene.evaluate_candidate(api, REPO, 42, list(allow), enforce)
        return api, record

    def assert_never_deleted(self, responses=None, allow=()):
        api, record = self.run_candidate(responses, allow)
        self.assertEqual("skipped", record["action"])
        self.assertNotIn((DELETE_ENDPOINT, "DELETE", False), api.calls)

    def test_previous_main_lacked_the_closed_unmerged_predicate(self):
        old_source = subprocess.run(
            ["git", "show", "97760312a2ecab36eb74dec12b4e015c592239e7:scripts/org-branch-hygiene.py"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout
        self.assertIn("compare/", old_source)
        self.assertNotIn("PR is not closed and unmerged", old_source)

    def test_merged_pr_is_never_eligible(self):
        responses = baseline()
        responses[PR_ENDPOINT]["merged"] = True
        self.assert_never_deleted(responses)

    def test_same_repository_is_required(self):
        responses = baseline()
        responses[PR_ENDPOINT]["head"]["repo"]["full_name"] = "fork/example"
        self.assert_never_deleted(responses)

    def test_branch_sha_must_equal_pr_head(self):
        responses = baseline()
        responses[REF_ENDPOINT] = {"object": {"sha": "b" * 40}}
        self.assert_never_deleted(responses)

    def test_default_branch_is_never_deleted(self):
        responses = baseline()
        responses[PR_ENDPOINT]["head"]["ref"] = "main"
        responses[PR_ENDPOINT]["head"]["sha"] = SHA
        responses[f"repos/{REPO}"] = {"default_branch": "main"}
        self.assert_never_deleted(responses)

    def test_protected_branch_is_never_deleted(self):
        responses = baseline()
        responses[PROTECTION_ENDPOINT] = {"required_status_checks": {}}
        self.assert_never_deleted(responses)

    def test_protection_lookup_error_fails_closed(self):
        responses = baseline()
        responses[PROTECTION_ENDPOINT] = hygiene.Result(False, error="HTTP 500")
        self.assert_never_deleted(responses)

    def test_open_pr_head_is_never_deleted(self):
        responses = baseline()
        responses[OPEN_ENDPOINT] = [{"head": {"ref": BRANCH, "repo": {"full_name": REPO}}}]
        self.assert_never_deleted(responses)

    def test_allowlist_is_never_deleted(self):
        self.assert_never_deleted(allow=[{"repository": REPO, "branch": "feature/*"}])

    def test_refetch_before_delete_prevents_race_deletion(self):
        class RaceGitHub(FakeGitHub):
            def __init__(self):
                super().__init__(baseline())
                self.ref_reads = 0
            def request(self, endpoint, method="GET", paginate=False):
                if endpoint == REF_ENDPOINT and method == "GET":
                    self.ref_reads += 1
                    if self.ref_reads == 2:
                        self.calls.append((endpoint, method, paginate))
                        return hygiene.Result(True, {"object": {"sha": "b" * 40}})
                return super().request(endpoint, method, paginate)
        api = RaceGitHub()
        record = hygiene.evaluate_candidate(api, REPO, 42, [], True)
        self.assertEqual("skipped", record["action"])
        self.assertNotIn((DELETE_ENDPOINT, "DELETE", False), api.calls)

    def test_positive_path_deletes_exact_ref_only_after_all_checks(self):
        api, record = self.run_candidate()
        self.assertEqual("deleted", record["action"])
        self.assertIn((DELETE_ENDPOINT, "DELETE", False), api.calls)
        self.assertEqual(2, sum(call[0] == REF_ENDPOINT and call[1] == "GET" for call in api.calls))

    def test_audit_mode_never_deletes(self):
        api, record = self.run_candidate(enforce=False)
        self.assertEqual("candidate", record["action"])
        self.assertNotIn((DELETE_ENDPOINT, "DELETE", False), api.calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
