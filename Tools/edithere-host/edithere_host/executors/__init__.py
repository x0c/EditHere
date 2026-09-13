"""Named executor registry. Optional backends live only in this package."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol


class Executor(Protocol):
    name: str

    def dump(
        self,
        *,
        task: dict[str, Any],
        package_dir: Path,
        checkout: Path,
    ) -> None:
        """Start work. Do not wait for a result file."""


_REGISTRY: dict[str, Executor] = {}


def register(executor: Executor) -> None:
    _REGISTRY[executor.name] = executor


def get(name: str) -> Executor | None:
    return _REGISTRY.get(name)


def known_names() -> frozenset[str]:
    return frozenset(_REGISTRY)


class MissingExecutor(ValueError):
    def __init__(self) -> None:
        super().__init__(
            "Project JSON has no executor name; dump would not happen."
        )


class UnknownExecutor(ValueError):
    def __init__(self, name: str) -> None:
        self.name = name
        super().__init__(
            f"Unknown executor {name!r}. Known: {', '.join(sorted(known_names())) or '(none)'}."
        )


from .corral_cursor import CorralCursorExecutor  # noqa: E402

register(CorralCursorExecutor())
