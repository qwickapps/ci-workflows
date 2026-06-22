# Deployment Gates Testing Guide

**Document:** crew#24 — Blue-green migration + auto-rollback testing  
**Last Updated:** 2026-06-22

---

## Overview

This guide explains how to test and verify the new deployment gates:
1. **Pre-deploy gate:** Backup slot health check (refuses deploy if backup down)
2. **Post-cutover gate:** 2-minute soak test (triggers auto-rollback if health fails)
3. **Auto-rollback:** Automatic revert + incident creation

---

## Gate 1: Pre-Deploy Backup Health Check

**What it does:** Refuses to start deployment if the backup slot (fallback) is unhealthy.

**Why it matters:** Prevents cascading failures where both live and backup slots are down (like crew#21).

### Test Procedure

**Setup:**
- Service with `-live` and `-stable` slots both running
- Service must have `/health` endpoint returning HTTP 200

**Test: Happy path (backup healthy → deploy allowed)**

```bash
# 1. Verify both slots are healthy
curl -s https://qwickapps-mcp-live.taile324e7.ts.net/health | jq
curl -s https://qwickapps-mcp-stable.taile324e7.ts.net/health | jq
# Expected: Both return {"ok": true}

# 2. Start deploy (should proceed past pre-deploy gate)
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live \
  -f container_port=8000 \
  -f health_path=/health \
  -f caprover_host=captain.oci-main \
  -f dockerfile_path=Dockerfile \
  -f package_json_path=package.json

# 3. Check workflow (should pass pre-deploy gate)
gh run list -R qwickapps/ci-workflows | head -1
# Expected: Pre-deploy gate shows ✅ PASSED
```

**Test: Failure path (backup unhealthy → deploy refused)**

```bash
# 1. Take down the backup slot
docker stop srv-captain--qwickapps-mcp-stable
# or via CapRover: stop the stable app

# 2. Verify backup is down
curl -s https://qwickapps-mcp-stable.taile324e7.ts.net/health
# Expected: Connection timeout or HTTP 5xx

# 3. Try to start deploy (should be blocked by pre-deploy gate)
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live \
  ... (same params as above)

# 4. Check workflow (should FAIL at pre-deploy gate)
gh run list -R qwickapps/ci-workflows | head -1
# Expected: "Pre-deploy safety gate FAILED: Backup slot is UNHEALTHY"
# Workflow exit: ❌ REFUSED DEPLOYMENT

# 5. Restart backup slot and retry
docker start srv-captain--qwickapps-mcp-stable
# or via CapRover: restart the stable app
sleep 30

# 6. Retry deploy (should now pass pre-deploy gate)
```

**Success Criteria:**
- ✅ Deploy blocked when backup is unhealthy
- ✅ Deploy proceeds when backup is healthy
- ✅ Clear error message explaining safety gate

---

## Gate 2: Post-Cutover Soak Test (2-minute stability check)

**What it does:** Probes the new live slot's health endpoint every 5 seconds for 2 minutes. If ANY probe fails, triggers auto-rollback.

**Why it matters:** Catches issues that manifest after traffic cutover (memory leaks, race conditions, resource exhaustion).

### Test Procedure

**Setup:**
- Service deployed to `-live` slot
- Service has `/health` endpoint
- Service will be tested with intentional failure

**Test: Happy path (all probes succeed → deployment complete)**

```bash
# 1. Deploy a working service
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live \
  ... (full params)

# 2. Watch workflow (should reach soak test step)
gh run watch <RUN_ID>

# 3. Expected output during soak test:
# [0/120 s] Probe 1: ✓ OK (HTTP 200)
# [5/120 s] Probe 2: ✓ OK (HTTP 200)
# [10/120 s] Probe 3: ✓ OK (HTTP 200)
# ... (continues for 2 minutes, 24 total probes)
# [120/120 s] Probe 24: ✓ OK (HTTP 200)
# ✅ Soak test PASSED

# 4. Check job result
gh run view <RUN_ID> --json jobs | jq
# Expected: soak-test step shows "conclusion": "success"
```

**Test: Failure path (probe fails → auto-rollback triggered)**

This requires intentionally breaking the `/health` endpoint.

```bash
# OPTION A: Use a test container that fails health check

# 1. Build a broken version of the service
# In your app's Dockerfile or config, make /health return HTTP 503

# 2. Deploy the broken version
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live \
  -f image_ref=ghcr.io/qwickapps/img-mcp:broken-test
  ... (full params)

# 3. Watch workflow
gh run watch <RUN_ID>

# 4. Expected behavior:
# - Pre-deploy gate: ✅ PASSED (backup healthy)
# - Build: ✅ SUCCESS
# - Deploy to live: ✅ SUCCESS
# - Validate health: ✅ PASSED (first few checks succeed)
# - Soak test: Probe 1-3 pass, then...
# - [15/120 s] Probe 4: ✗ FAIL (HTTP 503)
# - ⚠️  Max failures exceeded (1 > 0)
# - ❌ Soak test FAILED
# - 🔄 Triggering automatic rollback...

# 5. Watch auto-rollback execute:
# - Authenticate with CapRover
# - Verify stable slot exists and is healthy
# - Update load balancer (revert traffic)
# - Verify rollback convergence
# - Create GitHub incident issue
# ✅ ROLLBACK COMPLETE

# 6. Verify incident was created
gh issue list -R qwickapps/crew | grep "Auto-rollback"
# Expected: Issue with title "[INCIDENT] Auto-rollback: qwickapps-mcp deployment failed"

# 7. Verify traffic reverted to stable
curl https://qwickapps-mcp.taile324e7.ts.net/health
# Expected: Should connect to stable slot and return 200

# OPTION B: Intentionally break running service

# 1. Deploy a normal version
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live
  ... (full params)

# 2. While soak test is running, break the health endpoint:
docker exec srv-captain--qwickapps-mcp-live \
  curl -X POST http://localhost:3000/admin/break-health

# 3. OR: Manually kill the container or API process

# 4. Observe soak test detects failure and triggers rollback
```

**Success Criteria:**
- ✅ All 24 probes succeed on healthy deployment
- ✅ Any single probe failure triggers auto-rollback
- ✅ Auto-rollback completes successfully
- ✅ GitHub incident issue created
- ✅ Service never unavailable (fallback slot takes traffic)

---

## Gate 3: Auto-Rollback & Incident Creation

**What it does:** Automatically revert failed deployment and create GitHub incident.

**Why it matters:** Provides automatic recovery + clear audit trail for post-mortem.

### Test Procedure

**Prerequisites:**
- Previous test (Gate 2 failure path) already creates an incident
- Or manually trigger auto-rollback for testing

**Test: Manual auto-rollback trigger**

```bash
# 1. Put service in failed state
docker stop srv-captain--qwickapps-mcp-live
# or make /health return HTTP 500

# 2. Trigger auto-rollback manually
chmod +x .ci-workflows/scripts/auto-rollback.sh
.ci-workflows/scripts/auto-rollback.sh \
  --app-name qwickapps-mcp \
  --from-slot qwickapps-mcp-live \
  --to-slot qwickapps-mcp-stable \
  --reason "Test: Manual rollback trigger" \
  --caprover-url https://oci-main \
  --caprover-password "$CAPROVER_PASSWORD" \
  --github-token "$GH_TOKEN" \
  --create-issue

# 3. Expected output:
# ========================================
# 🔄 AUTOMATIC ROLLBACK IN PROGRESS
#   App: qwickapps-mcp
#   From: qwickapps-mcp-live (failed)
#   To: qwickapps-mcp-stable (previous stable)
#   Reason: Test: Manual rollback trigger
# ========================================
# 
# Step 1: Authenticating with CapRover...
# ✓ Authenticated
# 
# Step 2: Verifying failed slot state...
# ✓ From-slot exists: qwickapps-mcp-live
# 
# Step 3: Verifying fallback slot state...
# ✓ To-slot exists: qwickapps-mcp-stable
# ✓ To-slot is healthy (HTTP 200)
# 
# Step 4: Reverting traffic to fallback slot...
# ✓ Traffic reverted (via LB update)
# 
# Step 5: Verifying rollback convergence...
# ✓ Traffic restored to qwickapps-mcp-stable
# 
# Step 6: Creating incident issue...
# ✓ Incident issue created
# 
# ✅ ROLLBACK COMPLETE

# 4. Verify incident was created
gh issue list -R qwickapps/crew | head -5
# Expected: New issue "[INCIDENT] Auto-rollback: qwickapps-mcp deployment failed"

# 5. Check incident content
gh issue view <ISSUE_NUMBER> -R qwickapps/crew
# Expected fields:
# - Title: [INCIDENT] Auto-rollback: qwickapps-mcp deployment failed
# - Body includes: timestamp, service, failure reason, timeline, next steps
# - Labels: incident, auto-rollback, qwickapps-mcp
```

**Success Criteria:**
- ✅ Auto-rollback completes without errors
- ✅ Traffic reverted to stable slot
- ✅ GitHub incident created with full details
- ✅ Service restored (health check passes)

---

## Full End-to-End Test

**Scenario:** Deploy a service through all gates with intentional failure

```bash
# STEP 1: Verify baseline
curl -s https://qwickapps-mcp.taile324e7.ts.net/health | jq .ok
# Expected: true

# STEP 2: Deploy broken version
gh workflow run deploy-app.yml \
  -R qwickapps/ci-workflows \
  -f app_name=qwickapps-mcp \
  -f environment=prod \
  -f stage=live \
  -f image_ref=ghcr.io/qwickapps/img-mcp:broken-e2e-test \
  -f container_port=8000 \
  -f health_path=/health \
  -f caprover_host=captain.oci-main \
  -f dockerfile_path=Dockerfile \
  -f package_json_path=package.json

# STEP 3: Monitor workflow execution
gh run watch <RUN_ID>

# Expected timeline:
# ✅ 0:00  Checkout code
# ✅ 0:10  Pre-deploy gate (backup health) — PASS
# ✅ 1:30  Build image
# ✅ 3:00  Verify image exists
# ✅ 3:15  Deploy to live slot
# ✅ 4:00  Validate health
# ✅ 5:15  Soak test starts
# ✓ 5:15  Probe 1: OK
# ✓ 5:20  Probe 2: OK
# ✓ 5:25  Probe 3: OK
# ✗ 5:30  Probe 4: FAIL (HTTP 503)
# ❌ 5:35  Soak test FAILED
# 🔄 5:40  Auto-rollback triggered
# ✅ 6:00  Rollback complete
# ⚠️  6:05  Incident created
# ❌ 6:10  Workflow overall: FAILED

# STEP 4: Verify service is restored
curl -s https://qwickapps-mcp.taile324e7.ts.net/health | jq .ok
# Expected: true (traffic on stable slot, which is healthy)

# STEP 5: Check incident
gh issue list -R qwickapps/crew | grep "Auto-rollback"
# Expected: Incident created with full details

# STEP 6: Cleanup
# Fix the bug in the app
# Rebuild the image
# Retry deploy
```

---

## Running Tests in CI

All these tests can be automated in CI:

**File:** `.github/workflows/test-deployment-gates.yml`

```yaml
name: Test Deployment Gates

on:
  workflow_dispatch:
  schedule:
    - cron: '0 2 * * 1'  # Monday 2 AM UTC

jobs:
  test-gates:
    runs-on: [self-hosted, macmini]
    steps:
      - uses: actions/checkout@v4
      - name: Test pre-deploy gate
        run: ./scripts/test-pre-deploy-gate.sh
      - name: Test soak test (success case)
        run: ./scripts/test-soak-success.sh
      - name: Test soak test (failure + rollback)
        run: ./scripts/test-soak-failure-rollback.sh
      - name: Report results
        run: ./scripts/report-gate-test-results.sh
```

---

## Verification Checklist

After each gate test, verify:

| Item | Command | Expected |
|------|---------|----------|
| Pre-deploy gate blocks unhealthy backup | Deploy with backup down | ❌ REFUSED |
| Pre-deploy gate allows healthy backup | Deploy with backup up | ✅ PASSED |
| Soak test passes on healthy service | Deploy normal image | ✅ All 24 probes OK |
| Soak test fails on broken service | Deploy broken image | ✗ First failure detected |
| Auto-rollback reverts traffic | Monitor health endpoint | ✅ Traffic to stable |
| Auto-rollback creates incident | List GitHub issues | ✅ Incident created |
| Service never unavailable | Monitor with `watch curl` | ✅ Always responds |

---

## Troubleshooting

**Q: Pre-deploy gate says backup slot not found**
- A: Verify the stable slot exists: `curl https://[app]-stable.taile324e7.ts.net/health`
- A: Check slot name matches expected pattern: `[app]-stable`

**Q: Soak test times out**
- A: Increase timeout: `--timeout 20` (default 10s)
- A: Check if health endpoint is slow: `time curl https://[app]-live.taile324e7.ts.net/health`

**Q: Auto-rollback fails to create incident**
- A: Verify GitHub token is valid: `gh auth status`
- A: Check if GitHub API is reachable: `curl https://api.github.com`
- A: Incident creation is best-effort; rollback succeeds even if issue creation fails

**Q: Traffic doesn't revert during rollback**
- A: Verify load balancer is responsive: `curl https://qwickway/health`
- A: Check if stable slot is truly healthy: `curl https://[app]-stable.taile324e7.ts.net/health`
- A: Rollback is still recorded even if LB update fails

---

## Next Steps

1. Run all gate tests manually (this document)
2. Automate tests in CI (test-deployment-gates.yml)
3. Run weekly automated gate validation
4. Collect metrics on auto-rollback triggers (should be rare)
5. Iterate on thresholds based on real deployments

---

## References

- crew#24: Blue-green migration + auto-rollback
- crew#21: MCP deploy failure (incident that prompted this)
- Scripts:
  - `scripts/check-backup-slot-health.sh` — Pre-deploy gate
  - `scripts/soak-test.sh` — Post-cutover gate
  - `scripts/auto-rollback.sh` — Automatic recovery
