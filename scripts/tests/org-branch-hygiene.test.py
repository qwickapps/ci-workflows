#!/usr/bin/env python3
"""Regression tests for the closed-unmerged-PR branch cleanup safety predicate."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_missing_null_or_nonboolean_merged_metadata_fails_closed(self):
        for value in ("missing", None, "false", 0):
            with self.subTest(value=value):
                responses = baseline()
                if value == "missing":
                    del responses[PR_ENDPOINT]["merged"]
                else:
                    responses[PR_ENDPOINT]["merged"] = value
                self.assert_never_deleted(responses)

    def test_pr_lookup_error_fails_closed(self):
        responses = baseline()
        responses[PR_ENDPOINT] = hygiene.Result(False, error="HTTP 500")
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

    def test_default_branch_lookup_error_or_malformed_metadata_fails_closed(self):
        for value in (
            hygiene.Result(False, error="HTTP 500"),
            {},
            {"default_branch": None},
            {"default_branch": True},
            {"default_branch": 1},
            {"default_branch": ["main"]},
            {"default_branch": {"name": "main"}},
        ):
            with self.subTest(value=value):
                responses = baseline()
                responses[f"repos/{REPO}"] = value
                self.assert_never_deleted(responses)

    def test_initial_ref_lookup_error_or_malformed_metadata_fails_closed(self):
        for value in (hygiene.Result(False, error="HTTP 500"), {}, {"object": {"sha": None}}):
            with self.subTest(value=value):
                responses = baseline()
                responses[REF_ENDPOINT] = value
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

    def test_open_pr_lookup_error_or_incomplete_metadata_fails_closed(self):
        incomplete_heads = [
            {"head": {"ref": BRANCH}},
            {"head": {"ref": BRANCH, "repo": {}}},
            {"head": {"ref": "", "repo": {"full_name": REPO}}},
            {"head": None},
            None,
        ]
        for value in [hygiene.Result(False, error="HTTP 500"), *incomplete_heads]:
            with self.subTest(value=value):
                responses = baseline()
                responses[OPEN_ENDPOINT] = value if isinstance(value, hygiene.Result) else [value]
                self.assert_never_deleted(responses)

    def test_non_list_open_pr_response_fails_closed(self):
        responses = baseline()
        responses[OPEN_ENDPOINT] = {"head": {"ref": BRANCH, "repo": {"full_name": REPO}}}
        self.assert_never_deleted(responses)

    def test_allowlist_is_never_deleted(self):
        self.assert_never_deleted(allow=[{"repository": REPO, "branch": "feature/*"}])

    def test_malformed_allowlist_entries_disable_deletion_before_api_lookup(self):
        for entries in (None, [{"repository": REPO}], [{"repository": "", "branch": "*"}], [{"repository": REPO, "branch": None}]):
            with self.subTest(entries=entries):
                api = FakeGitHub(baseline())
                record = hygiene.evaluate_candidate(api, REPO, 42, entries, True)
                self.assertEqual("skipped", record["action"])
                self.assertEqual([], api.calls)

    def test_allowlist_file_requires_version_and_complete_patterns(self):
        malformed = [
            {},
            {"version": 2, "allow": []},
            {"version": True, "allow": []},
            {"version": 1.0, "allow": []},
            {"version": 1},
            {"version": 1, "allow": [{"repository": REPO}]},
        ]
        for document in malformed:
            with self.subTest(document=document), tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "allowlist.json"
                path.write_text(__import__("json").dumps(document))
                entries, error = hygiene.load_allowlist(path)
                self.assertEqual([], entries)
                self.assertTrue(error)

    def test_malformed_allowlist_file_cli_path_makes_zero_api_calls(self):
        malformed = [
            {},
            {"version": True, "allow": []},
            {"version": 1.0, "allow": []},
            {"version": 1},
            {"version": 1, "allow": [{"repository": REPO}]},
        ]
        for document in malformed:
            with self.subTest(document=document), tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "allowlist.json"
                output = pathlib.Path(directory) / "report.json"
                path.write_text(__import__("json").dumps(document))

                class RecordingGitHub(FakeGitHub):
                    instances = []
                    def __init__(self):
                        super().__init__(baseline())
                        self.__class__.instances.append(self)

                argv = [
                    "org-branch-hygiene.py", "--repo", REPO, "--pr-number", "42", "--enforce",
                    "--allowlist", str(path), "--output", str(output),
                ]
                with mock.patch.object(hygiene, "GitHub", RecordingGitHub), mock.patch.object(sys, "argv", argv):
                    hygiene.main()
                self.assertEqual(1, len(RecordingGitHub.instances))
                self.assertEqual([], RecordingGitHub.instances[0].calls)
                report = __import__("json").loads(output.read_text())
                self.assertEqual("skipped", report["records"][0]["action"])
                self.assertEqual(0, report["summary"]["deleted"])

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

    def test_final_ref_lookup_error_fails_closed(self):
        class FinalReadErrorGitHub(FakeGitHub):
            def __init__(self):
                super().__init__(baseline())
                self.ref_reads = 0
            def request(self, endpoint, method="GET", paginate=False):
                if endpoint == REF_ENDPOINT and method == "GET":
                    self.ref_reads += 1
                    if self.ref_reads == 2:
                        self.calls.append((endpoint, method, paginate))
                        return hygiene.Result(False, error="HTTP 500")
                return super().request(endpoint, method, paginate)
        api = FinalReadErrorGitHub()
        record = hygiene.evaluate_candidate(api, REPO, 42, [], True)
        self.assertEqual("skipped", record["action"])
        self.assertNotIn((DELETE_ENDPOINT, "DELETE", False), api.calls)

    def test_delete_api_failure_is_not_reported_as_deleted(self):
        responses = baseline()
        responses[(DELETE_ENDPOINT, "DELETE")] = hygiene.Result(False, error="HTTP 500")
        api, record = self.run_candidate(responses)
        self.assertEqual("skipped", record["action"])
        self.assertIn((DELETE_ENDPOINT, "DELETE", False), api.calls)

    def test_paginated_non_array_page_is_rejected(self):
        completed = subprocess.CompletedProcess(["gh"], 0, stdout='[{"number": 1}]\n{"number": 2}\n', stderr="")
        with mock.patch.object(hygiene.subprocess, "run", return_value=completed):
            result = hygiene.GitHub().request("repos/example/pulls", paginate=True)
        self.assertFalse(result.ok)
        self.assertIn("non-array page", result.error)

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
