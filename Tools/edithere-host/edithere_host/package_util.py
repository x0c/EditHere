"""Evidence package validation and prompt helpers."""

from __future__ import annotations

import hashlib
import json
import re
import uuid
from pathlib import Path
from typing import Any, Optional


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def annotated_assets(package: dict[str, Any]) -> list[dict[str, Any]]:
    """Annotated image descriptors only — clean originals stay on the phone."""
    out: list[dict[str, Any]] = []
    for capture in package.get("captures") or []:
        if not isinstance(capture, dict):
            continue
        asset = capture.get("annotatedImage")
        if isinstance(asset, dict) and asset.get("relativePath") and asset.get("sha256"):
            out.append(asset)
    return out


def referenced_assets(package: dict[str, Any]) -> list[dict[str, Any]]:
    """Assets required for execution acceptance (annotated images only)."""
    return annotated_assets(package)


def digest_asset_keys(package: dict[str, Any], assets: dict[str, bytes]) -> list[str]:
    """
    Keys included in the content digest.

    Matches Swift `executionContentDigest` for annotated images, plus the frozen
    canonical `agent-prompt.txt` when present so prompt text is part of identity.
    """
    keys: list[str] = []
    for asset in annotated_assets(package):
        rel = str(asset["relativePath"])
        if rel in assets:
            keys.append(rel)
    if "agent-prompt.txt" in assets:
        keys.append("agent-prompt.txt")
    return sorted(keys)


def compute_content_digest(package_bytes: bytes, assets: dict[str, bytes], package: dict[str, Any]) -> str:
    """
    sha256( package_bytes + for key in sorted(asset_keys): key_utf8 + asset_bytes )
    """
    hasher = hashlib.sha256()
    hasher.update(package_bytes)
    for key in digest_asset_keys(package, assets):
        hasher.update(key.encode("utf-8"))
        hasher.update(assets[key])
    return hasher.hexdigest()


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def validate_package_schema(
    package: dict[str, Any],
    *,
    submission_id: Optional[str] = None,
) -> list[str]:
    """
    Structural validation. Returns problem strings (empty = OK).
    Raises nothing; callers may raise ValueError for hard parse failures.
    """
    problems: list[str] = []
    if not isinstance(package, dict) or not package:
        return ["package must be a non-empty JSON object"]

    schema = package.get("schemaVersion")
    if not schema or not str(schema).strip():
        problems.append("missing schemaVersion")

    pkg_id = package.get("id")
    if not pkg_id or not _is_uuid(str(pkg_id)):
        problems.append("missing or invalid id (UUID required)")
    elif submission_id is not None:
        if str(pkg_id).lower() != str(submission_id).lower():
            problems.append("submissionID does not match package.id")

    captures = package.get("captures")
    if not isinstance(captures, list) or len(captures) == 0:
        problems.append("captures must be a non-empty array")
        captures = []

    annotations = package.get("annotations")
    if not isinstance(annotations, list) or len(annotations) == 0:
        problems.append("annotations must be a non-empty array")
        annotations = []

    capture_ids: set[str] = set()
    for i, capture in enumerate(captures):
        if not isinstance(capture, dict):
            problems.append(f"captures[{i}] must be an object")
            continue
        cid = capture.get("id")
        if not cid:
            problems.append(f"captures[{i}] missing id")
        else:
            capture_ids.add(str(cid))
        annotated = capture.get("annotatedImage")
        if not isinstance(annotated, dict):
            problems.append(f"captures[{i}] missing annotatedImage")
            continue
        if not annotated.get("relativePath"):
            problems.append(f"captures[{i}].annotatedImage missing relativePath")
        sha = annotated.get("sha256")
        if not sha or not re.fullmatch(r"[0-9a-fA-F]{64}", str(sha)):
            problems.append(f"captures[{i}].annotatedImage missing or invalid sha256")

    for i, ann in enumerate(annotations):
        if not isinstance(ann, dict):
            problems.append(f"annotations[{i}] must be an object")
            continue
        cid = str(ann.get("captureID") or "")
        if not cid:
            problems.append(f"annotations[{i}] missing captureID")
        elif cid not in capture_ids:
            problems.append(f"annotations[{i}] captureID not found in captures")

    return problems


