#!/usr/bin/env bash
#
# check-first-deploy-proof.sh -- aos#193 Phase 1 §2 ("First-deploy proof,
# strengthened").
#
# Before this script existed, `deploy-caprover`'s live-stage path
# unconditionally curled `stable_app_url` and failed if it wasn't healthy --
# there was no allowance anywhere for a brand-new app's very first live
# promotion (aos#193's design doc confirmed this: "This is a real gap
# against SOP rule 4, not a hypothetical"). This script answers exactly one
# question -- "has this app EVER been promoted past live before?" -- as
# three independent, externally-queryable facts, ALL of which must say
# "never" for a first-deploy claim to be allowed:
#
#   1. CapRover app-absence: does `<app>-stable` exist on the target
#      CapRover instance at all (not just "is it currently healthy")?
#   2. GHCR tag-history-absence: has a `release` or `stable` tag EVER
#      existed for this app's image repo? (Closes the "delete the CapRover
#      app and refake first-deploy" gap that check 1 alone leaves open --
#      an app that was promoted once, then had its stable slot deleted,
#      still carries `release`/`stable` tag history in the registry.)
#   3. Single-use-marker-absence: has a `blue-green/first-deploy-used`
#      check run already been recorded for THIS app, on the promoting
#      commit, by a legitimate ci-workflows deploy-app.yml run (not just
#      any check run with a matching name -- see the binding verification
#      below)? (Closes the gap that would remain even if 1 and 2 were both
#      somehow cleared -- see create-blue-green-check-run.sh, which records
#      this marker on a successful first-deploy.)
#
# A caller cannot claim "first deploy" by passing a flag -- every signal
# here is queried directly from CapRover, GHCR, and GitHub, none of which a
# workflow_dispatch input can fake.
#
# aos#193 review finding #5 (marker binding): the `blue-green/first-deploy-
# used` check run is scoped by NAME to this exact app (`blue-green/first-
# deploy-used/<app_name>`, not a bare shared name) so one app's marker on a
# commit can never satisfy a different app's first-deploy check in a
# multi-app repo, AND its embedded output.text payload (repo/app_name/sha)
# is verified here on read, not just checked for existence.
#
# aos#193 review finding #1 (BLOCKER, round 2): a payload match alone is
# NOT enough to count a candidate as a valid marker -- output.text is just
# text the creating step fully controls, so a payload match alone is
# trivially forgeable by any other same-repo workflow with checks:write.
# Each payload-matching candidate is additionally verified via
# scripts/lib/check-run-binding.sh against the GitHub Actions API itself
# (creating app.slug == "github-actions", and the run named by
# external_id actually has this head_sha, this repo, status=="completed",
# and referenced_workflows[] proving it executed deploy-app.yml) -- see
# that library's header for the full story on why the previous
# self-reported `workflow_ref` text check was both never satisfied by a
# real record and trivially forgeable.
#
# KNOWN LIMITATION (documented, not silently accepted): check 3 above is
# scoped to the ONE commit sha this run is promoting (the exact sha
# deploy-caprover checked out for this run), not to "any ancestor commit"
# generally -- GitHub's REST API has no endpoint to list check runs across
# an arbitrary commit range, only per-exact-sha
# (`GET /repos/{owner}/{repo}/commits/{sha}/check-runs`). A first-deploy
# marker recorded against a DIFFERENT commit than the one a later run
# promotes would not be found by this check alone. Checks 1 and 2 are
# registry/orchestrator-level facts independent of which commit is being
# checked, so they remain the primary proof; check 3 is a secondary,
# same-commit-only backstop. A follow-up (tracked under aos#193) would
# replace the commit-scoped marker with a repo-scoped one (e.g. a dedicated
# git ref such as refs/blue-green/first-deploy-used/<app>) that does not
# depend on which commit a later run happens to check out.
#
# Any hard failure while querying CapRover or GHCR (auth failure, network
# error, malformed response) is NOT treated as "absent" -- it exits
# non-zero so the caller never allows a first-deploy claim on an
# inconclusive check. Only a clean, unambiguous "not found" counts as a
# negative (never-deployed) signal.
#
# Usage:
#   check-first-deploy-proof.sh \
#     --caprover-url      <https://captain.app.qwickforge.com> \
#     --caprover-password <...> \
#     --stable-app-name   <app>-stable \
#     --github-token      <token with packages:read, checks:read> \
#     --owner             qwickapps \
#     --repo              <owner>/<repo> \
#     --app-name          <app> \
#     --image-name        <real GHCR package name from resolve-stage's
#                          image_name output, NOT a string derived from
#                          app_name -- see aos#193 review finding #3> \
#     --commit-sha         <sha>
#
# Emits `first_deploy=true|false` to $GITHUB_OUTPUT if set, and always to
# stdout as the final line. All diagnostic/progress text goes to stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "$SCRIPT_DIR/lib/caprover-api.sh"
# shellcheck source=scripts/lib/check-run-binding.sh
source "$SCRIPT_DIR/lib/check-run-binding.sh"

