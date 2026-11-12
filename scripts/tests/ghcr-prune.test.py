#!/usr/bin/env python3
"""Regression tests for scripts/ghcr-prune.py's deletion safety predicates.

These are pure unit tests: no network, no SSH, no real `gh`/registry calls.
GitHub, Registry, and the SSH runner are all injected fakes.
"""
import importlib.util
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ghcr_prune", ROOT / "scripts/ghcr-prune.py")
ghcr_prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ghcr_prune)

ORG = "qwickapps"
PKG = "img-example"


def version(id_, digest, created_at, tags=None):
    return {
        "id": id_,
        "name": digest,
        "created_at": created_at,
        "metadata": {"container": {"tags": tags or []}},
    }


class FakeRegistry:
    """children_by_digest: {digest: [child_digest, ...]} for indexes;
    absent digest -> no children (plain manifest). failing_digests: set of
    digests whose manifest fetch should fail (fail-closed test)."""

    def __init__(self, children_by_digest=None, failing_digests=None):
        self.children_by_digest = children_by_digest or {}
        self.failing_digests = failing_digests or set()
        self.calls = []

    def children(self, owner, package, digest):
        self.calls.append((owner, package, digest))
        if digest in self.failing_digests:
            return ghcr_prune.Result(False, error="simulated manifest fetch failure")
        return ghcr_prune.Result(True, self.children_by_digest.get(digest, []))


def make_versions(n, start_id=100, tag_prefix="v"):
    """n versions, newest first by id/time, ids descending-friendly."""
    versions = []
    for i in range(n):
        day = 30 - i
        versions.append(version(start_id + i, f"sha256:{'a' * 63}{i:x}", f"2026-01-{day:02d}T00:00:00Z", [f"{tag_prefix}{n - i}"]))
    return versions


class KeepNewestNTests(unittest.TestCase):
    def test_keeps_exactly_the_newest_five_by_default(self):
        versions = make_versions(8)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        kept_ids = {d.version["id"] for d in plan.decisions if d.action == "keep"}
        deleted_ids = {d.version["id"] for d in plan.decisions if d.action == "delete"}
        self.assertEqual(kept_ids, {v["id"] for v in versions[:5]})
        self.assertEqual(deleted_ids, {v["id"] for v in versions[5:]})

    def test_fewer_than_keep_n_versions_all_kept(self):
        versions = make_versions(3)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        self.assertTrue(all(d.action == "keep" for d in plan.decisions))

    def test_rank_is_by_created_at_not_list_order(self):
        versions = make_versions(6)
        shuffled = [versions[3], versions[0], versions[5], versions[1], versions[4], versions[2]]
        plan = ghcr_prune.plan_package(ORG, PKG, shuffled, live_digests=set(), registry=FakeRegistry())
        kept_ids = {d.version["id"] for d in plan.decisions if d.action == "keep"}
        self.assertEqual(kept_ids, {v["id"] for v in versions[:5]})


class LiveReferenceProtectionTests(unittest.TestCase):
    def test_old_version_with_live_digest_is_kept(self):
        versions = make_versions(8)
        old_live_digest = versions[7]["name"]
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests={old_live_digest}, registry=FakeRegistry())
        decision = next(d for d in plan.decisions if d.version["id"] == versions[7]["id"])
        self.assertEqual(decision.action, "keep")
        self.assertIn("live reference", decision.reason)

    def test_live_digest_not_matching_any_version_changes_nothing(self):
        versions = make_versions(8)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests={"sha256:" + "f" * 64}, registry=FakeRegistry())
        deleted_ids = {d.version["id"] for d in plan.decisions if d.action == "delete"}
        self.assertEqual(deleted_ids, {v["id"] for v in versions[5:]})


