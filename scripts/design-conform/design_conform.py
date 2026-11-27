#!/usr/bin/env python3
"""Fail-closed visual and structural conformance checker for approved HTML.

The only runtime dependency is Playwright. PNG decoding, pixel comparison,
manifest parsing, reporting, and health probing use the Python standard library.
"""
from __future__ import annotations

import argparse
import ast
import difflib
import html
import json
import math
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

TOOL_VERSION = "1.1.0"
DEFAULT_VIEWPORTS = ((1440, 900), (390, 844))
LANDMARK_SELECTOR = "header,nav,main,aside,footer,section,article,[role=main],[role=navigation],[role=banner],[role=contentinfo],[role=complementary]"
PRIMARY_BUTTON_SELECTOR = "button,[role=button],input[type=submit],a.button,a.btn"


class ToolError(RuntimeError):
    """An environmental, configuration, or execution error (exit 2)."""


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    rgba: bytes


def _strip_yaml_comment(line: str) -> str:
    quote: str | None = None
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote == '"':
            escaped = True
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            continue
        if char == "#" and quote is None and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line


def _split_inline(value: str) -> list[str]:
    parts: list[str] = []
    quote: str | None = None
    depth = 0
    start = 0
    for index, char in enumerate(value):
        if char in ("'", '"'):
            quote = None if quote == char else char if quote is None else quote
        elif quote is None:
            if char in "[({":
                depth += 1
            elif char in "])}":
                depth -= 1
            elif char == "," and depth == 0:
                parts.append(value[start:index].strip())
                start = index + 1
    parts.append(value[start:].strip())
    return [part for part in parts if part]


def _parse_scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return None
    lowered = value.lower()
    if lowered in {"null", "~"}:
        return None
    if lowered in {"true", "false"}:
        return lowered == "true"
    if re.fullmatch(r"[-+]?\d+", value):
        return int(value)
    if re.fullmatch(r"[-+]?(\d+\.\d*|\d*\.\d+)([eE][-+]?\d+)?", value):
        return float(value)
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        return [_parse_scalar(part) for part in _split_inline(inner)] if inner else []
    if value.startswith("{") and value.endswith("}"):
        inner = value[1:-1].strip()
        if not inner:
            return {}
        return {key: _parse_scalar(raw) for key, raw in (_split_key_value(part) for part in _split_inline(inner))}
    if value[0] in "(['\"":
        try:
            return json.loads(value)
        except (json.JSONDecodeError, TypeError):
            try:
                return ast.literal_eval(value)
            except (ValueError, SyntaxError):
                pass
    return value


def _split_key_value(text: str) -> tuple[str, str]:
    quote: str | None = None
    depth = 0
    for index, char in enumerate(text):
        if char in ("'", '"'):
            quote = None if quote == char else char if quote is None else quote
        elif quote is None:
            if char in "[({":
                depth += 1
            elif char in "])}":
                depth -= 1
            elif char == ":" and depth == 0:
                key = text[:index].strip()
                if not key:
                    break
                return key, text[index + 1 :].strip()
    raise ToolError(f"invalid manifest mapping entry: {text!r}")


def _tokenize_yaml(text: str) -> list[tuple[int, str]]:
    tokens: list[tuple[int, str]] = []
    for number, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise ToolError(f"manifest line {number}: tabs are not valid indentation")
        clean = _strip_yaml_comment(raw).rstrip()
        if not clean.strip() or clean.lstrip().startswith("---"):
            continue
        indent = len(clean) - len(clean.lstrip(" "))
        tokens.append((indent, clean.strip()))
    return tokens