def validate_package_and_assets(
    package_bytes: bytes,
    assets: dict[str, bytes],
    *,
    submission_id: Optional[str] = None,
) -> tuple[dict[str, Any], list[str]]:
    """
    Parse package JSON, validate schema, and ensure every referenced asset is
    present with matching sha256.

    Returns (package_dict, missing_or_bad_paths). Empty list means OK.
    """
    try:
        package = json.loads(package_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid package JSON: {exc}") from exc
    if not isinstance(package, dict):
        raise ValueError("package must be a JSON object")

    problems = validate_package_schema(package, submission_id=submission_id)
    if problems:
        return package, problems

    for asset in referenced_assets(package):
        rel = str(asset["relativePath"])
        expected = str(asset["sha256"]).lower()
        if ".." in Path(rel).parts or rel.startswith(("/", "\\")):
            problems.append(f"unsafe path: {rel}")
            continue
        data = assets.get(rel)
        if data is None:
            problems.append(f"missing: {rel}")
            continue
        actual = sha256_hex(data)
        if actual.lower() != expected:
            problems.append(f"sha256 mismatch: {rel}")
            continue
        expected_bytes = asset.get("byteCount")
        if expected_bytes is not None and int(expected_bytes) != len(data):
            problems.append(f"byteCount mismatch: {rel}")
    return package, problems


def annotated_png_paths(package: dict[str, Any], package_dir: Path) -> list[str]:
    paths: list[str] = []
    for capture in package.get("captures") or []:
        if not isinstance(capture, dict):
            continue
        annotated = capture.get("annotatedImage") or {}
        rel = annotated.get("relativePath")
        if not rel:
            continue
        paths.append(str((package_dir / rel).resolve()))
    return paths


_NUMBERED_REQUEST_RE = re.compile(r"(?m)^\s*\d+\.\s+")


def require_canonical_prompt_text(text: str, package: Optional[dict[str, Any]] = None) -> None:
    """Validate canonical prompt body; raise ValueError if incomplete."""
    stripped = text.strip()
    if not stripped:
        raise ValueError("agent-prompt.txt is empty")

    lines = [ln.strip() for ln in stripped.splitlines() if ln.strip()]
    catalog_only = all(
        ln.startswith("App:")
        or ln.startswith("Page ")
        or ln.startswith("No screenshots")
        or ln == ""
        for ln in lines
    )
    if catalog_only:
        raise ValueError(
            "agent-prompt.txt looks like a page catalog only; "
            "canonical numbered requests are required"
        )

    annotation_count = 0
    if package is not None:
        anns = package.get("annotations") or []
        if isinstance(anns, list):
            annotation_count = len(anns)

    has_numbered = bool(_NUMBERED_REQUEST_RE.search(text))
    has_do_not_guess = "Do not guess" in text
    if annotation_count > 0 and not has_numbered and not has_do_not_guess:
        raise ValueError(
            "agent-prompt.txt must include numbered request lines "
            "(e.g. '1. …') matching annotations"
        )


def require_canonical_prompt_bytes(
    data: bytes, package: Optional[dict[str, Any]] = None
) -> None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"agent-prompt.txt is not UTF-8: {exc}") from exc
    require_canonical_prompt_text(text, package)


def require_canonical_prompt(package_dir: Path, package: Optional[dict[str, Any]] = None) -> Path:
    """Require a non-empty agent-prompt.txt that is more than a bare page catalog."""
    prompt_path = package_dir / "agent-prompt.txt"
    if not prompt_path.is_file() or prompt_path.stat().st_size == 0:
        raise FileNotFoundError(
            f"canonical agent-prompt.txt missing or empty under {package_dir}"
        )
    require_canonical_prompt_text(prompt_path.read_text(encoding="utf-8"), package)
    return prompt_path


def ensure_agent_prompt(package_dir: Path, package: dict[str, Any]) -> Path:
    """
    Require existing non-empty canonical agent-prompt.txt.

    Never invent a page-catalog-only fallback. Missing/empty → raise.
    """
    return require_canonical_prompt(package_dir, package)


def load_manifest(package_dir: Path) -> dict[str, Any]:
    manifest = package_dir / "manifest.json"
    if not manifest.is_file():
        raise FileNotFoundError(f"manifest.json not found in {package_dir}")
    return json.loads(manifest.read_text(encoding="utf-8"))


def load_package_dir_assets(package_dir: Path, package: dict[str, Any]) -> dict[str, bytes]:
    """
    Load referenced capture assets plus root execution files
    (agent-prompt.txt, page-*.png) so replay persists the canonical packet.
    """
    assets: dict[str, bytes] = {}
    for asset in referenced_assets(package):
        rel = str(asset["relativePath"])
        path = package_dir / rel
        if path.is_file():
            assets[rel] = path.read_bytes()

    # Root execution packet files (not under assets/).
    prompt = package_dir / "agent-prompt.txt"
    if prompt.is_file() and prompt.stat().st_size > 0:
        assets["agent-prompt.txt"] = prompt.read_bytes()

    for path in sorted(package_dir.glob("page-*.png")):
        if path.is_file():
            rel = path.name
            assets.setdefault(rel, path.read_bytes())

    assets_root = package_dir / "assets"
    if assets_root.is_dir():
        for path in assets_root.rglob("*"):
            if path.is_file():
                rel = str(path.relative_to(package_dir)).replace("\\", "/")
                assets.setdefault(rel, path.read_bytes())

    return assets