CAPROVER_URL=""
CAPROVER_PASSWORD=""
STABLE_APP_NAME=""
GITHUB_TOKEN=""
OWNER=""
REPO=""
APP_NAME=""
IMAGE_NAME=""
COMMIT_SHA=""

usage() {
  cat >&2 <<'EOF'
Usage:
  check-first-deploy-proof.sh \
    --caprover-url <url> --caprover-password <pw> --stable-app-name <name> \
    --github-token <token> --owner <org> --repo <owner/repo> \
    --app-name <app> --image-name <real-ghcr-package-name> --commit-sha <sha>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caprover-url)      CAPROVER_URL="$2"; shift 2 ;;
    --caprover-password) CAPROVER_PASSWORD="$2"; shift 2 ;;
    --stable-app-name)   STABLE_APP_NAME="$2"; shift 2 ;;
    --github-token)      GITHUB_TOKEN="$2"; shift 2 ;;
    --owner)              OWNER="$2"; shift 2 ;;
    --repo)               REPO="$2"; shift 2 ;;
    --app-name)            APP_NAME="$2"; shift 2 ;;
    --image-name)         IMAGE_NAME="$2"; shift 2 ;;
    --commit-sha)         COMMIT_SHA="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for var in CAPROVER_URL CAPROVER_PASSWORD STABLE_APP_NAME GITHUB_TOKEN OWNER REPO APP_NAME IMAGE_NAME COMMIT_SHA; do
  if [ -z "${!var}" ]; then
    flag="$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
    echo "::error::missing required argument: --$flag" >&2
    usage
    exit 2
  fi
done

export GH_TOKEN="$GITHUB_TOKEN"

# ── Check 1: CapRover app-absence ───────────────────────────────────────
echo "check-first-deploy-proof: checking CapRover for '${STABLE_APP_NAME}' on ${CAPROVER_URL}..." >&2
CAPROVER_TOKEN=""
if ! CAPROVER_TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"; then
  echo "::error::check-first-deploy-proof: could not authenticate to CapRover -- refusing to guess first-deploy status" >&2
  exit 1
fi

# caprover_get_app_definitions itself now validates status==100 and an
# actual array at .data.appDefinitions (aos#193 review finding #3) --
# a CapRover HTTP-200 error envelope or a malformed/empty body is a hard
# failure there, propagated as a non-zero return here, never silently
# read as "no apps".
CAPROVER_DEFS=""
if ! CAPROVER_DEFS="$(caprover_get_app_definitions "$CAPROVER_URL" "$CAPROVER_TOKEN")"; then
  echo "::error::check-first-deploy-proof: CapRover appDefinitions query failed -- refusing to guess first-deploy status" >&2
  exit 1
fi

CAPROVER_APP_EXISTS="false"
if printf '%s' "$CAPROVER_DEFS" | jq -e --arg app "$STABLE_APP_NAME" \
    '.data.appDefinitions[]? | select(.appName == $app)' >/dev/null 2>&1; then
  CAPROVER_APP_EXISTS="true"
fi
echo "check-first-deploy-proof: CapRover app '${STABLE_APP_NAME}' exists=${CAPROVER_APP_EXISTS}" >&2

# ── Check 2: GHCR tag-history-absence (release/stable, ever) ────────────
echo "check-first-deploy-proof: checking GHCR package '${IMAGE_NAME}' for release/stable tag history..." >&2
GHCR_TAG_HISTORY_FOUND="false"
GHCR_RESPONSE=""
GHCR_ERR_FILE="$(mktemp)"
trap 'rm -f "$GHCR_ERR_FILE"' EXIT
if GHCR_RESPONSE="$(gh api --paginate "orgs/${OWNER}/packages/container/${IMAGE_NAME}/versions?per_page=100" 2>"$GHCR_ERR_FILE")"; then
  # aos#193 review finding #3: a non-JSON body or an EMPTY body (both
  # possible on a 2xx response `gh api` happily passes through) must be a
  # hard failure, never silently read as "no tag history". `jq -es .` on
  # a genuinely empty string parses fine (slurp of zero inputs -> `[]`),
  # so the empty-body case needs its own explicit check -- it is NOT
  # caught by the JSON-parse check alone.
  if [ -z "$GHCR_RESPONSE" ]; then
    echo "::error::check-first-deploy-proof: GHCR package-versions response was empty -- refusing to guess first-deploy status" >&2
    exit 1
  fi
  if ! printf '%s' "$GHCR_RESPONSE" | jq -es . >/dev/null 2>&1; then
    echo "::error::check-first-deploy-proof: GHCR package-versions response is not valid JSON -- refusing to guess first-deploy status" >&2
    exit 1
  fi
  # `--paginate` prints one JSON array per page, concatenated (not merged
  # into a single array) -- `jq -s` (slurp) reads all of them as separate
  # inputs into one outer array, and `flatten` collapses that plus each
  # page's own array nesting into one flat list of version objects,
  # regardless of how many pages came back (including exactly one).
  if printf '%s' "$GHCR_RESPONSE" | jq -es '
      flatten
      | any(.metadata.container.tags[]? | . == "release" or . == "stable")
    ' 2>/dev/null | grep -q '^true$'; then
    GHCR_TAG_HISTORY_FOUND="true"
  fi
