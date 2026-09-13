"""corral-cursor: Corral-hosted Cursor session. Internals of one executor."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

from ..package_util import annotated_png_paths, load_manifest, require_canonical_prompt


NAME = "corral-cursor"
_SETTLE_ENV = "EDITHHERE_CORRAL_SETTLE_SECONDS"
_DEFAULT_SETTLE = 4.0


def _ensure_corral_on_path() -> Path:
    sesskit_src = Path.home() / "Codes" / "SessKit" / "src"
    if sesskit_src.is_dir() and str(sesskit_src) not in sys.path:
        sys.path.insert(0, str(sesskit_src))
    try:
        import corral.remote.sessions  # noqa: F401

        return Path(corral.remote.sessions.__file__).resolve().parent
    except ImportError:
        pass
    candidates: list[Path] = []
    env = os.environ.get("CORRAL_CLI_SRC")
    if env:
        candidates.append(Path(env).expanduser())
    candidates.append(Path.home() / "Codes" / "Corral" / "cli" / "src")
    for src in candidates:
        marker = src / "corral" / "remote" / "sessions.py"
        if marker.is_file():
            sys.path.insert(0, str(src))
            try:
                import corral.remote.sessions  # noqa: F401

                return src
            except ImportError:
                continue
    raise RuntimeError(
        "Corral CLI source not found or its dependencies are missing. "
        "Set CORRAL_CLI_SRC to …/Corral/cli/src (SessKit src is auto-added from ~/Codes/SessKit/src)."
    )


def _settle_seconds() -> float:
    raw = os.environ.get(_SETTLE_ENV)
    if not raw:
        return _DEFAULT_SETTLE
    try:
        return max(0.0, float(raw))
    except ValueError:
        return _DEFAULT_SETTLE


def _image_files(package: dict[str, Any], package_dir: Path) -> list[Path]:
    pages = sorted(p for p in package_dir.glob("page-*.png") if p.is_file())
    if pages:
        return pages
    out: list[Path] = []
    for raw in annotated_png_paths(package, package_dir):
        path = Path(raw)
        if path.is_file():
            out.append(path)
    if not out:
        raise RuntimeError(f"no numbered screenshots under {package_dir}")
    return out


class CorralCursorExecutor:
    name = NAME

    def dump(
        self,
        *,
        task: dict[str, Any],
        package_dir: Path,
        checkout: Path,
    ) -> None:
        if not checkout.is_dir():
            raise RuntimeError(f"checkout is not a directory: {checkout}")
        package = load_manifest(package_dir)
        prompt_path = require_canonical_prompt(package_dir, package)
        prompt = prompt_path.read_text(encoding="utf-8")
        images = _image_files(package, package_dir)

        _ensure_corral_on_path()
        from corral.remote.sessions import SessionHub, default_title_spawn_fn

        hub = SessionHub(title_spawn_fn=default_title_spawn_fn)
        payload = hub.new_session("cursor", str(checkout))
        key = str(payload.get("key") or "").strip()
        if not key:
            raise RuntimeError("Corral new_session returned no session key")
        settle = _settle_seconds()
        if settle:
            time.sleep(settle)
        for image in images:
            hub.send_image(key, image.read_bytes())
        hub.send_text(key, prompt)

