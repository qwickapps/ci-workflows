#!/usr/bin/env python3
"""Scheduled, live-ref-aware GHCR prune for the qwickapps org.

Dry-run by default. Keeps the newest N (default 5) versions per container
package, but a version's rank alone never deletes it -- three independent
protections win over rank:

  1. Live reference: its digest is pulled by a container or swarm service
     spec (including 0/0 replica specs) on any fleet host.
  2. Channel tag: it carries any of stable/live/release/latest/uat/prod.
  3. Child manifest: it is a platform-specific child of an index/manifest
     list that IS one of the newest N (fetched from the registry, not
     guessed from rank).

Why: 2026-10-07 an org-wide prune kept-newest-5-per-package blind to (1)
live refs and (3) child manifests, deleted live images and orphaned 104
platform manifests of indexes it otherwise kept, and had to be restored
from GitHub's 30-day undelete window. This script's job is to produce a
dry-run report that is safe to hand-review BEFORE anything is deleted --
see --enforce below.

Usage:
  # Dry run (default) -- writes a JSONL report, deletes nothing.
  python3 scripts/ghcr-prune.py --org qwickapps --output /tmp/ghcr-prune.jsonl

  # Real run -- only after a human has reviewed the dry-run report.
  python3 scripts/ghcr-prune.py --org qwickapps --enforce --output /tmp/ghcr-prune.jsonl

Every deleted version is logged with the exact `gh api` command to restore
it (GitHub keeps deleted package versions restorable for 30 days).
"""
import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import quote

CHANNEL_TAGS = {"stable", "live", "release", "latest", "uat", "prod"}
DEFAULT_KEEP = 5
DEFAULT_MIN_RATE_LIMIT = 200  # classic token pool is 5000/h and shared fleet-wide

# Inventory of hosts that may be running qwickapps GHCR images. "docker" is
# the command prefix (some hosts need passwordless sudo for docker socket
# access); "swarm" means also inventory `docker service ls` (which lists
# 0/0 replica specs too -- no extra flag needed).
DEFAULT_HOSTS = [
    {"name": "oci-main", "ssh_target": "ubuntu@oci-main", "docker": "docker", "swarm": True},
    {"name": "oci-gateway", "ssh_target": "ubuntu@oci-gateway", "docker": "docker", "swarm": True},
    {"name": "oci-dev", "ssh_target": "ubuntu@oci-dev", "docker": "docker", "swarm": True},
    {"name": "qwickapps-momo", "ssh_target": "qwickapps-momo", "docker": "sudo -n docker", "swarm": False},
    {"name": "macmini-devserver", "ssh_target": "macmini-devserver", "docker": "docker", "swarm": False},
]

DIGEST_RE = re.compile(r"@(sha256:[0-9a-f]{64})")


@dataclass
class Result:
    ok: bool
    value: object = None
    error: str = ""


class GitHub:
    """Thin wrapper over `gh api`. Never prints a token; `gh` resolves auth
    from the environment's logged-in session."""

    def request(self, endpoint, method="GET", paginate=False):
        args = ["gh", "api", endpoint]
        if method != "GET":
            args.extend(["-X", method])
        if paginate:
            args.append("--paginate")
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode:
            return Result(False, error=completed.stderr.strip())
        text = completed.stdout.strip()
        if not text:
            return Result(True, None)
        try:
            if paginate:
                decoder, offset, values = json.JSONDecoder(), 0, []
                while offset < len(text):
                    stripped = text[offset:].lstrip()
                    if not stripped:
                        break
                    offset += len(text[offset:]) - len(stripped)
                    item, consumed = decoder.raw_decode(stripped)
                    offset += consumed
                    if not isinstance(item, list):
                        return Result(False, error="paginated GitHub API response contains a non-array page")
                    values.extend(item)
                return Result(True, values)
            return Result(True, json.loads(text))
        except json.JSONDecodeError as exc:
            return Result(False, error=f"invalid GitHub API JSON: {exc}")


