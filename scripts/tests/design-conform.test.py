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
        self.assertLess(MODULE.text_similarity("Festive Flash sale today", "Style Atelier collection"), 0.95)

    @staticmethod
    def _solid(width: int, height: int, rgba: tuple[int, int, int, int]) -> "MODULE.Image":
        return MODULE.Image(width, height, bytes(rgba) * (width * height))

    def test_pixelmatch_identical_and_perceptual_threshold(self) -> None:
        white = self._solid(4, 4, (255, 255, 255, 255))
        ratio, diff, changed, total = MODULE.compare_images(white, white, 0.1)
        self.assertEqual((ratio, changed, total), (0.0, 0, 16))
        self.assertEqual((diff.width, diff.height), (4, 4))
        # a 2-level grey shift is below pixelmatch's YIQ threshold; red vs white is not
        near_white = self._solid(4, 4, (253, 253, 253, 255))
        self.assertEqual(MODULE.compare_images(white, near_white, 0.1)[2], 0)
        red = self._solid(4, 4, (255, 0, 0, 255))
        self.assertEqual(MODULE.compare_images(white, red, 0.1)[2], 16)
        # threshold 0 counts any change
        self.assertEqual(MODULE.compare_images(white, near_white, 0.0)[2], 16)

    def test_pixelmatch_color_delta_matches_reference_values(self) -> None:
        black = bytes((0, 0, 0, 255))
        white = bytes((255, 255, 255, 255))
        # pixelmatch: black->white YIQ delta is ~ the 35215 normaliser and negative when img1 is brighter
        self.assertAlmostEqual(MODULE.color_delta(black, white, 0, 0), 32857.4, delta=1.0)
        self.assertLess(MODULE.color_delta(white, black, 0, 0), 0)
        # transparent pixels blend with white
        self.assertEqual(MODULE.color_delta(bytes((0, 0, 0, 0)), white, 0, 0), 0.0)

    def test_pixelmatch_ignores_antialiased_edge_pixels(self) -> None:
        # A hard black/white vertical edge; the target softens one edge pixel to grey,
        # which is exactly the font-smoothing noise pixelmatch classifies as anti-aliasing.
        width, height = 6, 6
        rows = [[(0, 0, 0, 255)] * 3 + [(255, 255, 255, 255)] * 3 for _ in range(height)]
        base = MODULE.Image(width, height, bytes(c for row in rows for px in row for c in px))
        rows[2][3] = (128, 128, 128, 255)
        softened = MODULE.Image(width, height, bytes(c for row in rows for px in row for c in px))
        _, diff, changed, _ = MODULE.compare_images(base, softened, 0.1)
        self.assertEqual(changed, 0)
        pos = (2 * width + 3) * 4
        self.assertEqual(tuple(diff.rgba[pos : pos + 4]), (*MODULE.AA_COLOR, 255))

    def test_size_mismatch_counts_missing_area_as_changed(self) -> None:
        small = self._solid(2, 2, (10, 10, 10, 255))
        large = self._solid(2, 4, (10, 10, 10, 255))
        ratio, diff, changed, total = MODULE.compare_images(small, large, 0.1)
        self.assertEqual((changed, total, ratio), (4, 8, 0.5))
        self.assertEqual((diff.width, diff.height), (2, 4))

    def test_structure_comparator_reports_first_mismatch(self) -> None:
        artifact = {"headings": ["h1:festive flash", "h2:deals"], "landmarks": ["header", "main", "footer"]}
        self.assertTrue(MODULE.compare_structure(artifact, dict(artifact))["pass"])
        reordered = {"headings": ["h2:deals", "h1:festive flash"], "landmarks": ["header", "main", "footer"]}
        result = MODULE.compare_structure(artifact, reordered)
        self.assertFalse(result["pass"])
        self.assertFalse(result["headingsMatch"])
        self.assertTrue(result["landmarksMatch"])
        self.assertEqual(result["firstMismatch"]["headings"], {"index": 0, "artifact": "h1:festive flash", "target": "h2:deals"})
        truncated = {"headings": artifact["headings"], "landmarks": ["header", "main"]}
        mismatch = MODULE.compare_structure(artifact, truncated)["firstMismatch"]["landmarks"]
        self.assertEqual(mismatch, {"index": 2, "artifact": "footer", "target": None})

    def test_style_comparator_normalizes_and_detects_changes(self) -> None:
        artifact = {
            "root_background": "rgb(255, 255, 255)",
            "root_color": "rgb(0, 0, 0)",
            "h1_font_family": '"Playfair Display", serif',
            "body_font_family": "Inter, sans-serif",
            "primary_button_background": "rgb(200, 30, 60)",
        }
        equivalent = {
            "root_background": "rgba(255,255,255,1)",
            "root_color": "rgb(0,0,0)",
            "h1_font_family": "'Playfair Display',serif",
            "body_font_family": "inter, sans-serif",
            "primary_button_background": "rgb(200, 30, 60)",
        }
        self.assertEqual(MODULE.compare_styles(artifact, equivalent), {"pass": True, "mismatches": {}})
        changed = dict(equivalent, h1_font_family="Cormorant, serif", primary_button_background="rgb(20, 20, 20)")
        result = MODULE.compare_styles(artifact, changed)
        self.assertFalse(result["pass"])
        self.assertEqual(set(result["mismatches"]), {"h1_font_family", "primary_button_background"})
        # a missing button on the target is a mismatch, not a silent pass
        self.assertFalse(MODULE.compare_styles(artifact, dict(equivalent, primary_button_background=None))["pass"])

    def test_cli_accepts_out_and_exits_2_on_tool_error(self) -> None:
        self.assertEqual(MODULE.parse_args(["--out", "x"]).output, Path("x"))
        self.assertEqual(MODULE.parse_args(["--output", "y"]).output, Path("y"))
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "absent.yml"
            self.assertEqual(MODULE.main(["--manifest", str(missing), "--out", directory]), 2)

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
