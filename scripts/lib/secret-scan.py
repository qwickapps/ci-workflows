#!/usr/bin/env python3
"""secret-scan.py -- aos#198 leak-prevention secret scanner.

Standalone, dependency-free (stdlib only, python3 already a hard dependency
fleet-wide) so it can run identically in a local pre-commit hook (offline,
no network) and in a CI job on the self-hosted runner, with no drift
between the two enforcement points.

Modes:
  --diff              read a unified git diff on stdin; scans only ADDED
                       lines (git diff --cached, or a PR's full diff)
  --paths PATH [...]   scan the full content of each given file/dir
                       (recursive) -- used for the backfill scan and for
                       compressed-file scanning, since a diff shows a
                       compressed file as opaque binary.

Compressed files: any changed/scanned path ending in .gz/.zip/.tar.gz/.tgz
is transparently decompressed and its content scanned too (aos#198
requirement: "scan the full diff, including compressed files").

Exit codes:
  0 -- no hits
  1 -- one or more hits (the caller decides what "no override" means --
       this script never offers a bypass flag)

Output: human-readable findings on stderr (never the matched secret value
itself -- only the rule name, file, and line number) and, with --json, a
machine-readable summary on stdout suitable for a backfill report (classes
and counts only, per aos#198's explicit "no values" requirement).
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Ruleset. Categories are aos#198's own list, plus the categories the
# aos#191 leak's redaction summary proved were actually present in real
# traffic (token_assign, GitHub classic/fine-grained, DB URLs, Authorization
# headers, curl -u, sshpass -p, Anthropic keys) -- both sources agree on the
# bulk of this list, which is reassuring rather than redundant.
# ---------------------------------------------------------------------------

RULES: list[tuple[str, re.Pattern]] = [
    ("tskey-auth", re.compile(r"tskey-auth-[A-Za-z0-9]{5,}-[A-Za-z0-9]{20,}")),
    ("tskey-api", re.compile(r"tskey-api-[A-Za-z0-9]{5,}-[A-Za-z0-9]{20,}")),
    ("tskey-other", re.compile(r"\btskey-[A-Za-z0-9-]{20,}")),
    ("github-classic-pat", re.compile(r"\bgh[poura]_[A-Za-z0-9]{30,}")),
    ("github-fine-grained-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai-style-sk-key", re.compile(r"(?<![\w-])sk-[A-Za-z0-9]{20,}(?![\w-])")),
    ("litellm-key", re.compile(r"\bsk-litellm-[A-Za-z0-9_-]{10,}")),
    ("coolify-sanctum-token", re.compile(r"\b\d+\|[A-Za-z0-9]{35,}\b")),
    ("telegram-bot-token", re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b")),
    ("private-key-block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----")),
    (
        "db-url-with-credentials",
        re.compile(r"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:\s/]+:[^@\s]+@"),
    ),
    ("basic-auth-header", re.compile(r"(?i)\bAuthorization:\s*Basic\s+[A-Za-z0-9+/=]{8,}")),
    ("api-key-header", re.compile(r"(?i)\bx-api-key:\s*\S+")),
    ("curl-basic-auth-flag", re.compile(r"(?:^|[\s|])(?:curl\s.*?)?-u\s+[^\s:'\"]+:[^\s'\"]+")),
    ("sshpass-password-flag", re.compile(r"\bsshpass\s+-p\s*\S+")),
    ("json-password-field", re.compile(r'"(?:password|passwd|pwd)"\s*:\s*"[^"]{3,}"')),
    (
        "env-assignment-secret",
        # *_TOKEN/_SECRET/_KEY/_PASSWORD= in any quoting, including after a
        # pipe (aos#198): the leading (?:^|[|;&\s]) covers a bare start of
        # line/segment as well as appearing after a shell separator.
        re.compile(
            r"(?:^|[|;&\s])[A-Za-z_][A-Za-z0-9_]*(?:_TOKEN|_SECRET|_KEY|_PASSWORD|_PASS)\s*=\s*['\"]?[^\s'\"]{4,}"
        ),
    ),
]

# High-entropy fallback: a long, unstructured token that no named rule
# above caught -- the structural gap a fixed-format list can never close
# (research-lead's aos#191 review: "any format it had no pattern for" was
# one of the five ways real credentials got through their first detector).
# Conservative on purpose: a naive entropy check flags routine identifiers,
# hashes and paths, and a gate that fires on the codebase's own harmless
# text at "no override" gets disabled under pressure, which is worse than
# not having it. Three fixes learned the hard way (same review):
#   1. Evaluate the VALUE, not a `name=value`/`name:value` pair -- an
#      unstripped `hash=<64 hex>` computes entropy over the label too and
#      no longer looks like pure hex, so the hash-exclusion below silently
#      stops applying. Split off any leading `label=`/`label:` first.
#   2. Require at least one digit AND one letter in the value. Source
#      identifiers (`_maybe_spawn_session_reviewer`,
#      `mcp__qwickapps__send_telegram`) and path/domain fragments clear a
#      raw entropy threshold comfortably; real credentials essentially
#      always mix letters and digits, and letter-only secrets are still
#      caught by the named format/env-assignment rules above, so this
#      loses no real coverage.
#   3. Reject anything that looks path- or URL-shaped (2+ `/`) -- relative
#      paths and URL tails (`tests/fixtures/x.py`,
#      `//api.anthropic.com/v1/messages`) are exactly the kind of long,
#      mixed-character string this fallback exists to generalize past, and
#      exactly the kind of false positive that erodes trust in the gate.
_ENTROPY_CANDIDATE = re.compile(r"(?<![\w/+=])[A-Za-z0-9_/+=-]{32,}(?![\w/+=])")
_HEX_ONLY = re.compile(r"^[0-9a-fA-F]{32,}$")  # commit SHAs, hashes -- not secrets
_LABEL_PREFIX = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*[:=]")
_HAS_DIGIT = re.compile(r"\d")
_HAS_LETTER = re.compile(r"[A-Za-z]")


def shannon_entropy(s: str) -> float:
    if not s:
        return 0.0
    import math

    counts: dict[str, int] = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    length = len(s)
    return -sum((c / length) * math.log2(c / length) for c in counts.values())


def find_high_entropy(line: str) -> list[str]:
    hits = []
    for m in _ENTROPY_CANDIDATE.finditer(line):
        token = m.group(0)

        # Fix 1: strip a `label=`/`label:` prefix and judge the value alone.
        lm = _LABEL_PREFIX.match(token)
        value = token[lm.end():] if lm else token
        if not value:
            continue

        # Path/URL shape: 2+ slashes anywhere in the ORIGINAL token (fix 3).
        if token.count("/") >= 2:
            continue

        if _HEX_ONLY.match(value):
            # A bare hex string this long is almost always a hash/SHA, not
            # a secret -- hashes are the one high-entropy shape this
            # codebase deliberately produces constantly (command hashes,
            # git SHAs).
            continue

        # Fix 2: require both a digit and a letter in the value.
        if not (_HAS_DIGIT.search(value) and _HAS_LETTER.search(value)):
            continue

        if shannon_entropy(value) >= 4.0:
            hits.append(token)
    return hits


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------


class Finding:
    __slots__ = ("rule", "location", "line_no", "matched_text")

    def __init__(self, rule: str, location: str, line_no: int, matched_text: str):
        self.rule = rule
        self.location = location
        self.line_no = line_no
        self.matched_text = matched_text  # never printed -- only hashed


def _match_hash_prefix(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()[:8]


def load_allowlist(path: str | None) -> set[str]:
    """Hash-pinned allowlist of PROVEN false positives (research-lead's
    aos#191 review: "give it a hash-pinned allowlist... so a verified false
    positive is recorded by identity, without disabling the whole class,
    and without the allowlist itself containing a secret"). One 8-hex-char
    sha256 prefix per line, `#`-comments and blank lines ignored. Never
    silences a whole rule -- only the exact matched text that was manually
    verified benign."""
    candidates = [path] if path else [".secret-scan-allowlist.txt"]
    for p in candidates:
        if p and Path(p).is_file():
            allowed = set()
            for line in Path(p).read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if line:
                    allowed.add(line.lower())
            return allowed
    return set()


def filter_allowlisted(findings: list[Finding], allowlist: set[str]) -> list[Finding]:
    if not allowlist:
        return findings
    return [f for f in findings if _match_hash_prefix(f.matched_text) not in allowlist]


def scan_text(text: str, location: str) -> list[Finding]:
    findings: list[Finding] = []
    for i, line in enumerate(text.splitlines(), start=1):
        for name, pattern in RULES:
            m = pattern.search(line)
            if m:
                findings.append(Finding(name, location, i, m.group(0)))
        for token in find_high_entropy(line):
            findings.append(Finding("high-entropy-string", location, i, token))
    return findings


def decompress_and_scan(path: Path) -> list[Finding]:
    """Decompress a known archive extension and scan its content too
    (aos#198: "scan the full diff, including compressed files")."""
    findings: list[Finding] = []
    name = path.name.lower()
    try:
        if name.endswith(".gz") and not name.endswith(".tar.gz") and not name.endswith(".tgz"):
            with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
                findings += scan_text(fh.read(), f"{path} (gunzipped)")
        elif name.endswith(".tar.gz") or name.endswith(".tgz"):
            with tarfile.open(path, "r:gz") as tf:
                for member in tf.getmembers():
                    if not member.isfile():
                        continue
                    fh = tf.extractfile(member)
                    if fh is None:
                        continue
                    content = fh.read().decode("utf-8", errors="replace")
                    findings += scan_text(content, f"{path}!{member.name}")
        elif name.endswith(".zip"):
            with zipfile.ZipFile(path) as zf:
                for member in zf.namelist():
                    with zf.open(member) as fh:
                        content = fh.read().decode("utf-8", errors="replace")
                        findings += scan_text(content, f"{path}!{member}")
    except Exception as exc:  # noqa: BLE001 -- a corrupt/unreadable archive must not silently skip scanning
        findings.append(Finding(f"unreadable-archive ({exc.__class__.__name__})", str(path), 0, str(path)))
    return findings


_COMPRESSED_SUFFIXES = (".gz", ".zip", ".tar.gz", ".tgz")


def scan_paths(paths: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            for child in p.rglob("*"):
                if child.is_file() and ".git" not in child.parts:
                    findings += scan_paths([str(child)])
            continue
        if not p.is_file():
            continue
        if str(p).lower().endswith(_COMPRESSED_SUFFIXES):
            findings += decompress_and_scan(p)
            continue
        try:
            content = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        findings += scan_text(content, str(p))
    return findings


_DIFF_ADD_RE = re.compile(r"^\+(?!\+\+)(.*)$")
_DIFF_FILE_RE = re.compile(r"^\+\+\+ b/(.*)$")


def scan_diff(diff_text: str) -> list[Finding]:
    """Scan only ADDED lines of a unified diff -- deleted/context lines are
    not new exposure. A compressed file shows as a binary diff header
    ("Binary files a/... and b/... differ"); such paths can't be scanned
    from the diff text alone (git diff never shows their content), so the
    CI wrapper additionally checks out the real blobs for any changed
    compressed file and scans them via --paths (see the reusable workflow)."""
    findings: list[Finding] = []
    current_file = "<unknown>"
    for line in diff_text.splitlines():
        fm = _DIFF_FILE_RE.match(line)
        if fm:
            current_file = fm.group(1)
            continue
        m = _DIFF_ADD_RE.match(line)
        if not m:
            continue
        added = m.group(1)
        for name, pattern in RULES:
            pm = pattern.search(added)
            if pm:
                findings.append(Finding(name, current_file, 0, pm.group(0)))
        for token in find_high_entropy(added):
            findings.append(Finding("high-entropy-string", current_file, 0, token))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diff", action="store_true", help="read a unified diff on stdin")
    parser.add_argument("--paths", nargs="*", default=[], help="scan the full content of these files/dirs")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable class/count summary on stdout")
    parser.add_argument(
        "--allowlist",
        default=None,
        help="path to a hash-pinned allowlist file (default: .secret-scan-allowlist.txt in cwd, if present)",
    )
    args = parser.parse_args(argv)

    findings: list[Finding] = []
    if args.diff:
        findings += scan_diff(sys.stdin.read())
    if args.paths:
        findings += scan_paths(args.paths)

    findings = filter_allowlisted(findings, load_allowlist(args.allowlist))

    if not findings:
        if args.json:
            print(json.dumps({"hits": 0, "classes": {}}))
        return 0

    classes: dict[str, int] = {}
    for f in findings:
        classes[f.rule] = classes.get(f.rule, 0) + 1

    for f in findings:
        loc = f"{f.location}:{f.line_no}" if f.line_no else f.location
        print(f"SECRET-SCAN [{f.rule}] {loc}", file=sys.stderr)

    print(
        f"\nsecret-scan: {len(findings)} hit(s) across {len(classes)} class(es): "
        + ", ".join(f"{k}={v}" for k, v in sorted(classes.items())),
        file=sys.stderr,
    )

    if args.json:
        print(json.dumps({"hits": len(findings), "classes": classes}))

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
