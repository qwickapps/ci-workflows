# deploy-app.yml secondary lane (Momo Coolify): workflow spec and safety checks

Card: t_8f74771f (child of t_ba218534). Baseline: review ref
refs/review/t_ac4c4f1d/520ad335fb04 plus the uncommitted t_ba218534 workspace
changes (evidence record, digest pinning, unsupported-feature refusal, stop-job
concurrency). Each step below is marked IMPLEMENTED (in that code) or REQUIRED
(still open, owned by t_ba218534 unless noted).

## 0. Scope and invariants

- Lane is a closed input: `lane in {primary, secondary}`, default `primary`.
- Secondary = qwickapps-momo Coolify, exactly two slots:
  `build -> <app>-build`, `uat -> <app>-uat` (config
  `config/coolify-secondary-validation.json`, schema
  `coolify-secondary-validation/v1`, slots must be exactly {build, uat}).
- `live` and `stable` never run on the secondary lane.
- Credential: `COOLIFY_MOMO_DEPLOY_TOKEN` is the ONLY Coolify credential and
  keeps that exact name end to end. No other Coolify token identifier or
  secrets-service path may appear in the workflow, action, or helper scripts.
  `scripts/validate-coolify-token-exclusivity.py` scans all production
  deployment assets and fails closed on a forbidden token name or a missing
  required asset. The composite action runs it before resolving credentials.
- Every check fails closed: a check that cannot run is a failure, never a skip.

## 1. Job graph (secondary)

    resolve-stage -> validate-env -> build(build stage only) -> verify-provenance
      -> deploy-coolify-build | deploy-coolify-uat
      -> retag -> stop-coolify-build-slot (build stage only)

Primary-only jobs (`deploy-caprover`, `scale-build-slot`, `deploy-stable`) are
gated on `deployment_lane == 'primary'`; secondary-only jobs on
`deployment_lane == 'secondary'`. Neither lane's job may run when the other is
selected.

## 2. Steps and safety checks

### 2.1 Admission (resolve-stage) — IMPLEMENTED
1. `lane` not in {primary, secondary} -> fail.
2. secondary + stage not in {build, uat} ->
   `ERROR: secondary deployment lane supports only explicit build and uat validation slots; live/stable fail closed`
3. secondary + any primary-only feature requested -> fail (see §3).
4. Target is derived, never taken from caller host inputs:
   `TARGET_APP=<app>-<stage>`, `TARGET_APP_URL=http://<app>-<stage>.taile324e7.ts.net:<container_port>`.

### 2.2 Immutable image / provenance — IMPLEMENTED
1. `verify-provenance` resolves the image to a `sha256:<64 hex>` digest.
2. `coolify-validation-deploy.py` deploys `<base>@sha256:<hex>` (Coolify 4.x
   native `{name}:{tag}` form), never a movable tag such as `release-candidate`.
3. Fail-closed messages:
   - missing/malformed digest: `Coolify validation requires the verified sha256 image digest from verify-provenance`
   - ref carries a different digest: `image_ref digest differs from the verified provenance digest; refusing deployment`
4. Post-deploy readback of `docker_registry_image_name/tag` must equal the
   pinned values, else `Coolify image readback did not match the requested immutable image` (+ rollback).

### 2.3 Rendered environment — IMPLEMENTED
1. Env is rendered in-job into `$RUNNER_TEMP` by the caller's
   `env_render_script`; no artifact, no /tmp fallback. Missing script or
   empty output -> fail.
2. Parser rejects: lines without `=`, invalid keys, duplicate keys.
3. `TS_HOSTNAME` must equal the slot name:
   `secondary validation requires TS_HOSTNAME=<app>-<stage>; rendered env declared a different or empty hostname`
4. After deploy, every rendered key/value is read back from Coolify; mismatch ->
   `Coolify rendered-env readback did not match the requested values` (+ rollback).
   HTTP error bodies on env writes are withheld (may contain secrets).
5. Rendered env file and rollback snapshot are deleted in an `always()` step.