def _parse_yaml_block(tokens: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    if index >= len(tokens) or tokens[index][0] < indent:
        return {}, index
    is_list = tokens[index][0] == indent and tokens[index][1].startswith("-")
    container: Any = [] if is_list else {}
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise ToolError(f"unexpected manifest indentation near {text!r}")
        if is_list:
            if not text.startswith("-"):
                break
            item_text = text[1:].strip()
            index += 1
            if not item_text:
                if index >= len(tokens) or tokens[index][0] <= indent:
                    container.append(None)
                else:
                    child, index = _parse_yaml_block(tokens, index, tokens[index][0])
                    container.append(child)
                continue
            if ":" in item_text:
                key, raw_value = _split_key_value(item_text)
                item: dict[str, Any] = {}
                if raw_value:
                    item[key] = _parse_scalar(raw_value)
                elif index < len(tokens) and tokens[index][0] > indent:
                    child, index = _parse_yaml_block(tokens, index, tokens[index][0])
                    item[key] = child
                else:
                    item[key] = None
                if index < len(tokens) and tokens[index][0] > indent:
                    continuation_indent = tokens[index][0]
                    continuation, index = _parse_yaml_block(tokens, index, continuation_indent)
                    if not isinstance(continuation, dict):
                        raise ToolError(f"list mapping continuation for {key!r} must be a mapping")
                    item.update(continuation)
                container.append(item)
            else:
                container.append(_parse_scalar(item_text))
        else:
            if text.startswith("-"):
                break
            key, raw_value = _split_key_value(text)
            index += 1
            if raw_value:
                container[key] = _parse_scalar(raw_value)
            elif index < len(tokens) and tokens[index][0] > indent:
                child, index = _parse_yaml_block(tokens, index, tokens[index][0])
                container[key] = child
            else:
                container[key] = None
    return container, index


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ToolError(f"cannot read manifest {path}: {exc}") from exc
    try:
        document = json.loads(text)
    except json.JSONDecodeError:
        tokens = _tokenize_yaml(text)
        document, consumed = _parse_yaml_block(tokens, 0, tokens[0][0] if tokens else 0)
        if consumed != len(tokens):
            raise ToolError("manifest parser did not consume the complete document")
    if not isinstance(document, dict):
        raise ToolError("manifest root must be a mapping")
    return document


def sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
    return (left, up, upper_left)[distances.index(min(distances))]


def read_png(path: Path) -> Image:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ToolError(f"not a PNG file: {path}")
    offset = 8
    width = height = color_type = bit_depth = interlace = None
    compressed = bytearray()
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            break
    if None in (width, height, color_type, bit_depth, interlace):
        raise ToolError(f"PNG has no valid IHDR: {path}")
    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ToolError(f"unsupported PNG format in {path}: depth={bit_depth} color={color_type} interlace={interlace}")
    channels = 4 if color_type == 6 else 3
    stride = width * channels
    try:
        raw = zlib.decompress(bytes(compressed))
    except zlib.error as exc:
        raise ToolError(f"invalid PNG compression in {path}: {exc}") from exc
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ToolError(f"invalid PNG payload size in {path}: expected {expected}, got {len(raw)}")
    rows: list[bytearray] = []
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        encoded = raw[cursor + 1 : cursor + stride + 1]
        cursor += stride + 1
        row = bytearray(stride)
        previous = rows[-1] if rows else bytearray(stride)
        for index, value in enumerate(encoded):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                decoded = value
            elif filter_type == 1:
                decoded = value + left
            elif filter_type == 2:
                decoded = value + up
            elif filter_type == 3:
                decoded = value + ((left + up) // 2)
            elif filter_type == 4:
                decoded = value + _paeth(left, up, upper_left)
            else:
                raise ToolError(f"unsupported PNG filter {filter_type} in {path}")
            row[index] = decoded & 0xFF
        rows.append(row)
    rgba = bytearray(width * height * 4)
    output = 0
    for row in rows:
        for index in range(0, len(row), channels):
            rgba[output : output + 3] = row[index : index + 3]
            rgba[output + 3] = row[index + 3] if channels == 4 else 255
            output += 4
    return Image(width, height, bytes(rgba))


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def write_png(path: Path, image: Image) -> None:
    if len(image.rgba) != image.width * image.height * 4:
        raise ToolError("invalid RGBA buffer length")
    scanlines = bytearray()
    stride = image.width * 4
    for row in range(image.height):
        scanlines.append(0)
        start = row * stride
        scanlines.extend(image.rgba[start : start + stride])
    payload = b"\x89PNG\r\n\x1a\n"
    payload += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0))
    payload += _png_chunk(b"IDAT", zlib.compress(bytes(scanlines), 9))
    payload += _png_chunk(b"IEND", b"")
    path.write_bytes(payload)


# --- pixelmatch port -------------------------------------------------------
# Pure-Python port of mapbox/pixelmatch (ISC licence): perceptual YIQ colour
# delta with a squared-threshold cut-off and anti-aliasing detection, so that
# font-smoothing noise is not reported as a design difference.

PIXELMATCH_MAX_DELTA = 35215.0  # maximum possible YIQ delta value
DIFF_COLOR = (255, 0, 0)
AA_COLOR = (255, 255, 0)


def _blend(channel: float, alpha: float) -> float:
    # blend semi-transparent colour with white, as pixelmatch does
    return 255.0 + (channel - 255.0) * alpha


def _rgb2y(r: float, g: float, b: float) -> float:
    return r * 0.29889531 + g * 0.58662247 + b * 0.11448223


def _rgb2i(r: float, g: float, b: float) -> float:
    return r * 0.59597799 - g * 0.27417610 - b * 0.32180189


def _rgb2q(r: float, g: float, b: float) -> float:
    return r * 0.21147017 - g * 0.52261711 + b * 0.31114694