class ChannelTagProtectionTests(unittest.TestCase):
    def test_old_version_tagged_stable_is_kept(self):
        versions = make_versions(8)
        versions[7]["metadata"]["container"]["tags"] = ["sha-deadbeef", "stable"]
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        decision = next(d for d in plan.decisions if d.version["id"] == versions[7]["id"])
        self.assertEqual(decision.action, "keep")
        self.assertIn("channel tag", decision.reason)

    def test_channel_tags_are_case_insensitive(self):
        versions = make_versions(8)
        versions[7]["metadata"]["container"]["tags"] = ["LIVE"]
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        decision = next(d for d in plan.decisions if d.version["id"] == versions[7]["id"])
        self.assertEqual(decision.action, "keep")

    def test_non_channel_tag_does_not_protect(self):
        versions = make_versions(8)
        versions[7]["metadata"]["container"]["tags"] = ["sha-deadbeef", "staging"]
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        decision = next(d for d in plan.decisions if d.version["id"] == versions[7]["id"])
        self.assertEqual(decision.action, "delete")

    def test_all_six_channel_tags_protect(self):
        for tag in sorted(ghcr_prune.CHANNEL_TAGS):
            with self.subTest(tag=tag):
                versions = make_versions(8)
                versions[7]["metadata"]["container"]["tags"] = [tag]
                plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
                decision = next(d for d in plan.decisions if d.version["id"] == versions[7]["id"])
                self.assertEqual(decision.action, "keep")


class ChildManifestProtectionTests(unittest.TestCase):
    def test_child_of_kept_index_is_protected_even_though_untagged_and_old(self):
        versions = make_versions(5)  # all 5 are kept by rank
        child_digest = "sha256:" + "c" * 64
        child_version = version(999, child_digest, "2020-01-01T00:00:00Z", tags=[])
        all_versions = versions + [child_version]
        registry = FakeRegistry(children_by_digest={versions[0]["name"]: [child_digest]})
        plan = ghcr_prune.plan_package(ORG, PKG, all_versions, live_digests=set(), registry=registry)
        decision = next(d for d in plan.decisions if d.version["id"] == 999)
        self.assertEqual(decision.action, "keep")
        self.assertIn("child manifest", decision.reason)

    def test_untagged_old_version_that_is_nobodys_child_is_deleted(self):
        versions = make_versions(6)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        decision = next(d for d in plan.decisions if d.version["id"] == versions[5]["id"])
        self.assertEqual(decision.action, "delete")

    def test_manifest_fetch_failure_on_a_kept_index_skips_the_whole_package(self):
        versions = make_versions(8)
        failing_digest = versions[0]["name"]
        registry = FakeRegistry(failing_digests={failing_digest})
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=registry)
        self.assertTrue(plan.skipped)
        self.assertEqual(plan.decisions, [ghcr_prune.VersionDecision(v, "keep", "newest") for v in sorted(versions, key=ghcr_prune._created_at, reverse=True)])
        # Fail-closed must never reach a delete decision for this package.
        self.assertFalse(any(d.action == "delete" for d in plan.decisions))

    def test_manifest_is_only_fetched_for_kept_by_rank_versions(self):
        versions = make_versions(8)
        registry = FakeRegistry()
        ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=registry)
        queried_digests = {call[2] for call in registry.calls}
        self.assertEqual(queried_digests, {v["name"] for v in versions[:5]})


class RateLimitGateTests(unittest.TestCase):
    class FakeApi:
        def __init__(self, remaining):
            self.remaining = remaining

        def request(self, endpoint, method="GET", paginate=False):
            assert endpoint == "/rate_limit"
            return ghcr_prune.Result(True, {"resources": {"core": {"remaining": self.remaining, "reset": 123}}})

    def test_sufficient_remaining_passes(self):
        result = ghcr_prune.check_rate_limit(self.FakeApi(500), min_remaining=200)
        self.assertTrue(result.ok)

    def test_insufficient_remaining_aborts(self):
        result = ghcr_prune.check_rate_limit(self.FakeApi(50), min_remaining=200)
        self.assertFalse(result.ok)
        self.assertIn("remaining=50", result.error)

    def test_malformed_response_fails_closed(self):
        class BrokenApi:
            def request(self, endpoint, method="GET", paginate=False):
                return ghcr_prune.Result(True, {"resources": {}})

        result = ghcr_prune.check_rate_limit(BrokenApi(), min_remaining=200)
        self.assertFalse(result.ok)

    def test_api_error_fails_closed(self):
        class ErrorApi:
            def request(self, endpoint, method="GET", paginate=False):
                return ghcr_prune.Result(False, error="network error")

        result = ghcr_prune.check_rate_limit(ErrorApi(), min_remaining=200)
        self.assertFalse(result.ok)


