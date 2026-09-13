"""Minimal multipart/form-data parser (stdlib only)."""

from __future__ import annotations

import re
from typing import Optional


class FormField:
    __slots__ = ("name", "filename", "content_type", "data")

    def __init__(
        self,
        name: str,
        data: bytes,
        filename: Optional[str] = None,
        content_type: Optional[str] = None,
    ):
        self.name = name
        self.data = data
        self.filename = filename
        self.content_type = content_type


_NAME_RE = re.compile(rb'name="([^"]+)"')
_FILENAME_RE = re.compile(rb'filename="([^"]*)"')
_CT_RE = re.compile(rb"Content-Type:\s*([^\r\n]+)", re.IGNORECASE)


def _boundary_from_content_type(content_type: str) -> bytes:
    # Content-Type: multipart/form-data; boundary=----xyz
    match = re.search(r"boundary=([^;]+)", content_type, flags=re.IGNORECASE)
    if not match:
        raise ValueError("multipart Content-Type missing boundary")
    boundary = match.group(1).strip().strip('"')
    return boundary.encode("ascii", errors="strict")


def parse_multipart(content_type: str, body: bytes) -> dict[str, list[FormField]]:
    """Parse multipart body into name -> list[FormField]."""
    if "multipart/" not in (content_type or "").lower():
        raise ValueError("Content-Type must be multipart/*")
    boundary = _boundary_from_content_type(content_type)
    delimiter = b"--" + boundary
    if delimiter not in body:
        raise ValueError("multipart body missing boundary delimiter")

    fields: dict[str, list[FormField]] = {}
    parts = body.split(delimiter)
    for part in parts:
        if not part or part in (b"--", b"--\r\n", b"--\n"):
            continue
        if part.startswith(b"--"):
            # epilogue after closing boundary
            continue
        if part.startswith(b"\r\n"):
            part = part[2:]
        elif part.startswith(b"\n"):
            part = part[1:]
        if part.endswith(b"\r\n"):
            part = part[:-2]
        elif part.endswith(b"\n"):
            part = part[:-1]

        header_blob, sep, data = part.partition(b"\r\n\r\n")
        if not sep:
            header_blob, sep, data = part.partition(b"\n\n")
        if not sep:
            continue
        # Trailing CRLF before the next boundary was already stripped from `part`
        # above. Do not strip again — that would corrupt payloads that end in `\n`
        # (e.g. agent-prompt.txt).

        name_m = _NAME_RE.search(header_blob)
        if not name_m:
            continue
        name = name_m.group(1).decode("utf-8", errors="replace")
        filename_m = _FILENAME_RE.search(header_blob)
        filename = (
            filename_m.group(1).decode("utf-8", errors="replace") if filename_m else None
        )
        ct_m = _CT_RE.search(header_blob)
        content_type_part = ct_m.group(1).decode("utf-8", errors="replace").strip() if ct_m else None
        field = FormField(name=name, data=data, filename=filename, content_type=content_type_part)
        fields.setdefault(name, []).append(field)
    return fields


def first_text(fields: dict[str, list[FormField]], name: str) -> Optional[str]:
    items = fields.get(name)
    if not items:
        return None
    return items[0].data.decode("utf-8")


def first_bytes(fields: dict[str, list[FormField]], name: str) -> Optional[bytes]:
    items = fields.get(name)
    if not items:
        return None
    return items[0].data