def color_delta(img1: bytes, img2: bytes, k: int, m: int, y_only: bool = False) -> float:
    """Signed squared YIQ distance between pixel k of img1 and pixel m of img2."""
    r1, g1, b1, a1 = img1[k], img1[k + 1], img1[k + 2], img1[k + 3]
    r2, g2, b2, a2 = img2[m], img2[m + 1], img2[m + 2], img2[m + 3]
    if a1 == a2 and r1 == r2 and g1 == g2 and b1 == b2:
        return 0.0
    fr1, fg1, fb1 = float(r1), float(g1), float(b1)
    fr2, fg2, fb2 = float(r2), float(g2), float(b2)
    if a1 < 255:
        alpha = a1 / 255.0
        fr1, fg1, fb1 = _blend(fr1, alpha), _blend(fg1, alpha), _blend(fb1, alpha)
    if a2 < 255:
        alpha = a2 / 255.0
        fr2, fg2, fb2 = _blend(fr2, alpha), _blend(fg2, alpha), _blend(fb2, alpha)
    y1 = _rgb2y(fr1, fg1, fb1)
    y2 = _rgb2y(fr2, fg2, fb2)
    y = y1 - y2
    if y_only:
        return y
    i = _rgb2i(fr1, fg1, fb1) - _rgb2i(fr2, fg2, fb2)
    q = _rgb2q(fr1, fg1, fb1) - _rgb2q(fr2, fg2, fb2)
    delta = 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q
    return -delta if y1 > y2 else delta


def _has_many_siblings(img: bytes, x1: int, y1: int, width: int, height: int) -> bool:
    x0, y0 = max(x1 - 1, 0), max(y1 - 1, 0)
    x2, y2 = min(x1 + 1, width - 1), min(y1 + 1, height - 1)
    pos = (y1 * width + x1) * 4
    zeroes = 1 if x1 == x0 or x1 == x2 or y1 == y0 or y1 == y2 else 0
    here = img[pos : pos + 4]
    for x in range(x0, x2 + 1):
        for y in range(y0, y2 + 1):
            if x == x1 and y == y1:
                continue
            pos2 = (y * width + x) * 4
            if img[pos2 : pos2 + 4] == here:
                zeroes += 1
            if zeroes > 2:
                return True
    return False


def antialiased(img: bytes, x1: int, y1: int, width: int, height: int, img2: bytes) -> bool:
    """pixelmatch's anti-aliasing heuristic (Vysniauskas 2009)."""
    x0, y0 = max(x1 - 1, 0), max(y1 - 1, 0)
    x2, y2 = min(x1 + 1, width - 1), min(y1 + 1, height - 1)
    pos = (y1 * width + x1) * 4
    zeroes = 1 if x1 == x0 or x1 == x2 or y1 == y0 or y1 == y2 else 0
    min_delta = max_delta = 0.0
    min_x = min_y = max_x = max_y = 0
    for x in range(x0, x2 + 1):
        for y in range(y0, y2 + 1):
            if x == x1 and y == y1:
                continue
            delta = color_delta(img, img, pos, (y * width + x) * 4, True)
            if delta == 0:
                zeroes += 1
                if zeroes > 2:
                    return False
            elif delta < min_delta:
                min_delta, min_x, min_y = delta, x, y
            elif delta > max_delta:
                max_delta, max_x, max_y = delta, x, y
    if min_delta == 0 or max_delta == 0:
        return False
    return (
        _has_many_siblings(img, min_x, min_y, width, height) and _has_many_siblings(img2, min_x, min_y, width, height)
    ) or (
        _has_many_siblings(img, max_x, max_y, width, height) and _has_many_siblings(img2, max_x, max_y, width, height)
    )


def _crop(image: Image, width: int, height: int) -> bytes:
    if image.width == width and image.height == height:
        return image.rgba
    row = image.width * 4
    return b"".join(image.rgba[y * row : y * row + width * 4] for y in range(height))