class RestoreLogTests(unittest.TestCase):
    def test_report_includes_a_working_restore_command_for_every_deletion(self):
        versions = make_versions(8)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        records, summary = ghcr_prune.build_report(ORG, {PKG: plan}, keep_n=5)
        delete_records = [r for r in records if r["action"] == "delete"]
        self.assertEqual(len(delete_records), 3)
        for record in delete_records:
            self.assertEqual(
                record["restore_command"],
                f"gh api -X POST orgs/{ORG}/packages/container/{PKG}/versions/{record['version_id']}/restore",
            )

    def test_keep_records_have_no_restore_command(self):
        versions = make_versions(3)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        records, _ = ghcr_prune.build_report(ORG, {PKG: plan}, keep_n=5)
        self.assertTrue(all(r["restore_command"] is None for r in records))

    def test_summary_counts_match_records(self):
        versions = make_versions(8)
        plan = ghcr_prune.plan_package(ORG, PKG, versions, live_digests=set(), registry=FakeRegistry())
        records, summary = ghcr_prune.build_report(ORG, {PKG: plan}, keep_n=5)
        self.assertEqual(summary["keep"], sum(1 for r in records if r["action"] == "keep"))
        self.assertEqual(summary["delete"], sum(1 for r in records if r["action"] == "delete"))

    def test_skipped_package_reported_and_excluded_from_delete_summary(self):
        plan = ghcr_prune.PackagePlan(skipped="simulated failure")
        records, summary = ghcr_prune.build_report(ORG, {PKG: plan}, keep_n=5)
        self.assertEqual(records, [{"package": PKG, "action": "package_skipped", "reason": "simulated failure"}])
        self.assertEqual(summary["delete"], 0)
        self.assertEqual(summary["package_skipped"], 1)


