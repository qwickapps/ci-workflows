# design-conform

`design-conform` compares an approved HTML artifact with a staged deployment. It fails closed on missing selectors, invalid configuration, a baseline hash mismatch, an unavailable `/api/health`, or browser/tool errors.

## Reusable workflow

```yaml
jobs:
  design:
    uses: qwickapps/ci-workflows/.github/workflows/design-conform.yml@<pinned-sha>
    with:
      manifest: design-conform.yml
      target_url: https://staging.example.com
```

The job runs only on the approved Julie x64 pool and uploads `report.json`, `report.html`, full-page screenshots, region screenshots, and diff PNGs. Outputs are `verdict`, `report_sha256`, and `target_git_sha`.

## Manifest

```yaml
baseline:
  path: design/approved/home.html
  sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
target: https://staging.example.com
health_path: /api/health
threshold: 0.03
pixel_threshold: 0.1
text_threshold: 0.95
viewports:
  - 1440x900
  - 390x844
theme: [light, dark]
mask:
  - '[data-dynamic=countdown]'
  - '.cms-image'
screens:
  - id: home
    artifact_route: '#mockups'
    target_path: /
    regions:
      - name: hero
        artifact_selector: '#hero'
        target_selector: '[data-region=hero]'
```

The baseline path is relative to the manifest. Its SHA-256 must match before Chromium starts. Each selector must match exactly one element.

For every screen, viewport, theme, and region, the tool checks:

- pixel difference at the configured per-channel and region thresholds;
- ordered `h1`-`h3` text and landmark order;
- normalized visible-text similarity;
- exact computed values for region background/color, `h1` and body font families, and primary-button background.

The target deployment must return a git identity from `/api/health` as `gitSha`, `git_sha`, `sha`, or `commit` (top-level or under `build`).

## Approved exceptions

By default, the tool reads `<baseline-name>.exceptions.md`; `exceptions:` can select another file. A line is honored only when it starts with the region name and contains both `@raaj` and an HTTP(S) approval link. Use `screen/region` when region names repeat.

## Exit codes

- `0`: every non-excluded region passes;
- `1`: conformance mismatch;
- `2`: configuration, environment, browser, selector, health, or report-generation error.

Run locally:

```bash
python3 scripts/design-conform/design_conform.py \
  --manifest design-conform.yml \
  --output design-conform-report \
  --target https://staging.example.com
```
