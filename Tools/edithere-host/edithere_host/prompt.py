"""Canonical Agent prompt — derived view of an evidence package.

Port of EditHereCore PromptBuilder (template 8). Never print the template
number. Do not print CSS selectors, page URLs, or React source paths.
"""

from __future__ import annotations

import re
from typing import Any, Optional
from uuid import UUID

CURRENT_TEMPLATE_VERSION = 8  # code constant only — never Agent-facing

_REMOVE_ACTIONS = frozenset({"remove", "removeElement"})
_DEFAULT_PROMPTS = {
    "customRequest": "",
    "removeElement": "Remove this element from the UI.",
    "changeText": "Change the text of this element.",
    "adjustAppearance": "Adjust the appearance of this element.",
}
_CANNED_REQUESTS = {
    "removeElement": "Remove the marked element from the product.",
    "changeText": "Change the text of the marked element.",
    "adjustAppearance": "Adjust the appearance of the marked element.",
}

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def _non_empty(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _normalize_action(raw: Any) -> str:
    action = str(raw or "customRequest").strip()
    if action in _REMOVE_ACTIONS:
        return "removeElement"
    if action in _DEFAULT_PROMPTS:
        return action
    return "customRequest"


def _default_prompt(action: str) -> str:
    return _DEFAULT_PROMPTS.get(action, "")


def _effective_request_text(annotation: dict[str, Any]) -> str:
    action = _normalize_action(annotation.get("action"))
    text = str(annotation.get("requestText") or "").strip()
    if not text:
        return _default_prompt(action)
    return text


def _is_complete(annotation: dict[str, Any]) -> bool:
    action = _normalize_action(annotation.get("action"))
    text = str(annotation.get("requestText") or "").strip()
    if action == "removeElement":
        return True
    if action == "customRequest":
        return bool(text)
    if action == "changeText":
        return bool(text) and text != _default_prompt("changeText") and text != "Change the text to:"
    if action == "adjustAppearance":
        return bool(text) and text != _default_prompt("adjustAppearance")
    return bool(text)


def _request_line(annotation: dict[str, Any]) -> str:
    action = _normalize_action(annotation.get("action"))
    text = _effective_request_text(annotation)
    if text == _default_prompt(action):
        if action in _CANNED_REQUESTS:
            return _CANNED_REQUESTS[action]
    return text


def _useful_identifier(value: Any) -> Optional[str]:
    text = _non_empty(value)
    if text is None:
        return None
    if text.startswith("_"):
        return None
    if len(text) > 64:
        return None
    if _UUID_RE.fullmatch(text):
        return None
    try:
        UUID(text)
        return None
    except (ValueError, TypeError, AttributeError):
        pass
    return text


def public_control_kind(class_name: Optional[str]) -> Optional[str]:
    """Human control kind. Never emit private or raw UIKit class names."""
    raw = _non_empty(class_name)
    if raw is None:
        return None
    if raw.startswith("_"):
        return None
    name = re.split(r"[.\s]", raw)[-1]
    if name.startswith("_"):
        return None
    if "Hosting" in name:
        return None
    lower = name.lower()
    html = {
        "button": "button",
        "a": "link",
        "input": "text field",
        "textarea": "text field",
        "select": "button",
        "img": "image",
        "image": "image",
        "label": "label",
        "h1": "label",
        "h2": "label",
        "h3": "label",
        "li": "list row",
        "tr": "list row",
    }
    if lower in html:
        return html[lower]
    if "Button" in name:
        return "button"
    if "Switch" in name:
        return "switch"
    if "Slider" in name:
        return "slider"
    if "TextField" in name or "TextView" in name:
        return "text field"
    if "TabBar" in name:
        return "tab item"
    if "Cell" in name:
        return "list row"
    if "ImageView" in name or name.endswith("Image"):
        return "image"
    if name == "UILabel" or name.endswith("Label"):
        return "label"
    return None


def _hint_lines(annotation: dict[str, Any]) -> list[str]:
    hint = annotation.get("targetHint") or {}
    if not isinstance(hint, dict):
        hint = {}
    lines: list[str] = []
    on_screen = _non_empty(hint.get("visibleText"))
    if on_screen:
        lines.append(f"On screen: {on_screen}")
    label = _non_empty(hint.get("accessibilityLabel"))
    if label and label != hint.get("visibleText"):
        lines.append(f"Accessibility name: {label}")
    identifier = _useful_identifier(hint.get("accessibilityIdentifier"))
    if identifier:
        lines.append(f"Accessibility id: {identifier}")
    if on_screen is None:
        kind = public_control_kind(hint.get("className") if isinstance(hint.get("className"), str) else None)
        if kind:
            lines.append(f"Control: {kind}")
    instance = hint.get("instanceIndex")
    if isinstance(instance, int):
        lines.append(f"Similar on-screen row #{instance}")
    return lines


def _renumbered(package: dict[str, Any]) -> list[dict[str, Any]]:
    annotations = package.get("annotations") or []
    if not isinstance(annotations, list):
        return []
    out: list[dict[str, Any]] = []
    for index, item in enumerate(annotations):
        if not isinstance(item, dict):
            continue
        copy = dict(item)
        copy["number"] = index + 1
        out.append(copy)
    return out


def captures_used_by(annotations: list[dict[str, Any]], package: dict[str, Any]) -> list[dict[str, Any]]:
    used = {str(item.get("captureID") or "") for item in annotations}
    captures = package.get("captures") or []
    if not isinstance(captures, list):
        return []
    return [c for c in captures if isinstance(c, dict) and str(c.get("id") or "") in used]


def batch_prompt(package: dict[str, Any]) -> str:
    annotations = _renumbered(package)
    used_captures = captures_used_by(annotations, package)
    page_index_by_capture: dict[str, int] = {}
    for index, capture in enumerate(used_captures):
        page_index_by_capture[str(capture.get("id") or "")] = index + 1

    lines: list[str] = []
    app = _non_empty((package.get("app") or {}).get("displayName")) if isinstance(package.get("app"), dict) else None
    if app:
        lines.append(f"App: {app}")
    revision = None
    if isinstance(package.get("app"), dict):
        revision = _non_empty(package["app"].get("sourceRevision"))
    if revision:
        lines.append(f"Source: {revision}")
    lines.append(
        "Marks: blue rounded outline, white number on a blue pill at the top-left of the box. "
        "A point mark is a blue ring and crosshair with the same numbered pill."
    )
    if not used_captures:
        lines.append("No screenshots with marks were included.")
    else:
        for capture in used_captures:
            page = page_index_by_capture.get(str(capture.get("id") or ""), 0)
            marks = [
                str(item["number"])
                for item in annotations
                if str(item.get("captureID") or "") == str(capture.get("id") or "")
            ]
            mark_list = ", ".join(marks)
            screen = str(capture.get("screenID") or "unknown-screen")
            lines.append(f"Page {page} · {screen} — marks {mark_list}")
    overall = str(package.get("overallInstruction") or "").strip()
    if overall:
        lines.append("")
        lines.append(overall)
    lines.append("")
    if not annotations:
        lines.append("No requests.")
    else:
        captures = package.get("captures") or []
        capture_by_id = {
            str(c.get("id") or ""): c
            for c in captures
            if isinstance(c, dict)
        }
        for annotation in annotations:
            cid = str(annotation.get("captureID") or "")
            capture = capture_by_id.get(cid)
            page = page_index_by_capture.get(cid)
            screen = str((capture or {}).get("screenID") or "unknown-screen")
            page_label = f"Page {page} · {screen}" if page else screen
            lines.append(f"{annotation['number']}. {page_label}")
            lines.append(_request_line(annotation))
            lines.extend(_hint_lines(annotation))
            if str(annotation.get("selectionKind") or "") == "point":
                lines.append(
                    "This mark is a numbered point (outline not recognized). "
                    "Confirm the control on the screenshot."
                )
            if not _is_complete(annotation):
                lines.append("The change is not specific. Do not guess.")
            lines.append("")
        if lines and lines[-1] == "":
            lines.pop()
    return "\n".join(lines)


def execution_prompt(package: dict[str, Any]) -> str:
    """Page catalog + canonical legend (same envelope as the iOS evidence writer)."""
    annotations = _renumbered(package)
    used = captures_used_by(annotations, package)
    envelope: list[str] = []
    for index, _capture in enumerate(used):
        envelope.append(f"Page {index + 1}: page-{index + 1}.png")
    if envelope:
        envelope.append("")
    envelope.append(batch_prompt(package))
    return "\n".join(envelope)


def assemble_execution_assets(
    package: dict[str, Any], assets: dict[str, bytes]
) -> tuple[str, dict[str, bytes]]:
    """
    Add canonical agent-prompt.txt and page-N.png copies of annotated captures.

    Does not draw marks; clients send already-annotated images.
    """
    out = dict(assets)
    annotations = _renumbered(package)
    used = captures_used_by(annotations, package)
    for index, capture in enumerate(used):
        rel = str((capture.get("annotatedImage") or {}).get("relativePath") or "")
        page_name = f"page-{index + 1}.png"
        if rel and rel in out:
            out[page_name] = out[rel]
    prompt = execution_prompt(package)
    out["agent-prompt.txt"] = prompt.encode("utf-8")
    return prompt, out
