#!/usr/bin/env python3
"""Regression tests for preserved-branch handoff report specificity."""
import copy
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "scripts/tests/fixtures/branch-handoff-report"
spec = importlib.util.spec_from_file_location("branch_handoff", ROOT / "scripts/validate-branch-handoff-report.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


class BranchHandoffReportTests(unittest.TestCase):
    def test_valid_fixture_passes_with_exact_coverage(self):
        self.assertEqual([], checker.validate(fixture("valid.json")))

    def test_generic_owner_phrases_are_rejected(self):
        for name, phrase in (
            ("pending-owner-decision.json", "pending owner decision"),
            ("repo-maintainer-triage.json", "repo maintainer must triage"),
            ("create-pr-if-useful.json", "create pr if useful"),
        ):
            with self.subTest(name=name):
                errors = checker.validate(fixture(name))
                self.assertTrue(any(phrase in error for error in errors), errors)

    def test_missing_accountable_task_or_agent_is_rejected(self):
        report = fixture("valid.json")
        report["repositories"][0]["branches"][0]["next_action"] = (
            "Verify PR #90 for branch anika/example at SHA " + "a" * 40 + " and decide whether to reopen it."
        )
        errors = checker.validate(report)
        self.assertTrue(any("must name task" in error for error in errors), errors)

    def test_action_must_be_branch_specific_and_decisional(self):
        report = fixture("valid.json")
        report["repositories"][0]["branches"][0]["next_action"] = (
            "Task t_ab12cd34 must verify PR #90 and decide whether to reopen it."
        )
        errors = checker.validate(report)
        self.assertTrue(any("must name task" in error for error in errors), errors)

    def test_fresh_lane_totals_and_coverage_are_exact(self):
        report = fixture("valid.json")
        report["coverage"] = {"qwickapps/example": 2}
        report["total_non_default_branches"] = 2
        errors = checker.validate(report)
        self.assertTrue(any("coverage does not match" in error for error in errors), errors)
        self.assertTrue(any("total_non_default_branches" in error for error in errors), errors)

    def test_sha_is_required_for_branch_specific_unique_commit_check(self):
        report = fixture("valid.json")
        branch = report["repositories"][0]["branches"][0]
        branch["observed_sha"] = "not-a-sha"
        branch["next_action"] = "Task t_ab12cd34 must preserve unique commits from branch anika/example."
        errors = checker.validate(report)
        self.assertTrue(any("observed_sha" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main(verbosity=2)
