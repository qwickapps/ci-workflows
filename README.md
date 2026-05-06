# ci-workflows

Shared CI workflow scripts for QwickApps repositories. Used as a **git submodule** to provide consistent, centralised CI tooling across all projects.

---

## Contents

```
ci-workflows/
├── .github/workflows/
│   └── security-scan.yml       # Reusable govulncheck + Semgrep security scan
└── scripts/
    ├── attribution-check.sh    # Detects AI co-authorship in PR commits
    └── pr-status-comment.sh    # Posts CI validation results as a PR comment
```

---

## Adding as a submodule

```bash
git submodule add https://github.com/qwickapps/ci-workflows.git .ci-workflows
git commit -m "chore: add ci-workflows submodule"
```

Update to the latest version later with:

```bash
git submodule update --remote .ci-workflows
git commit -m "chore: update ci-workflows submodule"
```

---

## Reusable Workflows

### `.github/workflows/security-scan.yml`

Runs govulncheck and Semgrep, then opens a 72-hour SLA security issue only when there are confirmed findings:

- govulncheck alerts require parsed vulnerability findings greater than zero.
- SAST alerts require parsed Semgrep findings greater than zero at the configured severity.
- Scanner non-zero exits without parsed findings are logged as warnings and do not create security issues.

#### Caller example

```yaml
name: Security Scan

on:
  push:
    branches: [main, dev]
  pull_request:
  schedule:
    - cron: '0 6 * * 1'

permissions:
  contents: read
  issues: write

jobs:
  security-scan:
    uses: qwickapps/ci-workflows/.github/workflows/security-scan.yml@main
```

## Scripts

### `scripts/attribution-check.sh`

Scans every commit in a PR for AI co-authorship `Co-Authored-By` trailers.
Exits **1** if any are found, **0** if the range is clean.

#### Detected patterns

| Tool / Service | Example trailer |
|---|---|
| Claude / Anthropic | `Co-Authored-By: Claude Sonnet <noreply@anthropic.com>` |
| GitHub Copilot | `Co-Authored-By: GitHub Copilot <copilot@...>` |
| GPT / OpenAI / ChatGPT | `Co-Authored-By: GPT-4 <noreply@openai.com>` |
| Google Gemini | `Co-Authored-By: Gemini <...>` |
| OpenAI Codex | `Co-Authored-By: Codex <...>` |
| Generic AI Assistant | `Co-Authored-By: AI Assistant <...>` |

#### Usage

```bash
# Positional arguments
./scripts/attribution-check.sh <base_sha> <head_sha>

# Environment variables
BASE_SHA=abc123  HEAD_SHA=def456  ./scripts/attribution-check.sh

# With PR number for richer log output
BASE_SHA=abc123  HEAD_SHA=def456  PR_NUMBER=42  ./scripts/attribution-check.sh
```

#### GitHub Actions example

```yaml
- name: Checkout (full history)
  uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Attribution check
  run: .ci-workflows/scripts/attribution-check.sh
  env:
    BASE_SHA: ${{ github.event.pull_request.base.sha }}
    HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    PR_NUMBER: ${{ github.event.pull_request.number }}
```

---

### `scripts/pr-status-comment.sh`

Posts a formatted CI validation summary as a comment on the GitHub PR.

#### Required environment variables

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | GitHub token with `repo` (or `pull_requests: write`) scope |
| `GITHUB_REPO` | Repository in `owner/repo` format |
| `PR_NUMBER` | Pull request number |
| `CHECK_STATUS` | `pass` or `fail` |
| `CHECK_OUTPUT` | Human-readable summary text to include in the comment body |

#### Optional environment variables

| Variable | Description |
|---|---|
| `COMMENT_HEADER` | Override the default `## CI Validation Report` heading |
| `DRY_RUN` | Set to `true` to print the comment without posting |

#### Usage

```bash
export GITHUB_TOKEN="ghp_..."
export GITHUB_REPO="qwickapps/myapp"
export PR_NUMBER="42"
export CHECK_STATUS="fail"
export CHECK_OUTPUT="$(./scripts/attribution-check.sh $BASE $HEAD 2>&1)"

./scripts/pr-status-comment.sh
```

#### GitHub Actions example (combined with attribution-check)

```yaml
- name: Checkout
  uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Run attribution check
  id: attr_check
  run: |
    set +e
    OUTPUT=$(.ci-workflows/scripts/attribution-check.sh 2>&1)
    EXIT_CODE=$?
    set -e
    echo "output<<EOF" >> "$GITHUB_OUTPUT"
    echo "$OUTPUT" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"
    echo "status=$([ $EXIT_CODE -eq 0 ] && echo pass || echo fail)" >> "$GITHUB_OUTPUT"
    exit $EXIT_CODE
  env:
    BASE_SHA: ${{ github.event.pull_request.base.sha }}
    HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    PR_NUMBER: ${{ github.event.pull_request.number }}

- name: Post PR comment
  if: always()
  run: .ci-workflows/scripts/pr-status-comment.sh
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITHUB_REPO: ${{ github.repository }}
    PR_NUMBER: ${{ github.event.pull_request.number }}
    CHECK_STATUS: ${{ steps.attr_check.outputs.status }}
    CHECK_OUTPUT: ${{ steps.attr_check.outputs.output }}
```

---

## Contributing

1. All changes go through a PR on `main`.
2. After merging, downstream repos update via `git submodule update --remote`.

---

## Reference

- Design doc 37421058, section 4.5 — PR Pipeline architecture