else
  # aos#193 review finding #3 (404 positive-evidence, round 1): a 404
  # counts as "package genuinely does not exist" ONLY when BOTH the HTTP
  # status is 404 AND the response carries GitHub's own specific "Package
  # not found." message -- requiring both (not either alone) means a 404
  # returned for a DIFFERENT reason falls through to the hard-failure
  # branch below instead of being read as proof of absence.
  #
  # aos#193 review finding #2 (MEDIUM, round 2): that alone is still
  # ambiguous. GitHub returns that EXACT SAME 404 + "Package not found."
  # response for a private package this token simply cannot see (not
  # linked/scoped to the caller repo) -- indistinguishable from "never
  # pushed" by response text alone. Before trusting this 404 as absence,
  # independently prove the token can see container packages in this org
  # AT ALL: `GET /orgs/{owner}/packages?package_type=container` filters
  # its results to packages associated with the triggering repository when
  # called with the ephemeral GITHUB_TOKEN, so a non-empty result here is
  # real positive evidence of package visibility for this repo -- and in
  # real operation this is the normal case, not a special one: this job's
  # `build` dependency has already pushed THIS run's image to
  # `${IMAGE_NAME}` moments before this script ever runs (see
  # deploy-app.yml's `deploy-caprover` job: `needs: [..., build]`). If the
  # visibility probe itself fails or comes back empty, the whole
  # first-deploy proof is INDETERMINATE -- never silently read as
  # absence, exactly like every other ambiguous signal in this script.
  if grep -qi "HTTP 404" "$GHCR_ERR_FILE" && grep -qi "Package not found" "$GHCR_ERR_FILE"; then
    echo "check-first-deploy-proof: got a 404 'Package not found' for '${IMAGE_NAME}' -- confirming the token has real container-package visibility in org '${OWNER}' before trusting this as absence..." >&2
    VISIBILITY_ERR_FILE="$(mktemp)"
    VISIBILITY_OK="false"
    VISIBILITY_RESPONSE=""
    if VISIBILITY_RESPONSE="$(gh api "orgs/${OWNER}/packages?package_type=container&per_page=1" 2>"$VISIBILITY_ERR_FILE")"; then
      if printf '%s' "$VISIBILITY_RESPONSE" | jq -es 'flatten | length > 0' 2>/dev/null | grep -q '^true$'; then
        VISIBILITY_OK="true"
      fi
    fi
    if [ "$VISIBILITY_OK" != "true" ]; then
      echo "::error::check-first-deploy-proof: could not positively confirm this token can see ANY container package in org '${OWNER}' (orgs/${OWNER}/packages?package_type=container returned empty or failed) -- a 404 for '${IMAGE_NAME}' is therefore INDETERMINATE (genuine absence and a visibility gap look identical), not proof of absence. Refusing to guess first-deploy status." >&2
      cat "$VISIBILITY_ERR_FILE" >&2
      rm -f "$VISIBILITY_ERR_FILE"
      exit 1
    fi
    rm -f "$VISIBILITY_ERR_FILE"
    echo "check-first-deploy-proof: confirmed token has real container-package visibility in org '${OWNER}' -- GHCR package '${IMAGE_NAME}' genuinely does not exist -- no tag history (as expected for a genuinely new app)" >&2
    GHCR_TAG_HISTORY_FOUND="false"
  else
    echo "::error::check-first-deploy-proof: GHCR package-versions query failed unexpectedly -- refusing to guess first-deploy status" >&2
    cat "$GHCR_ERR_FILE" >&2
    exit 1
  fi
fi
echo "check-first-deploy-proof: GHCR release/stable tag history found=${GHCR_TAG_HISTORY_FOUND}" >&2