### 2.4 Topology preflight / post-check — IMPLEMENTED
1. Preflight (`coolify-validation-topology.py`) before any mutation: the slot
   hostname must have no live claimant on the CapRover hosts
   (oci-gateway, oci-main, server1-qwickforge), Tailscale (TS_API_KEY) or Coolify.
2. Target pinning: an existing app must be `build_pack=dockerimage` on the exact
   configured Momo server + destination, else
   `Coolify app '<name>' is not on the exact configured Momo destination; refusing mutation`.
   Same-named duplicates -> `multiple Coolify applications are named '<name>'; refusing ambiguous target`.
3. A newly created app is re-read and target-asserted BEFORE anything is
   deployed; on mismatch it is deleted.
4. Post-check: same topology script after health/smoke/E2E; a conflict fails the
   job, which triggers the rollback step.
5. Missing TS key -> `TS_API_KEY could not be resolved; topology verification cannot be skipped`.

### 2.5 Health — IMPLEMENTED, one gap
1. Liveness: `<target_url><health_path>` polled 15 x 20s ->
   `Momo validation health check failed`.
2. Deep subsystem check via caller's `.github/scripts/deep-health-check.sh` with
   `critical_subsystems` / `warning_subsystems`.
3. REQUIRED: if the caller repo lacks that script the step dies with a bash
   "No such file" error. Add an explicit check:
   `::error::deep-health-check.sh not found in caller repo; secondary lane cannot verify subsystem health, failing closed`
4. REQUIRED: `prod_critical_subsystems` (promoted to critical in non-build
   stages on primary) is not passed to the secondary uat run, so it is silently
   dropped. Either merge it into critical for `uat`, or fail closed (§3).

### 2.6 Smoke / E2E — IMPLEMENTED
1. `smoke_test_path` (curl, 2 retries), `smoke_test_command`, `run_e2e`
   (Playwright smoke|home|health), `e2e_command`, all against the slot URL with
   `APP_URL, HEALTH_PATH, IMAGE_REF, APP_NAME, ENV_LABEL=<role>`.
2. `run_migrations` only for uat; requested but no script ->
   `migration check requested but no migration script exists`.
3. Any failure fails the job and triggers rollback (§2.7). `public_url` is not
   used: validation slots are tailnet-only.

### 2.7 Evidence and rollback — IMPLEMENTED, gaps noted
Evidence (`coolify-secondary-validation-evidence/v1`), written by the deploy
step and appended to the job summary: lane, backend, role, resource
name/uuid, created flag, server/destination uuid, pinned image + digest,
Coolify deployment_uuid, rendered-env key names + sha256 (no values), rollback
plan. No record -> `Coolify deploy produced no evidence record; failing closed`.

Rollback:
1. In-script: any error after the snapshot restores the previous image + env
   (existing app) or deletes the created app. Rollback failure prints
   `FATAL: Coolify validation rollback also failed: <reason>` and the job fails.
2. Action-level: `failure() && steps.deploy.outcome == 'success'` restores from
   the snapshot after a health/smoke/E2E/post-check failure.
3. A deployment with no `deployment_uuid` is refused (no untracked deploys);
   terminal states failed/cancelled/error or >10 min -> fail + rollback.
4. Build slot is stopped after retag (`stop-coolify-build-slot`) with
   target assertion first.

REQUIRED:
- Evidence lives only in the step summary. It should also record the outcome of
  health, smoke/E2E and the post-check (write a final record after the
  post-check), so the summary proves the validated state, not just the deploy.
- Do NOT upload it as an Actions artifact (org artifact quota; see
  env_render_script rationale). Step summary is the evidence sink.

## 3. Unsupported backend features: fail-closed contract

Requested on lane=secondary -> resolve-stage exits 1 with one message listing
every offending input:

    ERROR: secondary (Momo Coolify) lane does not implement:<inputs>; refusing instead of skipping. Use lane=primary for these features.