def pixelmatch(
    img1: bytes,
    img2: bytes,
    width: int,
    height: int,
    threshold: float = 0.1,
    include_aa: bool = False,
    alpha: float = 0.1,
) -> tuple[int, bytearray]:
    """Return (mismatched pixel count, RGBA diff image) like pixelmatch()."""
    if len(img1) != len(img2) or len(img1) != width * height * 4:
        raise ValueError("image sizes do not match")
    max_delta = PIXELMATCH_MAX_DELTA * threshold * threshold
    output = bytearray(width * height * 4)
    diff = 0
    row_bytes = width * 4
    for y in range(height):
        row_start = y * row_bytes
        same_row = img1[row_start : row_start + row_bytes] == img2[row_start : row_start + row_bytes]
        for x in range(width):
            pos = row_start + x * 4
            delta = 0.0 if same_row else color_delta(img1, img2, pos, pos)
            if abs(delta) > max_delta:
                if not include_aa and (
                    antialiased(img1, x, y, width, height, img2) or antialiased(img2, x, y, width, height, img1)
                ):
                    output[pos : pos + 4] = bytes((*AA_COLOR, 255))
                else:
                    output[pos : pos + 4] = bytes((*DIFF_COLOR, 255))
                    diff += 1
            else:
                r, g, b, a = img1[pos], img1[pos + 1], img1[pos + 2], img1[pos + 3]
                grey = _rgb2y(r, g, b)
                value = int(round(_blend(grey, alpha * a / 255.0)))
                output[pos : pos + 4] = bytes((value, value, value, 255))
    return diff, output


def compare_images(baseline: Image, target: Image, threshold: float) -> tuple[float, Image, int, int]:
    """Masked-region diff ratio using pixelmatch over the common area.

    Pixels that exist in only one image (size mismatch) always count as changed,
    so a region that grew or shrank can never pass silently.
    """
    width = max(baseline.width, target.width)
    height = max(baseline.height, target.height)
    common_w = min(baseline.width, target.width)
    common_h = min(baseline.height, target.height)
    total = width * height
    if total == 0:
        return 0.0, Image(0, 0, b""), 0, 0
    changed, common_diff = (0, bytearray())
    if common_w and common_h:
        changed, common_diff = pixelmatch(
            _crop(baseline, common_w, common_h), _crop(target, common_w, common_h), common_w, common_h, threshold
        )
    output = bytearray(bytes((*DIFF_COLOR, 255)) * total)
    for y in range(common_h):
        output[y * width * 4 : y * width * 4 + common_w * 4] = common_diff[y * common_w * 4 : (y + 1) * common_w * 4]
    changed += total - common_w * common_h
    return changed / total, Image(width, height, bytes(output)), changed, total