# ── Check 3: single-use marker absence (this commit only -- see limitation
#    note above), scoped and bound to THIS app + a legitimate creator ────
MARKER_CHECK_NAME="blue-green/first-deploy-used/${APP_NAME}"
MARKER_CHECK_NAME_ENCODED="$(jq -rn --arg n "$MARKER_CHECK_NAME" '$n | @uri')"
echo "check-first-deploy-proof: checking for an existing '${MARKER_CHECK_NAME}' marker on ${COMMIT_SHA}..." >&2
MARKER_RESPONSE=""
if ! MARKER_RESPONSE="$(gh api "repos/${REPO}/commits/${COMMIT_SHA}/check-runs?check_name=${MARKER_CHECK_NAME_ENCODED}" 2>&1)"; then
  echo "::error::check-first-deploy-proof: check-runs query failed unexpectedly -- refusing to guess first-deploy status" >&2
  echo "$MARKER_RESPONSE" >&2
  exit 1
fi
if ! printf '%s' "$MARKER_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "::error::check-first-deploy-proof: check-runs query returned non-JSON response" >&2
  exit 1
fi

# aos#193 review finding #5: existence of a same-named check run is not
# enough -- verify each candidate's embedded output.text payload actually
# binds repo+app_name+sha (redundant with the name scoping and the
# per-sha API path, but cheap defense in depth).
#
# aos#193 review finding #1 (BLOCKER, round 2): a payload match alone is
# NOT sufficient either -- output.text is just text the creating step
# fully controls. Each payload-matching candidate is additionally run
# through scripts/lib/check-run-binding.sh's GitHub-Actions-API binding
# check (creating app.slug=="github-actions" and the run named by
# external_id really has this head_sha/repo/status=="completed" and
# referenced_workflows[] proving it executed deploy-app.yml) before it
# counts as a legitimate marker.
MARKER_FOUND="false"
MARKER_CANDIDATE_COUNT="$(printf '%s' "$MARKER_RESPONSE" | jq -r '.total_count // 0')"
if [ "$MARKER_CANDIDATE_COUNT" != "0" ]; then
  PAYLOAD_MATCHING_CANDIDATES="$(printf '%s' "$MARKER_RESPONSE" | jq -c \
    --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$COMMIT_SHA" '
      [ .check_runs[]?
        | (.output.text // "") as $t
        | ($t | fromjson? // {}) as $p
        | select(
            ($p.repo // "") == $repo and
            ($p.app_name // "") == $app and
            ($p.sha // "") == $sha
          )
        | {app_slug: (.app.slug // ""), external_id: (.external_id // "")}
      ]
    ')"
  PAYLOAD_MATCH_COUNT="$(printf '%s' "$PAYLOAD_MATCHING_CANDIDATES" | jq 'length')"

  if [ "${PAYLOAD_MATCH_COUNT:-0}" = "0" ]; then
    echo "::warning::check-first-deploy-proof: found ${MARKER_CANDIDATE_COUNT} check run(s) named '${MARKER_CHECK_NAME}' on ${COMMIT_SHA}, but none carried a payload matching repo/app_name/sha -- not counted as a marker" >&2
  else
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      CAND_APP_SLUG="$(printf '%s' "$candidate" | jq -r '.app_slug')"
      CAND_EXTERNAL_ID="$(printf '%s' "$candidate" | jq -r '.external_id')"
      if check_run_binding_verify "$REPO" "$COMMIT_SHA" "$CAND_APP_SLUG" "$CAND_EXTERNAL_ID"; then
        MARKER_FOUND="true"
        break
      fi
    done < <(printf '%s' "$PAYLOAD_MATCHING_CANDIDATES" | jq -c '.[]')
    if [ "$MARKER_FOUND" != "true" ]; then
      echo "::warning::check-first-deploy-proof: ${PAYLOAD_MATCH_COUNT} check run(s) named '${MARKER_CHECK_NAME}' on ${COMMIT_SHA} matched the expected payload, but none passed the GitHub-Actions-run binding check -- not counted as a marker" >&2
    fi
  fi
fi
echo "check-first-deploy-proof: first-deploy-used marker found=${MARKER_FOUND}" >&2

# ── Verdict: ALL THREE must indicate "never deployed" ───────────────────
FIRST_DEPLOY="false"
if [ "$CAPROVER_APP_EXISTS" = "false" ] && [ "$GHCR_TAG_HISTORY_FOUND" = "false" ] && [ "$MARKER_FOUND" = "false" ]; then
  FIRST_DEPLOY="true"
fi

echo "check-first-deploy-proof: verdict first_deploy=${FIRST_DEPLOY} (caprover_app_exists=${CAPROVER_APP_EXISTS} ghcr_tag_history_found=${GHCR_TAG_HISTORY_FOUND} marker_found=${MARKER_FOUND})" >&2

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "first_deploy=${FIRST_DEPLOY}" >> "$GITHUB_OUTPUT"
fi
echo "first_deploy=${FIRST_DEPLOY}"
