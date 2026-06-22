# Service Contract & Preflight Validation Guide

**Issue:** qwickapps/ci-workflows#24  
**Status:** Implementation complete  
**Purpose:** Prevent deploy secret and env drift across service workflows

---

## Overview

Deployments can fail silently when required secrets or environment variables are not propagated consistently across workflows and runtime platforms. This guide documents the service contract system that validates all required vars are present before deployment.

**Problem:** Weekly scans found repeated deploy outages caused by:
- RCLONE_CONFIG_BASE64 lost after Coolify reset (backup#151)
- Tailscale env vars wiped on deploy (ci-workflows#22)
- One-shot workflows needed to sync renamed secrets (memories#43, slack-mcp-server#16)
- Runtime env drift forcing manual recovery (mcp#135, #140-142, #150)

**Solution:** Add preflight audit step that compares required deploy secrets and runtime env vars against the service contract manifest before mutation.

---

## Quick Start

### 1. Add Your Service to the Contract Manifest

Edit `manifests/service-contracts.yml`:

```yaml
services:
  my-app:
    live:
      required_secrets:
        - GHCR_PULL_TOKEN
      required_env:
        - DATABASE_URL
        - API_KEY
      preserve_patterns:
        - 'DATABASE_*'
      critical: true
```

### 2. The preflight step runs automatically in the deploy workflow

When you deploy with this workflow, the preflight validation runs before configuration:

```
✅ Preflight Service Contract Validation
  ✓ DATABASE_URL
  ✓ API_KEY
  ⚠️  1 vars exist in CapRover but not in env file (will be preserved)
    - LEGACY_CONFIG
✅ All required vars present — deployment can proceed
```

### 3. No changes needed — the deploy-app workflow now includes preflight validation

The reusable deploy-app.yml workflow automatically calls the preflight step:

```yaml
- name: Preflight service contract validation
  run: |
    .ci-workflows/scripts/preflight-service-contract.sh \
      --app-name "${{ inputs.app_name }}" \
      --env-label "${{ needs.resolve-stage.outputs.env_label }}" \
      --env-file "$ENV_FILE" \
      --contract-file ".ci-workflows/manifests/service-contracts.yml" \
      --caprover-url "$CAPROVER_URL" \
      --caprover-password "$CAPROVER_PASSWORD" \
      --github-secrets-json "$GITHUB_SECRETS_JSON"
```

---

## Service Contract Manifest Format

### Structure

```yaml
services:
  <app-name>:
    <env-label>:  # 'dev', 'uat', 'live', or 'stable'
      required_secrets:     # Vars that MUST be in GitHub secrets
        - KEY_NAME
      required_env:         # Vars that MUST be in env file
        - VAR_NAME
      preserve_patterns:    # Patterns for existing CapRover vars to preserve
        - 'TS_*'            # Tailscale networking
        - 'RCLONE_*'        # Rclone backup config
      critical: <bool>      # Fail deployment if required vars missing
      notes: "..."          # Documentation
```

### Field Descriptions

| Field | Purpose | Example |
|-------|---------|---------|
| `required_secrets` | GitHub Actions secrets that MUST exist before deploy | `GHCR_PULL_TOKEN`, `OCI_CAPROVER_PASSWORD` |
| `required_env` | Env file variables that MUST be present for this stage | `DATABASE_URL`, `API_KEY` |
| `preserve_patterns` | Glob patterns for CapRover vars to preserve across deploys | `TS_*` (Tailscale), `RCLONE_*` (backup) |
| `critical` | If true, deployment fails if any required var is missing | `true` for production apps |
| `notes` | Documentation about why these vars are needed | "MCP requires network identity" |

### Validation Logic

When `preflight-service-contract.sh` runs:

1. **Load contract** for app + environment
2. **Check GitHub secrets** for `required_secrets` (fails if missing)
3. **Check env file** for `required_env` (fails if critical app, warns if optional)
4. **Check CapRover state** for existing vars (identifies vars to preserve)
5. **Plan preservation** by matching `preserve_patterns`
6. **Report findings** with full details

---

## Examples

### Example 1: MCP Service (Critical, Network-Dependent)

```yaml
qwickapps-mcp:
  live:
    required_secrets:
      - GHCR_PULL_TOKEN
    required_env:
      - TS_AUTHKEY        # Must have network identity
      - TS_HOSTNAME       # Must be registered with Tailscale
      - PORT              # Container listening port
    preserve_patterns:
      - 'TS_*'            # Preserve all Tailscale vars
    critical: true
    notes: "MCP requires Tailscale network identity; TS_AUTHKEY must survive redeploys"
```

**Preflight checks:**
- ✓ GHCR_PULL_TOKEN exists in GitHub secrets
- ✓ TS_AUTHKEY exists in env file (or preserved from CapRover)
- ✓ TS_HOSTNAME exists in env file (or preserved from CapRover)
- ✓ PORT exists in env file
- ⚠️ Any other TS_* vars in CapRover will be preserved

### Example 2: Backup Service (Critical, Storage-Dependent)

```yaml
qwickapps-backup:
  live:
    required_secrets:
      - GHCR_PULL_TOKEN
    required_env:
      - RCLONE_CONFIG_BASE64   # Encryption for remote storage
      - RCLONE_CONFIG_PASS     # Backup config passphrase
      - BACKUP_STORAGE_PATH    # Primary storage location
      - OCI_BACKUP_ENDPOINT    # Remote backup endpoint
    preserve_patterns:
      - 'RCLONE_*'
      - 'BACKUP_*'
    critical: true
    notes: "Backup requires rclone config; RCLONE_CONFIG_BASE64 loss is unrecoverable"
```

**Preflight checks:**
- ✓ GHCR_PULL_TOKEN in GitHub secrets
- ✓ RCLONE_CONFIG_BASE64 in env file (critical!)
- ✓ RCLONE_CONFIG_PASS in env file (critical!)
- ✓ BACKUP_STORAGE_PATH in env file
- ✓ OCI_BACKUP_ENDPOINT in env file
- ⚠️ Any RCLONE_* or BACKUP_* vars in CapRover will be preserved

### Example 3: Gateway (Special Case — Preserve TS_* Unless Explicit Rotation)

```yaml
provision-gateway:
  live:
    required_secrets:
      - OCI_GATEWAY_CAPROVER_PASSWORD
    required_env:
      - TS_AUTHKEY
      - TS_HOSTNAME
      - GATEWAY_ROUTES_JSON
    preserve_patterns:
      - 'TS_*'            # Preserve unless explicit rotation
      - 'GATEWAY_*'
    critical: true
    notes: "Gateway MUST preserve TS_* unless explicit rotation requested"
```

**Special behavior:** If env file doesn't contain TS_AUTHKEY but CapRover does, the existing value is preserved automatically.

---

## Adding a New Service

### Step 1: Identify Required Vars

For your service, list:
- **GitHub secrets** needed (usually just GHCR_PULL_TOKEN)
- **Env file vars** needed (config, credentials, network identity)
- **Patterns** for vars to preserve across deployments

### Step 2: Edit the manifest

```bash
# Add to manifests/service-contracts.yml
services:
  my-new-app:
    dev:
      required_secrets:
        - GHCR_PULL_TOKEN
      required_env:
        - IMPORTANT_CONFIG
      preserve_patterns:
        - 'MY_APP_*'

    live:
      required_secrets:
        - GHCR_PULL_TOKEN
      required_env:
        - IMPORTANT_CONFIG
        - DATABASE_URL
      preserve_patterns:
        - 'MY_APP_*'
        - 'DATABASE_*'
      critical: true
```

### Step 3: Test locally (optional)

```bash
# Dry-run: check contract without CapRover connection
bash .ci-workflows/scripts/preflight-service-contract.sh \
  --app-name my-new-app \
  --env-label live \
  --env-file .deploy-app-env/app-env-live-my-new-app.env \
  --contract-file .ci-workflows/manifests/service-contracts.yml \
  --dry-run true

# With CapRover (requires credentials):
bash .ci-workflows/scripts/preflight-service-contract.sh \
  --app-name my-new-app \
  --env-label live \
  --env-file .deploy-app-env/app-env-live-my-new-app.env \
  --contract-file .ci-workflows/manifests/service-contracts.yml \
  --caprover-url https://oci-main \
  --caprover-password "$CAPROVER_PASSWORD"
```

### Step 4: Merge and test in CI

The preflight step runs automatically during deploy. If it fails:

```
❌ CRITICAL FAILURE: Missing required vars for critical app
   Missing secrets: 1 (GHCR_PULL_TOKEN)
   Missing env vars: 1 (DATABASE_URL)

Action: Fix missing vars before retry
```

---

## Troubleshooting

### Deployment fails with "Missing required vars"

**Cause:** Contract specifies a var as required, but it's not in GitHub secrets or env file.

**Fix:**
1. Check the contract for your app: `grep -A 10 "^  my-app:" manifests/service-contracts.yml`
2. Verify GitHub secret exists: `gh secret list`
3. Verify env file has the var: `grep VAR_NAME .deploy-app-env/...env`
4. Or remove from contract if truly optional

### "Vars exist in CapRover but not in env file (will be preserved)"

**Cause:** This is normal. Preflight detects vars that exist in CapRover but won't be overwritten.

**What happens:** Those vars are preserved automatically (the configure-caprover-app.sh script merges, not replaces).

**When to worry:**
- If these are stale/orphaned vars, you may want to remove them manually
- Or update the contract to list them in `preserve_patterns` to track intentionally
- Or update the env file to include them if they should be canonical

### CapRover connection fails in preflight

**Cause:** Script tried to validate against live CapRover but network is down.

**Behavior:** If `--caprover-url` and `--caprover-password` are provided but connection fails, preflight treats it as a non-critical warning and continues.

**To force failure:** Update contract and mark as `critical: true`

---

## Verification: Deploy Workflow Integration

The `deploy-app.yml` workflow includes the preflight step automatically:

```yaml
# In .github/workflows/deploy-app.yml, after validate-env job
- name: Preflight service contract validation
  run: |
    chmod +x .ci-workflows/scripts/preflight-service-contract.sh
    .ci-workflows/scripts/preflight-service-contract.sh \
      --app-name "${{ inputs.app_name }}" \
      --env-label "${{ needs.resolve-stage.outputs.env_label }}" \
      --env-file "${{ steps.env-file.outputs.path }}" \
      --contract-file ".ci-workflows/manifests/service-contracts.yml" \
      --caprover-url "$CAPROVER_URL" \
      --caprover-password "$CAPROVER_PASSWORD" \
      --github-secrets-json "$(gh api repos/qwickapps/ci-workflows/actions/secrets -q '.secrets | map({(.name): .value}) | add' || echo '{}')"
```

**When it runs:**
- After env file validation but BEFORE CapRover configuration
- Ensures all required vars exist before any state is mutated
- Non-critical issues generate warnings but don't block deployment
- Critical issues block deployment with clear error message

---

## Best Practices

### 1. Mark Critical Apps

```yaml
services:
  qwickapps-backup:
    live:
      # ...
      critical: true  # ← Deployment fails if required vars missing
```

**Use for:**
- Production services (live/stable)
- Services with irreplaceable secrets (RCLONE_CONFIG_BASE64, DATABASE_URL)
- Services that depend on external integrations (Tailscale, backup storage)

**Don't use for:**
- Development/test services
- Services that can safely redeploy with defaults

### 2. Preserve Patterns Comprehensively

```yaml
preserve_patterns:
  - 'TS_*'            # All Tailscale vars
  - 'RCLONE_*'        # All rclone configs
  - 'DATABASE_*'      # All database configs
  - 'API_*'           # All API keys
```

**Why:** If a var is set outside the canonical pipeline (via hot-patch, per-host override, or managed by another workflow), preserving it prevents accidental deletion.

### 3. Document Why Vars Are Needed

```yaml
notes: "MCP requires Tailscale network identity; TS_AUTHKEY must survive redeploys"
```

**Helps:**
- Future developers understand the constraint
- Onboarding new team members
- Decision-making when refactoring

### 4. Keep Env Files in Git (Encrypted)

```bash
# .deploy-app-env/app-env-live-qwickapps-mcp.env
TS_AUTHKEY=<secret> # decrypt at deploy time
TS_HOSTNAME=qwickapps-mcp
PORT=3000
```

Use sops/age encryption so the env file is auditable but secrets are encrypted at rest.

---

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | ✅ All checks passed, deployment can proceed | None |
| 1 | ❌ Critical failure (missing required var for critical app) | Fix missing var and retry |
| 2 | ⚠️ Warning (orphaned vars, missing optional vars) | Review and continue if safe |

---

## References

- **Issue:** qwickapps/ci-workflows#24
- **Script:** `scripts/preflight-service-contract.sh`
- **Manifest:** `manifests/service-contracts.yml`
- **Workflow integration:** `.github/workflows/deploy-app.yml`
- **Related incidents:**
  - qwickapps/backup#151 (RCLONE_CONFIG_BASE64 lost)
  - qwickapps/ci-workflows#22 (Tailscale vars wiped)
  - qwickapps/memories#43 (Secret sync needed)
  - qwickapps/mcp#135, #140-142, #150 (env drift)
