"""Worker lifecycle: prepare, start, cancel, ingest validated results."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional, TYPE_CHECKING

from .package_util import annotated_png_paths, ensure_agent_prompt, load_manifest
from .store import TaskStore, utc_now

if TYPE_CHECKING:
    from .config import HostConfig
    from .server import HostServerState

WORKER_CMD_ENV = "EDITHHERE_WORKER_CMD"
TASK_DIR_ENV = "EDITHHERE_TASK_DIR"
CHECKOUT_ENV = "EDITHHERE_CHECKOUT"
PROJECT_ID_ENV = "EDITHHERE_PROJECT_ID"

_MAX_WORKER_LOG_BYTES = 256 * 1024
_VALID_MARK_STATUSES = frozenset({"changed", "unresolved", "skipped", "failed"})


def write_worker_request(store: TaskStore, task: dict[str, Any]) -> Path:
    """Write worker-request.json. Requires existing non-empty agent-prompt.txt."""
    remote = task["remoteTaskID"]
    task_dir = store.task_dir(remote)
    package_dir = store.package_dir(remote)
    package = load_manifest(package_dir)
    prompt_path = ensure_agent_prompt(package_dir, package)
    pngs = annotated_png_paths(package, package_dir)
    payload = {
        "remoteTaskID": remote,
        "submissionID": task["submissionID"],
        "projectID": task["projectID"],
        "taskDir": str(task_dir.resolve()),
        "packageDir": str(package_dir.resolve()),
        "agentPromptPath": str(prompt_path.resolve()),
        "numberedPngPaths": pngs,
        "createdAt": utc_now(),
    }
    out = task_dir / "worker-request.json"
    tmp = out.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, out)
    return out


def _append_worker_log(task_dir: Path, text: str) -> None:
    log_path = task_dir / "worker.log"
    try:
        existing = log_path.read_bytes() if log_path.is_file() else b""
        chunk = text.encode("utf-8", errors="replace")
        combined = existing + chunk
        if len(combined) > _MAX_WORKER_LOG_BYTES:
            combined = combined[-_MAX_WORKER_LOG_BYTES:]
        log_path.write_bytes(combined)
    except OSError as exc:
        print(f"edithere-host: failed to write worker.log: {exc}", file=sys.stderr)


def _checkout_for_project(config: Optional["HostConfig"], project_id: str) -> Optional[Path]:
    if config is None:
        return None
    proj = config.projects.get(project_id)
    if proj is None:
        return None
    return Path(proj.checkout).resolve()


def _persist_worker_meta(store: TaskStore, remote_task_id: str, meta: dict[str, Any]) -> None:
    task = store.load_task(remote_task_id)
    if task is None:
        return
    task = dict(task)
    task["worker"] = meta
    store.save_task(task)


def _clear_worker_meta(store: TaskStore, remote_task_id: str) -> None:
    task = store.load_task(remote_task_id)
    if task is None:
        return
    task = dict(task)
    task.pop("worker", None)
    store.save_task(task)


def apply_results_file(store: TaskStore, remote_task_id: str, results_path: Path) -> dict[str, Any]:
    """
    Parse and validate results.json; copy markOutcomes/verification onto the task.

    Returns the updated task. Raises ValueError on invalid content.
    """
    task = store.load_task(remote_task_id)
    if task is None:
        raise ValueError("task not found")
    try:
        raw = results_path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"results.json is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("results.json must be a JSON object")

    rid = str(data.get("remoteTaskID") or "")
    sid = str(data.get("submissionID") or "")
    if rid and rid != task["remoteTaskID"]:
        raise ValueError("results.remoteTaskID does not match task")
    if sid and sid != task["submissionID"]:
        raise ValueError("results.submissionID does not match task")

    outcomes_raw = data.get("markOutcomes")
    if outcomes_raw is None:
        raise ValueError("results.json missing markOutcomes")
    if not isinstance(outcomes_raw, list):
        raise ValueError("markOutcomes must be an array")
    outcomes: list[dict[str, Any]] = []
    for i, item in enumerate(outcomes_raw):
        if not isinstance(item, dict):
            raise ValueError(f"markOutcomes[{i}] must be an object")
        try:
            number = int(item.get("number"))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"markOutcomes[{i}].number invalid") from exc
        status = str(item.get("status") or "")
        if status not in _VALID_MARK_STATUSES:
            raise ValueError(f"markOutcomes[{i}].status invalid")
        summary = str(item.get("summary") or "")
        paths = item.get("paths") or []
        if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
            raise ValueError(f"markOutcomes[{i}].paths must be a string array")
        outcomes.append(
            {"number": number, "status": status, "summary": summary, "paths": list(paths)}
        )

    verification_raw = data.get("verification")
    if verification_raw is None:
        raise ValueError("results.json missing verification")
    if not isinstance(verification_raw, dict):
        raise ValueError("verification must be an object")
    verification = {
        "codeChanged": bool(verification_raw.get("codeChanged", False)),
        "checksPassed": verification_raw.get("checksPassed", None),
        "artifactReady": bool(verification_raw.get("artifactReady", False)),
        "installed": bool(verification_raw.get("installed", False)),
        "visuallyVerified": bool(verification_raw.get("visuallyVerified", False)),
    }
    if verification["checksPassed"] is not None:
        verification["checksPassed"] = bool(verification["checksPassed"])

    task = dict(task)
    task["markOutcomes"] = outcomes
    task["verification"] = verification
    task["state"] = "readyForReview"
    summary = data.get("summary")
    task["summary"] = str(summary) if summary else "Worker finished with validated results."
    store.save_task(task)
    return store.load_task(remote_task_id) or task


def _watch_process(
    store: TaskStore,
    remote_task_id: str,
    proc: subprocess.Popen,
    state: Optional["HostServerState"],
) -> None:
    """Wait for worker exit; map exit code + validated results to task state."""
    exit_code: Optional[int] = None
    try:
        exit_code = proc.wait()
    except Exception as exc:  # noqa: BLE001
        _append_worker_log(store.task_dir(remote_task_id), f"\nwait error: {exc}\n")
        exit_code = -1

    task_dir = store.task_dir(remote_task_id)
    _append_worker_log(task_dir, f"\nexit_code={exit_code}\n")

    if state is not None:
        state.clear_worker(remote_task_id)
    _clear_worker_meta(store, remote_task_id)

    task = store.load_task(remote_task_id)
    if task is None:
        return
    if task.get("state") == "cancelled":
        return

    task = dict(task)
    if exit_code == 0:
        results = task_dir / "results.json"
        if not results.is_file():
            task["state"] = "failed"
            task["summary"] = "Worker exited 0 but results.json is missing."
            store.save_task(task)
            return
        try:
            apply_results_file(store, remote_task_id, results)
        except ValueError as exc:
            task = store.load_task(remote_task_id) or task
            task = dict(task)
            if task.get("state") == "cancelled":
                return
            task["state"] = "failed"
            task["summary"] = f"Worker results invalid: {exc}"
            store.save_task(task)
    else:
        task["state"] = "failed"
        task["summary"] = f"Worker exited with code {exit_code}."
        store.save_task(task)


def start_worker_process(
    store: TaskStore,
    task: dict[str, Any],
    *,
    config: Optional["HostConfig"] = None,
    state: Optional["HostServerState"] = None,
) -> dict[str, Any]:
    """
    Start EDITHHERE_WORKER_CMD via Popen in a new session.

    Rechecks cancellation before and after Popen under the server lock so a
    cancel that wins the race never leaves a running worker.
    """
    cmd = os.environ.get(WORKER_CMD_ENV)
    if not cmd or not cmd.strip():
        return {"invoked": False, "reason": "no_worker_cmd"}

    remote = task["remoteTaskID"]
    task_dir = store.task_dir(remote)
    checkout = _checkout_for_project(config, task["projectID"])
    cwd = str(checkout) if checkout is not None and checkout.is_dir() else str(task_dir)

    env = os.environ.copy()
    env[TASK_DIR_ENV] = str(task_dir.resolve())
    env[PROJECT_ID_ENV] = str(task["projectID"])
    if checkout is not None:
        env[CHECKOUT_ENV] = str(checkout)

    if state is not None and state.is_cancel_requested(remote):
        return {"invoked": False, "reason": "cancelled_before_start", "task": store.load_task(remote)}

    current = store.load_task(remote)
    if current is not None and current.get("state") == "cancelled":
        return {"invoked": False, "reason": "cancelled_before_start", "task": current}

    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
    except OSError as exc:
        print(f"edithere-host: worker command failed to start: {exc}", file=sys.stderr)
        task = dict(store.load_task(remote) or task)
        if task.get("state") != "cancelled":
            task["state"] = "failed"
            task["summary"] = f"Worker failed to start: {exc}"
            store.save_task(task)
        return {"invoked": True, "exitCode": None, "error": "start_failed", "task": task}

    # Critical section: register or kill if cancel won the race.
    if state is not None:
        with state.lifecycle_lock:
            if state.is_cancel_requested(remote):
                _kill_process_group(proc, grace_seconds=2.0)
                state.clear_worker(remote)
                task = dict(store.load_task(remote) or task)
                task["state"] = "cancelled"
                task["summary"] = task.get("summary") or "Cancelled before worker registration."
                store.save_task(task)
                _clear_worker_meta(store, remote)
                return {
                    "invoked": True,
                    "cancelledBeforeRegister": True,
                    "stopped": True,
                    "task": store.load_task(remote),
                }
            state.register_worker(remote, proc)
            _persist_worker_meta(
                store,
                remote,
                {
                    "pid": proc.pid,
                    "pgid": proc.pid,
                    "startedAt": utc_now(),
                    "cmdEnv": WORKER_CMD_ENV,
                },
            )
            task = dict(store.load_task(remote) or task)
            if task.get("state") != "cancelled":
                task["state"] = "working"
                task["summary"] = "Worker process started."
                store.save_task(task)
    else:
        _persist_worker_meta(
            store,
            remote,
            {
                "pid": proc.pid,
                "pgid": proc.pid,
                "startedAt": utc_now(),
                "cmdEnv": WORKER_CMD_ENV,
            },
        )
        task = dict(store.load_task(remote) or task)
        if task.get("state") != "cancelled":
            task["state"] = "working"
            task["summary"] = "Worker process started."
            store.save_task(task)

    def _drain_and_watch() -> None:
        try:
            if proc.stdout is not None:
                for line in proc.stdout:
                    _append_worker_log(task_dir, line)
        except Exception:  # noqa: BLE001
            pass
        finally:
            try:
                if proc.stdout is not None:
                    proc.stdout.close()
            except Exception:  # noqa: BLE001
                pass
        _watch_process(store, remote, proc, state)

    thread = threading.Thread(target=_drain_and_watch, name=f"edithere-worker-{remote}", daemon=True)
    thread.start()
    return {
        "invoked": True,
        "pid": proc.pid,
        "task": store.load_task(remote),
    }


def _kill_process_group(proc: subprocess.Popen, *, grace_seconds: float) -> dict[str, Any]:
    if proc.poll() is not None:
        return {"alreadyExited": True, "exitCode": proc.returncode, "stopped": True}

    pid = proc.pid
    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.terminate()
        except OSError:
            pass

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        time.sleep(0.05)

    if proc.poll() is None:
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass

    while proc.poll() is None:
        time.sleep(0.05)

    return {"stopped": True, "exitCode": proc.returncode}


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def cancel_worker_process(
    state: "HostServerState",
    store: TaskStore,
    remote_task_id: str,
    *,
    grace_seconds: float = 2.0,
) -> dict[str, Any]:
    """
    Request cancel, stop any live process (in-memory or persisted), wait until stopped.

    Unknown running state is reported with stopped=False — callers must not claim success.
    """
    state.request_cancel(remote_task_id)

    proc = state.get_worker(remote_task_id)
    if proc is not None:
        result = _kill_process_group(proc, grace_seconds=grace_seconds)
        state.clear_worker(remote_task_id)
        _clear_worker_meta(store, remote_task_id)
        return {"hadProcess": True, **result}

    # Receiver restart: recover from durable worker metadata.
    task = store.load_task(remote_task_id)
    worker = (task or {}).get("worker") if task else None
    if isinstance(worker, dict) and worker.get("pid"):
        try:
            pid = int(worker["pid"])
        except (TypeError, ValueError):
            return {
                "hadProcess": False,
                "stopped": False,
                "uncertain": True,
                "reason": "invalid_persisted_pid",
            }
        if not _pid_alive(pid):
            _clear_worker_meta(store, remote_task_id)
            return {"hadProcess": True, "alreadyExited": True, "stopped": True}
        try:
            os.killpg(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pass
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline and _pid_alive(pid):
            time.sleep(0.05)
        if _pid_alive(pid):
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
            time.sleep(0.1)
        if _pid_alive(pid):
            return {
                "hadProcess": True,
                "stopped": False,
                "uncertain": True,
                "reason": "process_still_alive",
                "pid": pid,
            }
        _clear_worker_meta(store, remote_task_id)
        return {"hadProcess": True, "stopped": True, "recoveredFromDisk": True}

    return {"hadProcess": False, "stopped": True}


def enqueue_worker(
    store: TaskStore,
    task: dict[str, Any],
    *,
    config: Optional["HostConfig"] = None,
    state: Optional["HostServerState"] = None,
    async_start: bool = True,
) -> dict[str, Any]:
    """
    Prepare worker request with honest state transitions.

    - Always require canonical agent-prompt.txt.
    - Without EDITHHERE_WORKER_CMD → waitingForComputer (never working).
    - With command → start in background after accept; working only after Popen.
    """
    try:
        request_path = write_worker_request(store, task)
    except (FileNotFoundError, ValueError, OSError) as exc:
        task = dict(task)
        task["state"] = "failed"
        task["summary"] = f"Worker prep failed: {exc}"
        store.save_task(task)
        return {
            "task": store.load_task(task["remoteTaskID"]),
            "workerRequestPath": None,
            "error": str(exc),
        }

    cmd = os.environ.get(WORKER_CMD_ENV)
    if not cmd or not cmd.strip():
        task = dict(task)
        task["state"] = "waitingForComputer"
        task["summary"] = (
            "Worker request prepared; no EDITHHERE_WORKER_CMD configured. "
            "Waiting for computer-side execution."
        )
        store.save_task(task)
        return {
            "task": store.load_task(task["remoteTaskID"]),
            "workerRequestPath": str(request_path),
            "workerRun": {"invoked": False, "reason": "no_worker_cmd"},
        }

    if async_start and state is not None:
        remote = task["remoteTaskID"]
        if state.is_cancel_requested(remote):
            task = dict(task)
            task["state"] = "cancelled"
            task["summary"] = "Cancelled before worker start."
            store.save_task(task)
            return {
                "task": store.load_task(remote),
                "workerRequestPath": str(request_path),
                "workerRun": {"invoked": False, "reason": "cancelled_before_start"},
            }

        task = dict(task)
        task["state"] = "submitted"
        task["summary"] = task.get("summary") or "Accepted; starting worker."
        store.save_task(task)

        def _start() -> None:
            # Optional test hook: barrier before Popen (cancel-before-start probes).
            barrier = getattr(state, "start_barrier", None)
            if barrier is not None:
                try:
                    barrier.wait()
                except Exception:  # noqa: BLE001
                    pass
            start_worker_process(store, task, config=config, state=state)

        threading.Thread(target=_start, name=f"edithere-start-{remote}", daemon=True).start()
        return {
            "task": store.load_task(remote),
            "workerRequestPath": str(request_path),
            "workerRun": {"invoked": True, "async": True},
        }

    run_info = start_worker_process(store, task, config=config, state=state)
    return {
        "task": store.load_task(task["remoteTaskID"]),
        "workerRequestPath": str(request_path),
        "workerRun": run_info,
    }