class Registry:
    """GHCR v2 registry reads (manifest fetch). These do NOT count against
    the classic token's REST rate limit -- only `gh api` calls do."""

    ACCEPT = (
        "application/vnd.oci.image.index.v1+json,"
        "application/vnd.oci.image.manifest.v1+json,"
        "application/vnd.docker.distribution.manifest.list.v2+json,"
        "application/vnd.docker.distribution.manifest.v2+json"
    )

    def __init__(self, actor, token, timeout=10):
        self.actor = actor
        self.token = token
        self.timeout = timeout
        self._bearer_cache = {}

    def _bearer(self, owner, package):
        key = (owner, package)
        if key in self._bearer_cache:
            return self._bearer_cache[key]
        scope = f"repository:{owner}/{package}:pull"
        try:
            completed = subprocess.run(
                [
                    "curl", "-sS", "--max-time", str(self.timeout),
                    "-u", f"{self.actor}:{self.token}",
                    f"https://ghcr.io/token?service=ghcr.io&scope={scope}",
                ],
                capture_output=True, text=True,
            )
        except OSError as exc:
            return Result(False, error=f"token endpoint unreachable: {exc}")
        if completed.returncode:
            return Result(False, error="token endpoint request failed")
        try:
            bearer = json.loads(completed.stdout).get("token") or ""
        except json.JSONDecodeError:
            return Result(False, error="token endpoint returned invalid JSON")
        if not bearer:
            return Result(False, error="token endpoint returned no bearer token")
        self._bearer_cache[key] = Result(True, bearer)
        return self._bearer_cache[key]

    def manifest(self, owner, package, digest):
        """Fetch the manifest for <owner>/<package>@<digest>. Returns
        Result(ok=False) on ANY failure (auth, network, non-200, bad JSON)
        -- callers must treat that as fail-closed, never as "no children"."""
        bearer_result = self._bearer(owner, package)
        if not bearer_result.ok:
            return bearer_result
        try:
            completed = subprocess.run(
                [
                    "curl", "-sS", "--max-time", str(self.timeout),
                    "-w", "\n%{http_code}",
                    "-H", f"Authorization: Bearer {bearer_result.value}",
                    "-H", f"Accept: {self.ACCEPT}",
                    f"https://ghcr.io/v2/{owner}/{package}/manifests/{digest}",
                ],
                capture_output=True, text=True,
            )
        except OSError as exc:
            return Result(False, error=f"manifest request unreachable: {exc}")
        if completed.returncode:
            return Result(False, error="manifest request failed")
        body, _, status = completed.stdout.rpartition("\n")
        if status != "200":
            return Result(False, error=f"manifest HTTP {status}")
        try:
            return Result(True, json.loads(body))
        except json.JSONDecodeError:
            return Result(False, error="manifest response was not valid JSON")

    def children(self, owner, package, digest):
        """Result(ok, value=list-of-digest-strings). Empty list, not an
        error, when the manifest simply has no children (a plain, single-
        platform manifest)."""
        result = self.manifest(owner, package, digest)
        if not result.ok:
            return result
        manifests = (result.value or {}).get("manifests") or []
        digests = [m.get("digest") for m in manifests if isinstance(m, dict) and m.get("digest")]
        return Result(True, digests)


def run_ssh(ssh_target, remote_cmd, timeout=30):
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}", ssh_target, remote_cmd],
        capture_output=True, text=True, timeout=timeout + 10,
    )


def collect_host_image_refs(host, runner=run_ssh):
    """Returns Result(ok, value=list-of-raw-image-ref-strings) for every
    container (including stopped, via `ps -a`) and every swarm service
    (including 0/0 replica specs) on one host."""
    docker = host["docker"]
    parts = [f"{docker} ps -a --format '{{{{.Image}}}}'"]
    if host.get("swarm"):
        parts.append(f"{docker} service ls --format '{{{{.Image}}}}'")
    remote_cmd = " ; ".join(parts)
    completed = runner(host["ssh_target"], remote_cmd)
    if completed.returncode != 0 and not completed.stdout.strip():
        return Result(False, error=f"{host['name']}: ssh/docker inventory failed: {completed.stderr.strip()}")
    refs = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    return Result(True, sorted(set(refs)))