def _normalize_font_family(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    return ",".join(part.strip().strip("'\"").casefold() for part in value.split(",") if part.strip())


def _normalize_color(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    compact = re.sub(r"\s+", "", value.casefold())
    match = re.fullmatch(r"rgba\((\d+),(\d+),(\d+),(1|1\.0+)\)", compact)
    if match:
        return f"rgb({match.group(1)},{match.group(2)},{match.group(3)})"
    if compact in {"transparent", "rgba(0,0,0,0)"}:
        return "rgba(0,0,0,0)"
    return compact


def compare_structure(artifact: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    """Ordered h1-h3 and landmark comparison; reports the first divergence."""
    result: dict[str, Any] = {"pass": True}
    for key in ("headings", "landmarks"):
        left = list(artifact.get(key) or [])
        right = list(target.get(key) or [])
        match = left == right
        result[f"{key}Match"] = match
        if not match:
            result["pass"] = False
            index = next((i for i, (a, b) in enumerate(zip(left, right)) if a != b), min(len(left), len(right)))
            result.setdefault("firstMismatch", {})[key] = {
                "index": index,
                "artifact": left[index] if index < len(left) else None,
                "target": right[index] if index < len(right) else None,
            }
    return result


STYLE_NORMALIZERS = {
    "root_background": _normalize_color,
    "root_color": _normalize_color,
    "primary_button_background": _normalize_color,
    "h1_font_family": _normalize_font_family,
    "body_font_family": _normalize_font_family,
}


def compare_styles(artifact: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    """Computed-style spot checks: region bg/colour, h1/body font, primary button bg."""
    mismatches: dict[str, dict[str, Any]] = {}
    for key, normalize in STYLE_NORMALIZERS.items():
        left, right = normalize(artifact.get(key)), normalize(target.get(key))
        if left != right:
            mismatches[key] = {"artifact": artifact.get(key), "target": target.get(key)}
    return {"pass": not mismatches, "mismatches": mismatches}


def normalize_text(value: str) -> str:
    return " ".join(value.split()).casefold()


def text_similarity(left: str, right: str) -> float:
    return difflib.SequenceMatcher(None, normalize_text(left), normalize_text(right), autojunk=False).ratio()


def resolve_path(root: Path, value: str, label: str) -> Path:
    candidate = (root / value).resolve() if not Path(value).is_absolute() else Path(value).resolve()
    if not candidate.exists():
        raise ToolError(f"{label} does not exist: {candidate}")
    return candidate


def load_exceptions(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    exceptions: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip().lstrip("-* ")
        if not line or line.startswith("#") or "@raaj" not in line or not re.search(r"https?://", line):
            continue
        fields = [part.strip() for part in (line.split("|") if "|" in line else line.split(","))]
        region = fields[0].strip("` ")
        if region and region.lower() not in {"region", "---"}:
            exceptions[region] = line
    return exceptions


def probe_git_sha(target: str, health_path: str, timeout_ms: int) -> tuple[str, str]:
    url = urllib.parse.urljoin(target.rstrip("/") + "/", health_path.lstrip("/"))
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": f"design-conform/{TOOL_VERSION}"})
    try:
        with urllib.request.urlopen(request, timeout=timeout_ms / 1000) as response:
            payload = json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise ToolError(f"health probe failed at {url}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ToolError(f"health probe at {url} did not return an object")
    candidates: list[Any] = [payload.get("gitSha"), payload.get("git_sha"), payload.get("sha"), payload.get("commit")]
    build = payload.get("build")
    if isinstance(build, dict):
        candidates.extend((build.get("gitSha"), build.get("git_sha"), build.get("sha"), build.get("commit")))
    git_sha = next((str(value).strip() for value in candidates if value and str(value).strip()), "")
    if not git_sha:
        raise ToolError(f"health probe at {url} has no gitSha/git_sha/sha/commit")
    return git_sha, url


def _required_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ToolError(f"{label} must be a mapping")
    return value


def _required_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list) or not value:
        raise ToolError(f"{label} must be a non-empty list")
    return value


def validate_manifest(manifest: dict[str, Any], root: Path) -> dict[str, Any]:
    baseline_value = manifest.get("baseline")
    if isinstance(baseline_value, dict):
        baseline_path_value = baseline_value.get("path")
        expected_sha = baseline_value.get("sha256")
    else:
        baseline_path_value = baseline_value
        expected_sha = manifest.get("baseline_sha256")
    if not isinstance(baseline_path_value, str) or not isinstance(expected_sha, str):
        raise ToolError("manifest baseline must provide path and sha256")
    baseline = resolve_path(root, baseline_path_value, "baseline")
    actual_sha = sha256_file(baseline)
    if actual_sha.lower() != expected_sha.lower():
        raise ToolError(f"baseline sha256 mismatch: expected {expected_sha}, got {actual_sha}")
    target = manifest.get("target")
    if not isinstance(target, str) or not target.startswith(("http://", "https://")):
        raise ToolError("manifest target must be an http(s) base URL")
    screens = _required_list(manifest.get("screens"), "screens")
    seen_screens: set[str] = set()
    seen_regions: set[tuple[str, str]] = set()
    for screen_value in screens:
        screen = _required_mapping(screen_value, "screen")
        screen_id = screen.get("id")
        if not isinstance(screen_id, str) or not screen_id or screen_id in seen_screens:
            raise ToolError("each screen requires a unique non-empty id")
        seen_screens.add(screen_id)
        regions = _required_list(screen.get("regions"), f"screen {screen_id} regions")
        screen_masks = screen.get("mask", [])
        if isinstance(screen_masks, str):
            screen["mask"] = [screen_masks]
        elif not isinstance(screen_masks, list) or not all(isinstance(mask, str) and mask for mask in screen_masks):
            raise ToolError(f"screen {screen_id} mask must be a selector or list of selectors")
        for region_value in regions:
            region = _required_mapping(region_value, f"screen {screen_id} region")
            for key in ("name", "artifact_selector", "target_selector"):
                if not isinstance(region.get(key), str) or not region[key]:
                    raise ToolError(f"screen {screen_id} region requires {key}")
            identity = (screen_id, region["name"])
            if identity in seen_regions:
                raise ToolError(f"duplicate region {screen_id}/{region['name']}")
            seen_regions.add(identity)
    viewports: list[tuple[int, int]] = []
    for value in manifest.get("viewports", DEFAULT_VIEWPORTS):
        if isinstance(value, str) and re.fullmatch(r"\d+x\d+", value):
            width, height = (int(part) for part in value.split("x", 1))
        elif isinstance(value, dict):
            width, height = int(value.get("width", 0)), int(value.get("height", 0))
        elif isinstance(value, (list, tuple)) and len(value) == 2:
            width, height = int(value[0]), int(value[1])
        else:
            raise ToolError(f"invalid viewport {value!r}")
        if width <= 0 or height <= 0:
            raise ToolError(f"invalid viewport dimensions {width}x{height}")
        viewports.append((width, height))
    themes = manifest.get("theme", manifest.get("themes", ["default"]))
    if isinstance(themes, str):
        themes = [themes]
    if not isinstance(themes, list) or not themes or not all(isinstance(theme, str) and theme for theme in themes):
        raise ToolError("theme must be a string or non-empty list of strings")
    masks = manifest.get("mask", [])
    if isinstance(masks, str):
        masks = [masks]
    if not isinstance(masks, list) or not all(isinstance(mask, str) and mask for mask in masks):
        raise ToolError("mask must be a list of selectors")
    threshold = float(manifest.get("threshold", 0.03))
    pixel_threshold = float(manifest.get("pixel_threshold", 0.1))
    text_threshold = float(manifest.get("text_threshold", 0.95))
    if not 0 <= threshold <= 1 or not 0 <= pixel_threshold <= 1 or not 0 <= text_threshold <= 1:
        raise ToolError("thresholds must be between 0 and 1")
    exception_value = manifest.get("exceptions")
    exception_path = resolve_path(root, exception_value, "exceptions") if isinstance(exception_value, str) else baseline.with_suffix(".exceptions.md")
    return {
        **manifest,
        "baseline_path": baseline,
        "baseline_sha256": actual_sha,
        "target": target,
        "screens": screens,
        "viewports": viewports,
        "themes": themes,
        "masks": masks,
        "threshold": threshold,
        "pixel_threshold": pixel_threshold,
        "text_threshold": text_threshold,
        "exceptions_path": exception_path if exception_path.exists() else None,
    }


def _safe_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-") or "item"


def _configure_page(page: Any, theme: str, masks: Iterable[str], timeout_ms: int) -> None:
    page.wait_for_load_state("networkidle", timeout=timeout_ms)
    page.evaluate("document.fonts && document.fonts.ready")
    page.evaluate(
        """theme => {
          const root = document.documentElement;
          root.dataset.theme = theme;
          root.style.colorScheme = theme === 'default' ? '' : theme;
          root.classList.toggle('dark', theme === 'dark');
          root.classList.toggle('light', theme === 'light');
        }""",
        theme,
    )
    page.add_style_tag(content="*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important;scroll-behavior:auto!important}")
    for selector in masks:
        try:
            count = page.locator(selector).count()
        except Exception as exc:
            raise ToolError(f"invalid mask selector {selector!r}: {exc}") from exc
        if count:
            page.locator(selector).evaluate_all("els => els.forEach(el => el.style.visibility = 'hidden')")
    page.wait_for_timeout(500)


def _region_snapshot(page: Any, selector: str, path: Path) -> dict[str, Any]:
    locator = page.locator(selector)
    count = locator.count()
    if count != 1:
        raise ToolError(f"selector {selector!r} matched {count} elements; exactly one is required")
    locator.screenshot(path=str(path), animations="disabled")
    return locator.evaluate(
        """(root, args) => {
          const normalize = value => (value || '').replace(/\\s+/g, ' ').trim();
          const headings = [...root.querySelectorAll('h1,h2,h3')].map(el => `${el.tagName.toLowerCase()}:${normalize(el.innerText)}`);
          const landmarks = [...root.querySelectorAll(args.landmarks)].map(el => {
            const role = el.getAttribute('role');
            return role ? `${el.tagName.toLowerCase()}[role=${role}]` : el.tagName.toLowerCase();
          });
          const rootStyle = getComputedStyle(root);
          const h1 = root.querySelector('h1');
          const button = root.querySelector(args.button);
          return {
            headings,
            landmarks,
            text: normalize(root.innerText),
            styles: {
              root_background: rootStyle.backgroundColor,
              root_color: rootStyle.color,
              h1_font_family: h1 ? getComputedStyle(h1).fontFamily : null,
              body_font_family: getComputedStyle(document.body).fontFamily,
              primary_button_background: button ? getComputedStyle(button).backgroundColor : null,
            },
          };
        }""",
        {"landmarks": LANDMARK_SELECTOR, "button": PRIMARY_BUTTON_SELECTOR},
    )


def _screen_url(base: str, path: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def _artifact_url(path: Path, route: str) -> str:
    url = path.as_uri()
    if route:
        return url + (route if route.startswith("#") else f"#{route}")
    return url


def run_browser(config: dict[str, Any], output: Path, target_git_sha: str, health_url: str, timeout_ms: int) -> dict[str, Any]:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise ToolError("Playwright is not installed; install the playwright package and Chromium") from exc

    output.mkdir(parents=True, exist_ok=True)
    images_dir = output / "images"
    images_dir.mkdir(exist_ok=True)
    exceptions = load_exceptions(config["exceptions_path"])
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "toolVersion": TOOL_VERSION,
        "baseline": str(config["baseline_path"]),
        "baselineSha256": config["baseline_sha256"],
        "targetUrl": config["target"],
        "targetGitSha": target_git_sha,
        "healthUrl": health_url,
        "threshold": config["threshold"],
        "pixelThreshold": config["pixel_threshold"],
        "textThreshold": config["text_threshold"],
        "exceptionsFile": str(config["exceptions_path"]) if config["exceptions_path"] else None,
        "runs": [],
    }
    all_pass = True
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            for screen in config["screens"]:
                screen_id = screen["id"]
                screen_masks = [*config["masks"], *screen.get("mask", [])]
                for width, height in config["viewports"]:
                    for theme in config["themes"]:
                        run_name = _safe_name(f"{screen_id}-{width}x{height}-{theme}")
                        # dark/light themes also emulate prefers-color-scheme so
                        # media-query driven theme switches render the same way
                        color_scheme = theme if theme in {"dark", "light"} else "no-preference"
                        context = browser.new_context(
                            viewport={"width": width, "height": height}, device_scale_factor=1, color_scheme=color_scheme
                        )
                        artifact_page = context.new_page()
                        target_page = context.new_page()
                        artifact_url = _artifact_url(config["baseline_path"], str(screen.get("artifact_route", "")))
                        target_url = _screen_url(config["target"], str(screen.get("target_path", "")))
                        artifact_page.goto(artifact_url, wait_until="domcontentloaded", timeout=timeout_ms)
                        target_page.goto(target_url, wait_until="domcontentloaded", timeout=timeout_ms)
                        _configure_page(artifact_page, theme, screen_masks, timeout_ms)
                        _configure_page(target_page, theme, screen_masks, timeout_ms)
                        artifact_full = images_dir / f"{run_name}-artifact-full.png"
                        target_full = images_dir / f"{run_name}-target-full.png"
                        artifact_page.screenshot(path=str(artifact_full), full_page=True, animations="disabled")
                        target_page.screenshot(path=str(target_full), full_page=True, animations="disabled")
                        run_result: dict[str, Any] = {
                            "screen": screen_id,
                            "viewport": {"width": width, "height": height},
                            "theme": theme,
                            "artifactUrl": artifact_url,
                            "targetUrl": target_url,
                            "artifactScreenshot": str(artifact_full.relative_to(output)),
                            "targetScreenshot": str(target_full.relative_to(output)),
                            "regions": [],
                        }
                        for region in screen["regions"]:
                            region_name = region["name"]
                            qualified_name = f"{screen_id}/{region_name}"
                            exception = exceptions.get(qualified_name) or exceptions.get(region_name)
                            if exception:
                                run_result["regions"].append({"name": region_name, "excluded": True, "exception": exception, "verdict": "EXCLUDED"})
                                continue
                            prefix = _safe_name(f"{run_name}-{region_name}")
                            artifact_region_path = images_dir / f"{prefix}-artifact.png"
                            target_region_path = images_dir / f"{prefix}-target.png"
                            diff_path = images_dir / f"{prefix}-diff.png"
                            artifact_data = _region_snapshot(artifact_page, region["artifact_selector"], artifact_region_path)
                            target_data = _region_snapshot(target_page, region["target_selector"], target_region_path)
                            ratio, diff_image, changed, total = compare_images(
                                read_png(artifact_region_path), read_png(target_region_path), config["pixel_threshold"]
                            )
                            write_png(diff_path, diff_image)
                            similarity = text_similarity(artifact_data["text"], target_data["text"])
                            structure = compare_structure(artifact_data, target_data)
                            styles = compare_styles(artifact_data["styles"], target_data["styles"])
                            structure_match = structure["pass"]
                            style_match = styles["pass"]
                            pixel_pass = ratio <= config["threshold"]
                            text_pass = similarity >= config["text_threshold"]
                            verdict = "PASS" if pixel_pass and text_pass and structure_match and style_match else "FAIL"
                            if verdict != "PASS":
                                all_pass = False
                            run_result["regions"].append(
                                {
                                    "name": region_name,
                                    "excluded": False,
                                    "pixelDiffRatio": ratio,
                                    "changedPixels": changed,
                                    "totalPixels": total,
                                    "pixelPass": pixel_pass,
                                    "textSimilarity": similarity,
                                    "textPass": text_pass,
                                    "structurePass": structure_match,
                                    "stylePass": style_match,
                                    "structureDetail": structure,
                                    "styleMismatches": styles["mismatches"],
                                    "artifactStructure": {"headings": artifact_data["headings"], "landmarks": artifact_data["landmarks"]},
                                    "targetStructure": {"headings": target_data["headings"], "landmarks": target_data["landmarks"]},
                                    "artifactStyles": artifact_data["styles"],
                                    "targetStyles": target_data["styles"],
                                    "artifactScreenshot": str(artifact_region_path.relative_to(output)),
                                    "targetScreenshot": str(target_region_path.relative_to(output)),
                                    "diffScreenshot": str(diff_path.relative_to(output)),
                                    "verdict": verdict,
                                }
                            )
                        run_result["verdict"] = "PASS" if all(region["verdict"] in {"PASS", "EXCLUDED"} for region in run_result["regions"]) else "FAIL"
                        report["runs"].append(run_result)
                        context.close()
        finally:
            browser.close()
    report["verdict"] = "PASS" if all_pass else "FAIL"
    return report


def write_html_report(path: Path, report: dict[str, Any]) -> None:
    cards: list[str] = []
    for run in report["runs"]:
        regions: list[str] = []
        for region in run["regions"]:
            if region.get("excluded"):
                regions.append(f"<section class='excluded'><h3>{html.escape(region['name'])}: EXCLUDED</h3><pre>{html.escape(region['exception'])}</pre></section>")
                continue
            metrics = (
                f"pixel={region['pixelDiffRatio']:.4%} ({'PASS' if region['pixelPass'] else 'FAIL'}), "
                f"text={region['textSimilarity']:.4f} ({'PASS' if region['textPass'] else 'FAIL'}), "
                f"structure={'PASS' if region['structurePass'] else 'FAIL'}, styles={'PASS' if region['stylePass'] else 'FAIL'}"
            )
            images = "".join(
                f"<figure><img src='{html.escape(region[key])}' alt='{html.escape(label)}'><figcaption>{label}</figcaption></figure>"
                for key, label in (("artifactScreenshot", "Approved artifact"), ("targetScreenshot", "Target"), ("diffScreenshot", "Pixel diff"))
            )
            details = html.escape(json.dumps({
                "artifactStructure": region["artifactStructure"],
                "targetStructure": region["targetStructure"],
                "artifactStyles": region["artifactStyles"],
                "targetStyles": region["targetStyles"],
            }, indent=2))
            regions.append(f"<section><h3>{html.escape(region['name'])}: {region['verdict']}</h3><p>{metrics}</p><div class='images'>{images}</div><details><summary>Structure and styles</summary><pre>{details}</pre></details></section>")
        cards.append(
            f"<article><h2>{html.escape(run['screen'])} · {run['viewport']['width']}×{run['viewport']['height']} · {html.escape(run['theme'])}: {run['verdict']}</h2>"
            f"<div class='images'><figure><img src='{html.escape(run['artifactScreenshot'])}' alt='artifact full'><figcaption>Approved full page</figcaption></figure>"
            f"<figure><img src='{html.escape(run['targetScreenshot'])}' alt='target full'><figcaption>Target full page</figcaption></figure></div>{''.join(regions)}</article>"
        )
    document = f"""<!doctype html><html><head><meta charset='utf-8'><title>design-conform {report['verdict']}</title>
<style>body{{font:14px system-ui;margin:24px;background:#111;color:#eee}}article,section{{border:1px solid #444;border-radius:8px;padding:16px;margin:16px 0}}.images{{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}}img{{max-width:100%;background:#fff}}figure{{margin:0}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}.excluded{{border-color:#9b7b19}}h1{{color:{'#7ee787' if report['verdict']=='PASS' else '#ff7b72'}}}</style></head><body>
<h1>design-conform: {report['verdict']}</h1><p>Baseline SHA-256: <code>{html.escape(report['baselineSha256'])}</code><br>Target git SHA: <code>{html.escape(report['targetGitSha'])}</code><br>Tool: {html.escape(report['toolVersion'])}</p>{''.join(cards)}</body></html>"""
    path.write_text(document, encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path("design-conform.yml"))
    parser.add_argument("--out", "--output", dest="output", type=Path, default=Path("design-conform-report"))
    parser.add_argument("--target", help="override the manifest target URL")
    parser.add_argument("--timeout-ms", type=int, default=30_000)
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        manifest_path = args.manifest.resolve()
        manifest = load_manifest(manifest_path)
        if args.target:
            manifest["target"] = args.target
        config = validate_manifest(manifest, manifest_path.parent)
        if args.validate_only:
            print(json.dumps({"valid": True, "baselineSha256": config["baseline_sha256"], "screens": len(config["screens"])}, sort_keys=True))
            return 0
        output = args.output.resolve()
        target_git_sha, health_url = probe_git_sha(config["target"], str(config.get("health_path", "/api/health")), args.timeout_ms)
        report = run_browser(config, output, target_git_sha, health_url, args.timeout_ms)
        (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_html_report(output / "report.html", report)
        print(f"DESIGN CONFORM {report['verdict']} report={output / 'report.json'}")
        return 0 if report["verdict"] == "PASS" else 1
    except ToolError as exc:
        print(f"DESIGN CONFORM TOOL ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"DESIGN CONFORM TOOL ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
