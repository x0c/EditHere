"""Read project executor name and dump an accepted package. Fire-and-forget."""

from __future__ import annotations

import json
import sys
import threading
from pathlib import Path
from typing import TYPE_CHECKING, Any, Optional

from . import MissingExecutor, UnknownExecutor, get

if TYPE_CHECKING:
    from ..config import HostConfig
    from ..store import TaskStore


def read_executor_name(config: "HostConfig", project_id: str) -> str:
    """Return the project JSON executor string, or empty if absent."""
    proj = config.projects.get(project_id)
    if proj is None:
        return ""
    path = Path(proj.checkout) / proj.project_config
    if not path.is_file():
        return ""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(raw, dict):
        return ""
    return str(raw.get("executor") or "").strip()


def require_known_executor(name: str) -> None:
    if not name:
        raise MissingExecutor()
    if get(name) is None:
        raise UnknownExecutor(name)


def _append_dump_log(task_dir: Path, text: str) -> None:
    log_path = task_dir / "dump.log"
    try:
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(text)
            if not text.endswith("\n"):
                fh.write("\n")
    except OSError as exc:
        print(f"edithere-host: failed to write dump.log: {exc}", file=sys.stderr)


def _run_dump(
    store: "TaskStore",
    config: "HostConfig",
    task: dict[str, Any],
    name: str,
) -> None:
    remote = task["remoteTaskID"]
    task_dir = store.task_dir(remote)
    package_dir = store.package_dir(remote)
    checkout = Path(config.projects[task["projectID"]].checkout).resolve()
    executor = get(name)
    if executor is None:
        _append_dump_log(task_dir, f"unknown executor {name!r} at dump time")
        return
    try:
        executor.dump(task=task, package_dir=package_dir, checkout=checkout)
        _append_dump_log(task_dir, f"dumped to {name}")
    except Exception as exc:  # noqa: BLE001 — dump must not crash the host
        _append_dump_log(task_dir, f"dump failed: {exc}")
        print(f"edithere-host: executor {name} dump failed: {exc}", file=sys.stderr)


def dump_accepted_task(
    config: "HostConfig",
    store: "TaskStore",
    task: dict[str, Any],
    *,
    wait: bool,
) -> Optional[str]:
    """
    Dump a newly accepted task to its named executor.

    Returns the executor name. Accept/replay already rejected a missing name.
    HTTP callers pass wait=False so the response is not blocked.
    Replay passes wait=True so the process does not exit before inject.
    Does not wait for a result file in either case.
    """
    name = read_executor_name(config, task["projectID"])
    require_known_executor(name)
    if wait:
        _run_dump(store, config, task, name)
        return name
    thread = threading.Thread(
        target=_run_dump,
        args=(store, config, task, name),
        name=f"edithere-dump-{task['remoteTaskID']}",
        daemon=True,
    )
    thread.start()
    return name