def resolve_repo_digests(host, image_refs, runner=run_ssh):
    """Returns Result(ok, value={ref: [digest, ...]}) using the LOCAL
    docker daemon's own RepoDigests -- this reflects exactly what that
    host actually pulled, with no separate registry auth needed."""
    if not image_refs:
        return Result(True, {})
    docker = host["docker"]
    quoted_refs = " ".join(shlex.quote(ref) for ref in image_refs)
    remote_cmd = f"{docker} image inspect {quoted_refs} --format '{{{{json .RepoDigests}}}}' 2>/dev/null"
    completed = runner(host["ssh_target"], remote_cmd)
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    resolved = {}
    if len(lines) == len(image_refs):
        for ref, line in zip(image_refs, lines):
            try:
                repo_digests = json.loads(line) or []
            except json.JSONDecodeError:
                repo_digests = []
            resolved[ref] = [d.rsplit("@", 1)[-1] for d in repo_digests if "@" in d]
    else:
        # Batch output didn't line up 1:1 with input (e.g. a missing local
        # image shifted the count) -- fall back to one inspect per ref
        # rather than guess at alignment.
        for ref in image_refs:
            single = runner(host["ssh_target"], f"{docker} image inspect {shlex.quote(ref)} --format '{{{{json .RepoDigests}}}}' 2>/dev/null")
            try:
                repo_digests = json.loads(single.stdout.strip() or "[]") or []
            except json.JSONDecodeError:
                repo_digests = []
            resolved[ref] = [d.rsplit("@", 1)[-1] for d in repo_digests if "@" in d]
    return Result(True, resolved)


def collect_live_digests(hosts, org, runner=run_ssh):
    """Returns (live_digests: set[str], per_host_refs: dict, errors: list[str]).

    live_digests includes both digest-pinned refs (parsed directly) and
    tag refs resolved via the host's own RepoDigests. errors is non-empty
    when a host's inventory could not be collected at all -- callers
    should treat that as a reason to abort rather than silently proceed
    with incomplete live-ref coverage.
    """
    live_digests = set()
    per_host_refs = {}
    errors = []
    prefix = f"ghcr.io/{org}/"
    for host in hosts:
        refs_result = collect_host_image_refs(host, runner)
        if not refs_result.ok:
            errors.append(refs_result.error)
            continue
        org_refs = [r for r in refs_result.value if r.startswith(prefix)]
        per_host_refs[host["name"]] = org_refs
        for ref in org_refs:
            match = DIGEST_RE.search(ref)
            if match:
                live_digests.add(match.group(1))
        digests_result = resolve_repo_digests(host, org_refs, runner)
        if digests_result.ok:
            for digests in digests_result.value.values():
                live_digests.update(digests)
    return live_digests, per_host_refs, errors


@dataclass
class VersionDecision:
    version: dict
    action: str  # "keep" or "delete"
    reason: str


@dataclass
class PackagePlan:
    decisions: list = field(default_factory=list)
    skipped: str = ""  # non-empty -> whole package skipped this run (fail-safe)


def _tags_of(version):
    return (((version.get("metadata") or {}).get("container") or {}).get("tags") or [])


