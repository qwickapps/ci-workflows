#!/usr/bin/env python3
"""Regression tests for fresh, exact preserved-branch handoff reports."""
import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "scripts/tests/fixtures/branch-handoff-report"
spec = importlib.util.spec_from_file_location("branch_handoff", ROOT / "scripts/validate-branch-handoff-report.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
NOW = datetime(2026, 10, 4, 3, 30, tzinfo=timezone.utc)


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


def valid_pair():
    return fixture("valid.json"), fixture("valid-inventory.json")


class BranchHandoffReportTests(unittest.TestCase):
    def validate(self, report, inventory):
        return checker.validate(report, inventory, now=NOW)

    def assert_error(self, report, inventory, text):
        errors = self.validate(report, inventory)
        self.assertTrue(any(text in error for error in errors), errors)

    def test_fresh_inventory_report_fixture_passes_with_exact_coverage(self):
        report, inventory = valid_pair()
        self.assertEqual([], self.validate(report, inventory))

    def test_zero_branch_repository_is_explicit_and_valid(self):
        report, inventory = valid_pair()
        report["repositories"][0]["branches"] = []
        report["coverage"] = {"qwickapps/example": 0}
        report["total_non_default_branches"] = 0
        inventory["repositories"][0]["branches"] = []
        self.assertEqual([], self.validate(report, inventory))

    def test_duplicate_branch_identity_is_rejected_but_coverage_is_unique(self):
        report, inventory = valid_pair()
        report["repositories"][0]["branches"].append(copy.deepcopy(report["repositories"][0]["branches"][0]))
        self.assert_error(report, inventory, "duplicate report branch identity")
        self.assertFalse(any("coverage does not match" in error for error in self.validate(report, inventory)))

    def test_generic_owner_phrases_are_rejected(self):
        for name, phrase in (
            ("pending-owner-decision.json", "pending owner decision"),
            ("repo-maintainer-triage.json", "repo maintainer must triage"),
            ("create-pr-if-useful.json", "create pr if useful"),
        ):
            with self.subTest(name=name):
                report, inventory = valid_pair()
                report = fixture(name)
                errors = self.validate(report, inventory)
                self.assertTrue(any(phrase in error for error in errors), errors)

    def test_missing_accountable_task_or_agent_is_rejected(self):
        report, inventory = valid_pair()
        report["repositories"][0]["branches"][0]["next_action"] = (
            "Verify PR #90 for branch anika/example at SHA " + "a" * 40 + " and decide whether to reopen it."
        )
        self.assert_error(report, inventory, "must name task")

    def test_branch_prefix_collision_is_not_an_exact_citation(self):
        report, inventory = valid_pair()
        report["repositories"][0]["branches"][0]["next_action"] = (
            "Task t_ab12cd34 must verify PR #90 for branch anika/example-other and decide whether to reopen it."
        )
        self.assert_error(report, inventory, "cite this exact branch")

    def test_exact_branch_and_exact_sha_citations_are_accepted(self):
        for action in (
            "Task t_ab12cd34 must verify PR #90 for branch anika/example and decide whether to reopen it.",
            "Agent @anika must check unique commits at SHA " + "a" * 40 + " and decide whether to preserve them.",
        ):
            with self.subTest(action=action):
                report, inventory = valid_pair()
                report["repositories"][0]["branches"][0]["next_action"] = action
                self.assertEqual([], self.validate(report, inventory))

    def test_branch_suffix_collisions_are_not_exact_citations(self):
        for suffix in ("+other", "@other", "=other", "é"):
            with self.subTest(suffix=suffix):
                report, inventory = valid_pair()
                report["repositories"][0]["branches"][0]["next_action"] = (
                    "Task t_ab12cd34 must verify PR #90 for branch anika/example"
                    + suffix
                    + " and decide whether to reopen it."
                )
                self.assert_error(report, inventory, "cite this exact branch")

    def test_unicode_whitespace_suffix_collisions_are_not_exact_citations(self):
        # Every non-ASCII whitespace code point is legal inside a Git ref, so
        # `anika/example<ws>other` names a different branch and must not match.
        unicode_spaces = [chr(c) for c in range(0x80, 0x110000) if chr(c).isspace()]
        for required in ("\u0085", "\u00a0", "\u1680", "\u2000", "\u2003", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000"):
            self.assertIn(required, unicode_spaces)
        for space in unicode_spaces:
            for template in (
                "Task t_ab12cd34 must verify PR #90 for branch anika/example{ws}other and decide whether to reopen it.",
                "Agent @anika must check unique commits at SHA " + "a" * 40 + "{ws}other and decide whether to preserve them.",
            ):
                with self.subTest(codepoint=f"U+{ord(space):04X}", template=template[:30]):
                    report, inventory = valid_pair()
                    report["repositories"][0]["branches"][0]["next_action"] = template.format(ws=space)
                    self.assert_error(report, inventory, "cite this exact branch")

    def test_exact_unicode_branch_citations_are_accepted(self):
        for name in ("anika/exampleé", "anika/ex\u00a0ample", "anika/ex\u2028ample"):
            with self.subTest(branch=name):
                report, inventory = valid_pair()
                report["repositories"][0]["branches"][0]["branch"] = name
                inventory["repositories"][0]["branches"][0]["branch"] = name
                report["repositories"][0]["branches"][0]["next_action"] = (
                    f"Task t_ab12cd34 must verify PR #90 for branch {name} and decide whether to reopen it."
                )
                self.assertEqual([], self.validate(report, inventory))

    def test_citation_token_ends_at_git_forbidden_ascii_delimiters(self):
        for delimiter in (" ", "\t", "\n", "\r", "\x0b", "\x0c", "\x7f"):
            with self.subTest(delimiter=repr(delimiter)):
                report, inventory = valid_pair()
                report["repositories"][0]["branches"][0]["next_action"] = (
                    "Task t_ab12cd34 must verify PR #90 for branch anika/example"
                    + delimiter
                    + "and decide whether to reopen it."
                )
                self.assertEqual([], self.validate(report, inventory))

    def test_malformed_and_stale_generated_at_are_rejected(self):
        report, inventory = valid_pair()
        report["generated_at"] = "not-a-timestamp"
        self.assert_error(report, inventory, "generated_at must be a valid")
        report, inventory = valid_pair()
        report["generated_at"] = (NOW - timedelta(seconds=checker.MAX_FRESHNESS_SECONDS + 1)).isoformat()
        self.assert_error(report, inventory, "generated_at exceeds")

    def test_generated_at_utc_conversion_range_edges_return_clean_errors(self):
        for value in ("0001-01-01T00:00:00+23:00", "9999-12-31T23:59:59-23:00"):
            with self.subTest(value=value):
                report, inventory = valid_pair()
                report["generated_at"] = value
                self.assert_error(report, inventory, "generated_at must be a valid ISO-8601 timestamp")

    def test_malformed_identity_values_return_errors_without_exception(self):
        for field, value, expected in (
            ("branch", None, "branch name must be non-empty"),
            ("observed_sha", None, "observed_sha must be a 40-character SHA"),
        ):
            with self.subTest(field=field):
                report, inventory = valid_pair()
                report["repositories"][0]["branches"][0][field] = value
                self.assert_error(report, inventory, expected)

    def test_inventory_omitted_branch_and_report_added_branch_are_rejected(self):
        report, inventory = valid_pair()
        inventory["repositories"][0]["branches"] = []
        self.assert_error(report, inventory, "branch identities do not exactly match")
        report, inventory = valid_pair()
        added = copy.deepcopy(report["repositories"][0]["branches"][0])
        added.update({
            "branch": "anika/new-example",
            "observed_sha": "b" * 40,
            "next_action": "Task t_ab12cd34 must verify PR #91 for branch anika/new-example at SHA " + "b" * 40 + " and decide whether to reopen it.",
        })
        report["repositories"][0]["branches"].append(added)
        report["coverage"] = {"qwickapps/example": 2}
        report["total_non_default_branches"] = 2
        self.assert_error(report, inventory, "branch identities do not exactly match")

    def test_stale_sha_and_default_branch_inclusion_are_rejected(self):
        report, inventory = valid_pair()
        report["repositories"][0]["branches"][0]["observed_sha"] = "b" * 40
        report["repositories"][0]["branches"][0]["next_action"] = (
            "Task t_ab12cd34 must verify PR #90 for branch anika/example at SHA " + "b" * 40 + " and decide whether to reopen it."
        )
        self.assert_error(report, inventory, "observed_sha does not match inventory")
        report, inventory = valid_pair()
        report_branch = report["repositories"][0]["branches"][0]
        report_branch.update({
            "branch": "main",
            "next_action": "Task t_ab12cd34 must verify PR #90 for branch main at SHA " + "a" * 40 + " and decide whether to reopen it.",
        })
        self.assert_error(report, inventory, "report must exclude default branch")

    def test_inventory_malformed_and_stale_timestamp_are_rejected(self):
        report, inventory = valid_pair()
        inventory["observed_at"] = None
        self.assert_error(report, inventory, "inventory observed_at must be a non-empty")
        report, inventory = valid_pair()
        inventory["observed_at"] = (NOW - timedelta(seconds=checker.MAX_FRESHNESS_SECONDS + 1)).isoformat()
        self.assert_error(report, inventory, "inventory observed_at exceeds")

    def test_inventory_timestamp_utc_conversion_range_edges_return_clean_errors(self):
        for value in ("0001-01-01T00:00:00+23:00", "9999-12-31T23:59:59-23:00"):
            with self.subTest(value=value):
                report, inventory = valid_pair()
                inventory["observed_at"] = value
                self.assert_error(report, inventory, "inventory observed_at must be a valid ISO-8601 timestamp")

    def test_valid_cli_path_uses_a_fresh_pair(self):
        current = datetime.now(timezone.utc).isoformat()
        report, inventory = valid_pair()
        report["generated_at"] = current
        inventory["observed_at"] = current
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            report_path = directory / "report.json"
            inventory_path = directory / "inventory.json"
            report_path.write_text(json.dumps(report))
            inventory_path.write_text(json.dumps(inventory))
            completed = subprocess.run(
                [sys.executable, str(ROOT / "scripts/validate-branch-handoff-report.py"), str(report_path), str(inventory_path)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("[branch-handoff] PASS", completed.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
