#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "design-conform" / "design_conform.py"
SPEC = importlib.util.spec_from_file_location("design_conform", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DesignConformUnitTests(unittest.TestCase):
    def test_yaml_subset_parses_nested_screen_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "design-conform.yml"
            path.write_text(
                """baseline:
  path: design/approved/home.html
  sha256: abc123
target: https://example.test
mask:
  - .clock
screens:
  - id: home
    artifact_route: '#mockups'
    target_path: /
    regions:
      - name: hero
        artifact_selector: '#hero'
        target_selector: main .hero
viewports:
  - 1440x900
  - width: 390
    height: 844
theme: [light, dark]
threshold: 0.03
""",
                encoding="utf-8",
            )
            manifest = MODULE.load_manifest(path)
        self.assertEqual(manifest["screens"][0]["regions"][0]["name"], "hero")
        self.assertEqual(manifest["viewports"][1], {"width": 390, "height": 844})
        self.assertEqual(manifest["theme"], ["light", "dark"])

    def test_png_round_trip_and_diff(self) -> None:
        left = MODULE.Image(2, 1, bytes((0, 0, 0, 255, 255, 255, 255, 255)))
        right = MODULE.Image(2, 1, bytes((0, 0, 0, 255, 255, 0, 255, 255)))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.png"
            MODULE.write_png(path, left)
            decoded = MODULE.read_png(path)
        self.assertEqual(decoded, left)
        ratio, diff, changed, total = MODULE.compare_images(left, right, 0.1)
        self.assertEqual((changed, total), (1, 2))
        self.assertEqual(ratio, 0.5)
        self.assertEqual((diff.width, diff.height), (2, 1))

    def test_text_normalization_and_similarity(self) -> None:
        self.assertEqual(MODULE.normalize_text("  Hello\n WORLD "), "hello world")
        self.assertEqual(MODULE.text_similarity("Hello world", " hello   WORLD "), 1.0)

    def test_only_raaj_linked_exceptions_are_honored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "home.exceptions.md"
            path.write_text(
                """# Approved deviations
hero | CMS image differs | approved by @raaj https://example.test/approval/1
footer | developer preference | no approval
""",
                encoding="utf-8",
            )
            exceptions = MODULE.load_exceptions(path)
        self.assertIn("hero", exceptions)
        self.assertNotIn("footer", exceptions)

    def test_validate_manifest_rejects_baseline_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "approved.html"
            baseline.write_text("<main>approved</main>", encoding="utf-8")
            manifest = {
                "baseline": {"path": "approved.html", "sha256": "0" * 64},
                "target": "https://example.test",
                "screens": [{
                    "id": "home",
                    "regions": [{"name": "main", "artifact_selector": "main", "target_selector": "main"}],
                }],
            }
            with self.assertRaises(MODULE.ToolError):
                MODULE.validate_manifest(manifest, root)


class _FixtureHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass

    def do_GET(self) -> None:
        if self.path == "/api/health":
            body = json.dumps({"gitSha": "fixture-sha-123"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


@unittest.skipUnless(os.environ.get("DESIGN_CONFORM_BROWSER_TEST") == "1", "browser integration test not requested")
class DesignConformBrowserTests(unittest.TestCase):
    def test_identical_page_passes_and_changed_style_fails(self) -> None:
        approved = """<!doctype html><html><head><style>
body{margin:0;font-family:Arial,sans-serif;background:rgb(255,255,255);color:rgb(0,0,0)}
main{background:rgb(255,255,255);color:rgb(0,0,0);padding:24px;width:500px}
button{background:rgb(0,100,200);color:white;border:0;padding:8px}
</style></head><body><main><h1>Approved heading</h1><nav>Primary</nav><p>Exact approved copy.</p><button>Buy now</button></main></body></html>"""
        changed = approved.replace("rgb(255,255,255);color:rgb(0,0,0);padding", "rgb(255,0,255);color:rgb(0,0,0);padding")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "approved.html"
            target = root / "index.html"
            baseline.write_text(approved, encoding="utf-8")
            target.write_text(approved, encoding="utf-8")
            handler = lambda *args, **kwargs: _FixtureHandler(*args, directory=str(root), **kwargs)
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                port = server.server_address[1]
                manifest = root / "design-conform.yml"
                manifest.write_text(
                    json.dumps({
                        "baseline": {
                            "path": "approved.html",
                            "sha256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
                        },
                        "target": f"http://127.0.0.1:{port}",
                        "viewports": ["800x600"],
                        "theme": ["light"],
                        "screens": [{
                            "id": "home",
                            "target_path": "/",
                            "regions": [{"name": "main", "artifact_selector": "main", "target_selector": "main"}],
                        }],
                    }),
                    encoding="utf-8",
                )
                passing_output = root / "passing-report"
                self.assertEqual(MODULE.main(["--manifest", str(manifest), "--output", str(passing_output)]), 0)
                passing_report = json.loads((passing_output / "report.json").read_text())
                self.assertEqual(passing_report["verdict"], "PASS")
                self.assertEqual(passing_report["targetGitSha"], "fixture-sha-123")

                target.write_text(changed, encoding="utf-8")
                failing_output = root / "failing-report"
                self.assertEqual(MODULE.main(["--manifest", str(manifest), "--output", str(failing_output)]), 1)
                failing_report = json.loads((failing_output / "report.json").read_text())
                self.assertEqual(failing_report["verdict"], "FAIL")
                self.assertFalse(failing_report["runs"][0]["regions"][0]["stylePass"])
            finally:
                server.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