def _created_at(version):
    try:
        return datetime.fromisoformat(version["created_at"].replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return datetime.min.replace(tzinfo=timezone.utc)


def plan_package(org, package, versions, live_digests, registry, keep_n=DEFAULT_KEEP):
    """Pure decision logic for one package. `registry` needs only a
    `.children(owner, package, digest) -> Result` method, so tests can
    inject a fake with no real network/SSH access."""
    ranked = sorted(versions, key=_created_at, reverse=True)
    kept_by_rank = ranked[:keep_n]
    rank_ids = {v["id"] for v in kept_by_rank}

    protected_children = set()
    for v in kept_by_rank:
        children_result = registry.children(org, package, v["name"])
        if not children_result.ok:
            # Fail-closed: we cannot prove this kept index's children are
            # safe to leave unprotected, so touch NOTHING in this package.
            return PackagePlan(
                decisions=[VersionDecision(v, "keep", "newest") for v in ranked],
                skipped=f"manifest fetch failed for kept version {v['name']}: {children_result.error}",
            )
        protected_children.update(children_result.value)

    decisions = []
    for v in ranked:
        digest = v["name"]
        tags = {t.lower() for t in _tags_of(v)}
        if v["id"] in rank_ids:
            decisions.append(VersionDecision(v, "keep", f"newest {keep_n}"))
        elif digest in live_digests:
            decisions.append(VersionDecision(v, "keep", "live reference on a fleet host"))
        elif tags & CHANNEL_TAGS:
            decisions.append(VersionDecision(v, "keep", f"channel tag ({sorted(tags & CHANNEL_TAGS)})"))
        elif digest in protected_children:
            decisions.append(VersionDecision(v, "keep", "child manifest of a kept index"))
        else:
            decisions.append(VersionDecision(v, "delete", f"not in newest {keep_n}, no live ref, no channel tag, not a child of a kept index"))
    return PackagePlan(decisions=decisions)


def check_rate_limit(api, min_remaining):
    result = api.request("/rate_limit")
    if not result.ok or not isinstance(result.value, dict):
        return Result(False, error=f"could not read /rate_limit: {result.error}")
    core = (result.value.get("resources") or {}).get("core") or {}
    remaining = core.get("remaining")
    if not isinstance(remaining, int):
        return Result(False, error="/rate_limit response missing resources.core.remaining")
    if remaining < min_remaining:
        return Result(False, error=f"core rate limit remaining={remaining} < required minimum={min_remaining}; resets at {core.get('reset')}")
    return Result(True, remaining)


def list_org_packages(api, org, only=None):
    result = api.request(f"/orgs/{org}/packages?package_type=container&per_page=100", paginate=True)
    if not result.ok or not isinstance(result.value, list):
        return Result(False, error=f"could not list packages: {result.error}")
    names = sorted(p["name"] for p in result.value if isinstance(p, dict) and p.get("name"))
    if only:
        names = [n for n in names if n in only]
    return Result(True, names)


def list_package_versions(api, org, package):
    endpoint = f"/orgs/{org}/packages/container/{quote(package, safe='')}/versions?per_page=100"
    result = api.request(endpoint, paginate=True)
    if not result.ok or not isinstance(result.value, list):
        return Result(False, error=f"could not list versions for {package}: {result.error}")
    return Result(True, result.value)


def delete_version(api, org, package, version_id):
    endpoint = f"/orgs/{org}/packages/container/{quote(package, safe='')}/versions/{version_id}"
    return api.request(endpoint, method="DELETE")


def restore_command(org, package, version_id):
    endpoint = f"orgs/{org}/packages/container/{quote(package, safe='')}/versions/{version_id}/restore"
    return f"gh api -X POST {endpoint}"


def build_report(org, package_plans, keep_n):
    records = []
    for package, plan in package_plans.items():
        if plan.skipped:
            records.append({
                "package": package, "action": "package_skipped", "reason": plan.skipped,
            })
            continue
        for decision in plan.decisions:
            v = decision.version
            records.append({
                "package": package,
                "version_id": v.get("id"),
                "digest": v.get("name"),
                "tags": _tags_of(v),
                "created_at": v.get("created_at"),
                "action": decision.action,
                "reason": decision.reason,
                "restore_command": restore_command(org, package, v.get("id")) if decision.action == "delete" else None,
            })
    summary = {
        "keep": sum(1 for r in records if r["action"] == "keep"),
        "delete": sum(1 for r in records if r["action"] == "delete"),
        "package_skipped": sum(1 for r in records if r["action"] == "package_skipped"),
    }
    return records, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--org", default="qwickapps")
    parser.add_argument("--keep", type=int, default=DEFAULT_KEEP)
    parser.add_argument("--enforce", action="store_true", help="Actually delete. Default is dry-run.")
    parser.add_argument("--package", action="append", default=None, help="Limit to this package (repeatable). Default: every container package in --org.")
    parser.add_argument("--min-rate-limit", type=int, default=DEFAULT_MIN_RATE_LIMIT)
    parser.add_argument("--delete-batch-recheck", type=int, default=50, help="Re-check /rate_limit after this many DELETE calls during --enforce.")
    parser.add_argument("--output", default=None, help="JSONL report path. Default: ghcr-prune-report-<timestamp>.jsonl in cwd.")
    parser.add_argument("--hosts", default=None, help="Comma-separated host names to inventory (default: all of " + ",".join(h["name"] for h in DEFAULT_HOSTS) + ")")
    args = parser.parse_args()

    output_path = args.output or f"ghcr-prune-report-{int(time.time())}.jsonl"

    api = GitHub()
    rl = check_rate_limit(api, args.min_rate_limit)
    if not rl.ok:
        print(f"[ghcr-prune] ABORT: {rl.error}", file=sys.stderr)
        return 2
    print(f"[ghcr-prune] rate limit OK: {rl.value} remaining")

    only = set(args.package) if args.package else None
    packages_result = list_org_packages(api, args.org, only=only)
    if not packages_result.ok:
        print(f"[ghcr-prune] ABORT: {packages_result.error}", file=sys.stderr)
        return 2
    packages = packages_result.value
    if only:
        missing = only - set(packages)
        if missing:
            print(f"[ghcr-prune] ABORT: requested package(s) not found in org: {sorted(missing)}", file=sys.stderr)
            return 2

    hosts = DEFAULT_HOSTS
    if args.hosts:
        wanted = set(args.hosts.split(","))
        hosts = [h for h in DEFAULT_HOSTS if h["name"] in wanted]

    live_digests, per_host_refs, host_errors = collect_live_digests(hosts, args.org)
    if host_errors:
        print("[ghcr-prune] ABORT: live-ref inventory incomplete:", file=sys.stderr)
        for err in host_errors:
            print(f"  - {err}", file=sys.stderr)
        return 2
    print(f"[ghcr-prune] live-ref inventory OK: {len(live_digests)} distinct live digests across {len(hosts)} hosts")

    try:
        actor = subprocess.run(["gh", "api", "user", "--jq", ".login"], capture_output=True, text=True, check=True).stdout.strip()
        token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"[ghcr-prune] ABORT: could not obtain registry credentials: {exc}", file=sys.stderr)
        return 2
    registry = Registry(actor, token)

    package_plans = {}
    for package in packages:
        versions_result = list_package_versions(api, args.org, package)
        if not versions_result.ok:
            package_plans[package] = PackagePlan(skipped=versions_result.error)
            continue
        package_plans[package] = plan_package(args.org, package, versions_result.value, live_digests, registry, keep_n=args.keep)

    records, summary = build_report(args.org, package_plans, args.keep)
    with open(output_path, "w") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    print(f"[ghcr-prune] report written to {output_path}")
    print(f"[ghcr-prune] keep={summary['keep']} delete={summary['delete']} package_skipped={summary['package_skipped']}")

    if not args.enforce:
        print("[ghcr-prune] DRY RUN -- nothing deleted. Review the report, then re-run with --enforce.")
        return 0

    print(f"[ghcr-prune] ENFORCING deletions ({summary['delete']} versions)...")
    deleted, failed = 0, 0
    calls_since_check = 0
    for record in records:
        if record["action"] != "delete":
            continue
        if calls_since_check >= args.delete_batch_recheck:
            rl = check_rate_limit(api, args.min_rate_limit)
            if not rl.ok:
                print(f"[ghcr-prune] ABORT mid-run: {rl.error}. {deleted} deleted so far; see {output_path} for restore commands.", file=sys.stderr)
                return 2
            calls_since_check = 0
        result = delete_version(api, args.org, record["package"], record["version_id"])
        calls_since_check += 1
        if result.ok:
            deleted += 1
            print(f"[ghcr-prune] deleted {record['package']} {record['digest']} (id={record['version_id']}); restore: {record['restore_command']}")
        else:
            failed += 1
            print(f"[ghcr-prune] FAILED to delete {record['package']} id={record['version_id']}: {result.error}", file=sys.stderr)
    print(f"[ghcr-prune] done: deleted={deleted} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