class LiveRefInventoryTests(unittest.TestCase):
    """Exercises the SSH-sourced inventory parsing with a fake runner --
    no real network/SSH, but the same shapes real `docker` output has."""

    class FakeCompleted:
        def __init__(self, stdout, returncode=0, stderr=""):
            self.stdout = stdout
            self.returncode = returncode
            self.stderr = stderr

    def test_digest_pinned_ref_is_captured_without_any_inspect_call(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": False}
        digest = "sha256:" + "d" * 64
        ref = f"ghcr.io/qwickapps/img-x@{digest}"

        def runner(target, cmd):
            if "image inspect" in cmd:
                return self.FakeCompleted("[]\n")
            return self.FakeCompleted(ref + "\n")

        live_digests, per_host_refs, errors = ghcr_prune.collect_live_digests([host], "qwickapps", runner)
        self.assertEqual(errors, [])
        self.assertIn(digest, live_digests)
        self.assertEqual(per_host_refs["h1"], [ref])

    def test_tag_ref_resolved_via_repo_digests(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": False}
        ref = "ghcr.io/qwickapps/img-x:1.2.3"
        digest = "sha256:" + "e" * 64

        def runner(target, cmd):
            if "image inspect" in cmd:
                return self.FakeCompleted(f'["ghcr.io/qwickapps/img-x@{digest}"]\n')
            return self.FakeCompleted(ref + "\n")

        live_digests, _, errors = ghcr_prune.collect_live_digests([host], "qwickapps", runner)
        self.assertEqual(errors, [])
        self.assertIn(digest, live_digests)

    def test_non_org_images_are_ignored(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": False}

        def runner(target, cmd):
            return self.FakeCompleted("postgres:16\nghcr.io/otherorg/img-x:latest\n")

        live_digests, per_host_refs, errors = ghcr_prune.collect_live_digests([host], "qwickapps", runner)
        self.assertEqual(errors, [])
        self.assertEqual(per_host_refs["h1"], [])
        self.assertEqual(live_digests, set())

    def test_swarm_host_also_queries_service_ls(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": True}
        seen_cmds = []

        def runner(target, cmd):
            seen_cmds.append(cmd)
            return self.FakeCompleted("")

        ghcr_prune.collect_live_digests([host], "qwickapps", runner)
        self.assertTrue(any("service ls" in c for c in seen_cmds))
        self.assertTrue(any("ps -a" in c for c in seen_cmds))

    def test_unreachable_host_is_reported_as_an_error_not_silently_skipped(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": False}

        def runner(target, cmd):
            return self.FakeCompleted("", returncode=255, stderr="Permission denied (publickey).")

        live_digests, per_host_refs, errors = ghcr_prune.collect_live_digests([host], "qwickapps", runner)
        self.assertEqual(len(errors), 1)
        self.assertIn("h1", errors[0])

    def test_main_aborts_when_live_ref_inventory_is_incomplete(self):
        # Regression guard: main() must not proceed to plan/delete anything
        # if even one host's live-ref inventory could not be collected --
        # an incomplete live-ref set is the exact failure mode that let the
        # 2026-10-07 unsafe prune delete live images.
        source = (ROOT / "scripts/ghcr-prune.py").read_text()
        self.assertIn("if host_errors:", source)
        self.assertIn("ABORT: live-ref inventory incomplete", source)


class RepoDigestBatchMisalignmentTests(unittest.TestCase):
    class FakeCompleted:
        def __init__(self, stdout, returncode=0, stderr=""):
            self.stdout = stdout
            self.returncode = returncode
            self.stderr = stderr

    def test_falls_back_to_per_ref_inspect_when_batch_output_is_misaligned(self):
        host = {"name": "h1", "ssh_target": "h1", "docker": "docker", "swarm": False}
        refs = ["ghcr.io/qwickapps/img-a:1", "ghcr.io/qwickapps/img-b:1"]
        digest_a = "sha256:" + "1" * 64

        calls = {"batch": 0}

        def runner(target, cmd):
            if refs[0] in cmd and refs[1] in cmd:
                calls["batch"] += 1
                return self.FakeCompleted("only-one-line\n")  # misaligned: 2 refs, 1 line
            if refs[0] in cmd:
                return self.FakeCompleted(f'["ghcr.io/qwickapps/img-a@{digest_a}"]\n')
            return self.FakeCompleted("[]\n")

        result = ghcr_prune.resolve_repo_digests(host, refs, runner)
        self.assertTrue(result.ok)
        self.assertEqual(result.value[refs[0]], [digest_a])
        self.assertEqual(result.value[refs[1]], [])
        self.assertEqual(calls["batch"], 1)


class ScriptSelfChecksTests(unittest.TestCase):
    """Guards against silently losing a safety property in a future edit."""

    def test_default_hosts_cover_the_five_required_fleet_hosts(self):
        names = {h["name"] for h in ghcr_prune.DEFAULT_HOSTS}
        self.assertEqual(names, {"oci-main", "oci-gateway", "oci-dev", "qwickapps-momo", "macmini-devserver"})

    def test_channel_tags_match_the_runbook_set(self):
        self.assertEqual(ghcr_prune.CHANNEL_TAGS, {"stable", "live", "release", "latest", "uat", "prod"})

    def test_default_keep_is_five(self):
        self.assertEqual(ghcr_prune.DEFAULT_KEEP, 5)

    def test_compiles_cleanly(self):
        completed = subprocess.run([sys.executable, "-m", "py_compile", str(ROOT / "scripts/ghcr-prune.py")], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
