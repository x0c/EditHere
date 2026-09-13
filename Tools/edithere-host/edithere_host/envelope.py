"""JSON envelope helpers, exit codes, and stdout/stderr conventions."""

from __future__ import annotations

import json
import sys
from typing import Any, Optional

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_AUTH = 4
EXIT_CONFLICT = 5
EXIT_TIMEOUT = 6


def want_json(force_json: bool = False) -> bool:
    if force_json:
        return True
    return not sys.stdout.isatty()


def envelope(
    *,
    ok: bool,
    data: Any = None,
    error: Optional[dict] = None,
    meta: Optional[dict] = None,
) -> dict:
    return {
        "ok": ok,
        "data": data if ok else (data if data is not None else None),
        "error": None if ok else (error or {"code": "error", "message": "failed", "hint": None}),
        "meta": meta or {},
    }


def error_body(code: str, message: str, hint: Optional[str] = None) -> dict:
    return {"code": code, "message": message, "hint": hint}


def emit(
    payload: dict,
    *,
    as_json: bool,
    human_lines: Optional[list[str]] = None,
    exit_code: int = EXIT_OK,
) -> int:
    if as_json:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    else:
        if human_lines:
            sys.stdout.write("\n".join(human_lines) + "\n")
        else:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return exit_code


def http_status_for_error(code: Optional[str]) -> int:
    mapping = {
        "unauthorized": 401,
        "forbidden": 403,
        "not_found": 404,
        "conflict": 409,
        "bad_request": 400,
        "incomplete_assets": 400,
        "invalid_package": 400,
        "method_not_allowed": 405,
    }
    if not code:
        return 500
    return mapping.get(code, 500)