| Input | Status |
|---|---|
| stage=live / stable | IMPLEMENTED (separate message, §2.1) |
| record_first_stable_evidence=true | IMPLEMENTED |
| bootstrap_first_stable=true | IMPLEMENTED |
| require_live_approval_check=true | IMPLEMENTED |
| cmd (non-empty) | IMPLEMENTED |
| caprover_url (non-empty) | REQUIRED: an explicit CapRover override on the Coolify lane is a caller error, refuse it. (`caprover_host` is a required input for every caller, so it cannot be refused; it is ignored by design and documented.) |
| prod_critical_subsystems (non-empty, stage=uat) | REQUIRED unless §2.5.4 wires it through |
| gateway_live_url / gateway_stable_url / route_gateway | covered by the live/stable refusal; no extra check |

## 4. Concurrency (detail owned by t_2740078a)

- Secondary groups: `coolify-momo-<app>-build` (deploy-coolify-build AND
  stop-coolify-build-slot) and `coolify-momo-<app>-uat`; `cancel-in-progress: false`.
- Primary groups: `caprover-deploy-<app>-<stage>`. The prefixes are disjoint,
  so the lanes never queue behind or cancel each other.
- Known GitHub behaviour: a group holds at most one PENDING job; a newer pending
  job cancels the older pending one even with cancel-in-progress false. Outcome
  is a visibly cancelled run (never a false success); the worst case is a build
  slot left running until the next run's stop. Acceptable; documented.

## 5. Credentials — IMPLEMENTED, gaps noted

`scripts/resolve-coolify-validation-credentials.sh`: takes
`COOLIFY_MOMO_DEPLOY_TOKEN`, falls back only to secrets path
`infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN`, masks, and exports the
same exact name. Unresolved ->
`scoped COOLIFY_MOMO_DEPLOY_TOKEN could not be resolved; refusing secondary deployment`.
The deploy script itself refuses an empty token:
`COOLIFY_MOMO_DEPLOY_TOKEN is missing; secondary deployment fails closed`.

REQUIRED:
- Narrow secrets: the composite action env currently gets `toJSON(secrets)` and
  every QWICKSECRETS_* key on ALL steps. Only the env-render step may receive
  caller/QwickSecrets material; topology, deploy, health, smoke/E2E and
  rollback steps get only `COOLIFY_MOMO_DEPLOY_TOKEN` and `TS_API_KEY_RESOLVED`.
  (Smoke/E2E commands are caller-supplied code; they must not see deploy
  credentials.)
- The fallback URL `qwickapps-secrets-live...:7007` is the old tailnet LB, recorded
  in fleet memory (2026-10-15) as refusing connections; not re-probed for this spec
  (plain-HTTP probe blocked by guard), so t_ba218534 must verify it from the macmini
  runner. If it is dead the fallback never succeeds. It still fails closed, but
  the GitHub secret `COOLIFY_MOMO_DEPLOY_TOKEN` must be present on every
  caller. Repoint the fallback to the live secrets endpoint or drop it; do not
  add any other COOLIFY_* path.

## 6. Helper provenance

Every `qwickapps/ci-workflows` checkout in deploy-app.yml (both lanes) uses
`ref: main`. So a run of an unmerged workflow commit executes main's helper
scripts, and review-time runs do not exercise the scripts under review.
REQUIRED for the secondary jobs: check out helpers at the same commit as the
workflow under test, or the pre-merge validation evidence is void. Changing the
primary-lane checkouts is out of scope for this card.

## 7. Acceptance tests (t_ba218534 / t_5d681050)

- `coolify-validation-safety.test.py`: digest pinning, mismatch refusal,
  target assertion + delete-on-wrong-destination, evidence written, env
  readback, rollback paths.
- `deploy-app-stage-host-gate.test.sh`: lane gate, unsupported-input refusal
  incl. caprover_url and prod_critical_subsystems once added.
- `deploy-stable-caprover.test.sh`: allowlist the intended secondary jobs
  (resolve-stage, deploy-coolify-*, stop-coolify-build-slot) instead of
  "no other job mentions coolify".
- Token exclusivity check from t_ceac1895 runs in CI over deploy-app.yml,
  `.github/actions/coolify-validation/`, and `scripts/*coolify*`.
- Mutation check: break each gate once; the relevant test must fail.
