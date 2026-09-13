"""HTTP receiver for EditHere evidence packages."""

from __future__ import annotations

import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Optional
from urllib.parse import parse_qs, unquote, urlparse

from .advertise import Advertiser, advertisable
from .config import HostConfig
from .envelope import envelope, error_body
from .multipart import first_bytes, first_text, parse_multipart
from .package_util import (
    compute_content_digest,
    require_canonical_prompt_bytes,
    validate_package_and_assets,
)
from .executors import MissingExecutor, UnknownExecutor
from .executors.dispatch import dump_accepted_task, read_executor_name, require_known_executor
from .store import ConflictError, TaskStore
from .worker import cancel_worker_process, enqueue_worker


class HostServerState:
    def __init__(self, config: HostConfig, store: TaskStore, *, auto_worker: bool = False):
        self.config = config
        self.store = store
        self.auto_worker = auto_worker
        self.advertiser: Any = None
        self.lifecycle_lock = threading.RLock()
        self._workers: dict[str, subprocess.Popen] = {}
        self._cancel_requested: set[str] = set()
        # Optional test hook: threading.Barrier set by probes before enqueue.
        self.start_barrier: Any = None

    def request_cancel(self, remote_task_id: str) -> None:
        with self.lifecycle_lock:
            self._cancel_requested.add(remote_task_id)

    def is_cancel_requested(self, remote_task_id: str) -> bool:
        with self.lifecycle_lock:
            return remote_task_id in self._cancel_requested

    def register_worker(self, remote_task_id: str, proc: subprocess.Popen) -> None:
        # Caller must hold lifecycle_lock when racing with cancel.
        self._workers[remote_task_id] = proc

    def get_worker(self, remote_task_id: str) -> Optional[subprocess.Popen]:
        with self.lifecycle_lock:
            return self._workers.get(remote_task_id)

    def clear_worker(self, remote_task_id: str) -> None:
        with self.lifecycle_lock:
            self._workers.pop(remote_task_id, None)



def _project_id_from_request(headers: Any, query: dict[str, list[str]]) -> Optional[str]:
    q = (query.get("projectID") or [None])[0]
    if q and str(q).strip():
        return str(q).strip()
    header = headers.get("X-EditHere-Project-ID")
    if header and str(header).strip():
        return str(header).strip()
    return None


def make_handler(state: HostServerState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: Any) -> None:
            # Never log Authorization / token headers. Standard access line only.
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _send_json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def _fail(self, status: int, code: str, message: str, hint: Optional[str] = None, **meta: Any) -> None:
            self._send_json(
                status,
                envelope(ok=False, data=None, error=error_body(code, message, hint), meta=meta or {}),
            )

        def _ok(self, data: Any, status: int = 200, **meta: Any) -> None:
            self._send_json(status, envelope(ok=True, data=data, error=None, meta=meta or {}))

        def _check_token(self, project_id: Optional[str] = None) -> bool:
            got = self.headers.get("X-EditHere-Token")
            if project_id:
                if not state.config.authorize(got, project_id):
                    self._fail(
                        401,
                        "unauthorized",
                        "Missing or invalid token for this project.",
                        hint="Use the project-scoped credential provisioned for this app binding.",
                    )
                    return False
                return True
            # Health / routes without project: any configured host token is enough.
            expected = state.config.token()
            if expected is None:
                self._fail(
                    401,
                    "unauthorized",
                    "Host token is not configured in the environment.",
                    hint=f"Set env {state.config.token_env} before serving.",
                )
                return False
            if got is None or got != expected:
                self._fail(401, "unauthorized", "Missing or invalid X-EditHere-Token.")
                return False
            return True

        def do_GET(self) -> None:  # noqa: N802
            try:
                self._do_GET()
            except Exception as exc:  # noqa: BLE001 — always answer with envelope
                self._fail(500, "internal_error", f"Unhandled server error: {exc}")

        def do_POST(self) -> None:  # noqa: N802
            try:
                self._do_POST()
            except Exception as exc:  # noqa: BLE001
                self._fail(500, "internal_error", f"Unhandled server error: {exc}")

        def _lookup_submission(self, submission_id: str, project_id: Optional[str]) -> None:
            if not project_id:
                self._fail(
                    400,
                    "bad_request",
                    "projectID is required for submission lookup.",
                    hint="Pass ?projectID=… or header X-EditHere-Project-ID.",
                )
                return
            task = state.store.find_by_submission(submission_id, project_id=project_id)
            if task is None:
                self._fail(
                    404,
                    "not_found",
                    f"No task for projectID={project_id} submissionID={submission_id}.",
                )
                return
            self._ok(task)

        def _do_GET(self) -> None:
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            query = parse_qs(parsed.query)

            if path in ("/v1/health", "/health"):
                if not self._check_token():
                    return
                self._ok({"status": "ok", "destinationID": "local-host"})
                return

            # Optional nested route: /v1/projects/{projectID}/submissions/{submissionID}
            if path.startswith("/v1/projects/"):
                rest = path[len("/v1/projects/") :].strip("/")
                parts = rest.split("/")
                if len(parts) == 3 and parts[1] == "submissions":
                    project_id = parts[0]
                    submission_id = parts[2]
                    if not project_id or not submission_id:
                        self._fail(400, "bad_request", "Invalid project/submission path.")
                        return
                    if not self._check_token(project_id):
                        return
                    self._lookup_submission(submission_id, project_id)
                    return
                self._fail(404, "not_found", f"Unknown path {path}.")
                return

            if path.startswith("/v1/submissions/"):
                submission_id = path[len("/v1/submissions/") :].strip("/")
                if not submission_id or "/" in submission_id:
                    self._fail(400, "bad_request", "Invalid submissionID path.")
                    return
                project_id = _project_id_from_request(self.headers, query)
                if not project_id:
                    self._fail(
                        400,
                        "bad_request",
                        "projectID is required for submission lookup.",
                        hint="Pass ?projectID=… or header X-EditHere-Project-ID.",
                    )
                    return
                if not self._check_token(project_id):
                    return
                self._lookup_submission(submission_id, project_id)
                return
            if path.startswith("/v1/tasks/"):
                rest = path[len("/v1/tasks/") :].strip("/")
                if not rest or "/" in rest:
                    self._fail(400, "bad_request", "Invalid remoteTaskID path.")
                    return
                task = state.store.load_task(rest)
                if task is None:
                    self._fail(404, "not_found", f"No task for remoteTaskID {rest}.")
                    return
                if not self._check_token(str(task.get("projectID") or "")):
                    return
                self._ok(task)
                return
            self._fail(404, "not_found", f"Unknown path {path}.")

        def _do_POST(self) -> None:
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            if path == "/v1/submissions":
                self._handle_submit()
                return
            if path.startswith("/v1/tasks/") and path.endswith("/cancel"):
                remote = path[len("/v1/tasks/") : -len("/cancel")].strip("/")
                if not remote or "/" in remote:
                    self._fail(400, "bad_request", "Invalid remoteTaskID path.")
                    return
                task = state.store.load_task(remote)
                if task is None:
                    self._fail(404, "not_found", f"No task for remoteTaskID {remote}.")
                    return
                if not self._check_token(str(task.get("projectID") or "")):
                    return
                self._handle_cancel(remote)
                return
            if not self._check_token():
                return
            self._fail(404, "not_found", f"Unknown path {path}.")

        def _read_body(self) -> bytes:
            length = int(self.headers.get("Content-Length") or "0")
            if length < 0:
                return b""
            return self.rfile.read(length)

        def _handle_submit(self) -> None:
            content_type = self.headers.get("Content-Type") or ""
            body = self._read_body()
            try:
                fields = parse_multipart(content_type, body)
            except ValueError as exc:
                self._fail(400, "bad_request", f"Invalid multipart body: {exc}")
                return

            project_id = (first_text(fields, "projectID") or "").strip()
            submission_id = (first_text(fields, "submissionID") or "").strip()
            claimed_digest = (first_text(fields, "contentDigest") or "").strip()
            package_bytes = first_bytes(fields, "package")

            if not project_id or not submission_id or not claimed_digest or package_bytes is None:
                self._fail(
                    400,
                    "bad_request",
                    "Missing required fields: projectID, submissionID, contentDigest, package.",
                )
                return

            if not self._check_token(project_id):
                return

            if project_id not in state.config.projects:
                self._fail(
                    404,
                    "not_found",
                    f"Unknown projectID {project_id}.",
                    hint="Register the project in host.json projects.",
                )
                return

            assets: dict[str, bytes] = {}
            for name, items in fields.items():
                if name in ("projectID", "submissionID", "contentDigest", "package"):
                    continue
                for item in items:
                    # Form name is the relative path (e.g. assets/foo.png).
                    rel = name
                    if ".." in rel.split("/") or rel.startswith(("/", "\\")):
                        self._fail(400, "bad_request", f"Unsafe asset path: {rel}")
                        return
                    assets[rel] = item.data

            try:
                package, problems = validate_package_and_assets(
                    package_bytes, assets, submission_id=submission_id
                )
            except ValueError as exc:
                self._fail(400, "invalid_package", str(exc))
                return
            if problems:
                # Identity / schema issues vs missing assets.
                identityish = any(
                    "submissionID" in p or "schemaVersion" in p or "must be" in p or "missing id" in p
                    for p in problems
                )
                code = "invalid_package" if identityish else "incomplete_assets"
                self._fail(
                    400,
                    code,
                    "Package validation failed before acknowledge.",
                    hint="; ".join(problems[:8]),
                )
                return

            recomputed = compute_content_digest(package_bytes, assets, package)
            if claimed_digest.lower() != recomputed.lower():
                self._fail(
                    400,
                    "digest_mismatch",
                    "Claimed contentDigest does not match recomputed digest.",
                    hint=f"recomputed={recomputed}",
                )
                return

            # Complete execution packet required before durable acceptance (R4).
            prompt_bytes = assets.get("agent-prompt.txt")
            if prompt_bytes is None:
                self._fail(
                    400,
                    "incomplete_packet",
                    "Canonical agent-prompt.txt is required before acceptance.",
                    hint="Upload agent-prompt.txt with numbered requests; retry the same submissionID after fixing.",
                )
                return
            try:
                require_canonical_prompt_bytes(prompt_bytes, package)
            except ValueError as exc:
                self._fail(400, "incomplete_packet", str(exc))
                return

            try:
                executor_name = read_executor_name(state.config, project_id)
                require_known_executor(executor_name)
            except MissingExecutor as exc:
                self._fail(
                    400,
                    "missing_executor",
                    str(exc),
                    hint="Set executor in the project JSON to a registered name such as corral-cursor.",
                )
                return
            except UnknownExecutor as exc:
                self._fail(
                    400,
                    "unknown_executor",
                    str(exc),
                    hint="Set executor to a registered name such as corral-cursor.",
                )
                return

            # Accept always starts as submitted; dump does not wait for results.
            initial_state = "submitted"
            try:
                task, created = state.store.accept_or_reuse(
                    project_id=project_id,
                    submission_id=submission_id,
                    content_digest=recomputed,
                    package_bytes=package_bytes,
                    assets=assets,
                    initial_state=initial_state,
                )
            except ConflictError as exc:
                self._fail(
                    409,
                    "conflict",
                    "Same submissionID with a different contentDigest.",
                    hint=f"Existing remoteTaskID={exc.remote_task_id}",
                    existingDigest=exc.existing_digest,
                )
                return

            worker_meta: dict[str, Any] = {}
            if created and executor_name:
                dump_accepted_task(state.config, state.store, task, wait=False)
            elif created and state.auto_worker:
                # Dormant opt-in path. Named executor dump is the live path.
                worker_meta = enqueue_worker(
                    state.store,
                    task,
                    config=state.config,
                    state=state,
                    async_start=True,
                )
                task = worker_meta.get("task") or state.store.load_task(task["remoteTaskID"]) or task

            self._ok(
                task,
                status=200,
                created=created,
                reused=not created,
                workerRequestPath=worker_meta.get("workerRequestPath"),
            )

        def _handle_cancel(self, remote_task_id: str) -> None:
            task = state.store.load_task(remote_task_id)
            if task is None:
                self._fail(404, "not_found", f"No task for remoteTaskID {remote_task_id}.")
                return

            current = task.get("state")
            if current == "readyForReview":
                # Already finished successfully — report honestly, do not rewrite.
                self._ok(task)
                return

            # Mark cancel intent first so a racing starter cannot launch.
            result = cancel_worker_process(state, state.store, remote_task_id)
            task = dict(state.store.load_task(remote_task_id) or task)

            if result.get("uncertain") or result.get("stopped") is False:
                task["state"] = "working"
                task["summary"] = (
                    "Cancel requested but worker stop could not be confirmed; "
                    "do not treat as cancelled."
                )
                state.store.save_task(task)
                self._fail(
                    409,
                    "cancel_uncertain",
                    task["summary"],
                    hint=str(result.get("reason") or "process_still_alive"),
                    task=state.store.load_task(remote_task_id),
                )
                return

            task["state"] = "cancelled"
            if result.get("hadProcess"):
                task["summary"] = "Cancelled; worker process stopped."
            else:
                task["summary"] = "Cancelled before worker start."
            state.store.save_task(task)
            self._ok(state.store.load_task(remote_task_id))

    return Handler


def create_server(
    config: HostConfig,
    *,
    listen: Optional[str] = None,
    auto_worker: bool = False,
    advertise: bool = False,
) -> tuple[ThreadingHTTPServer, HostServerState]:
    listen_s = listen or config.listen
    host, _, port_s = listen_s.rpartition(":")
    if not host:
        host = "0.0.0.0"
    port = int(port_s)
    store = TaskStore(config.data_dir)
    state = HostServerState(config, store, auto_worker=auto_worker)
    advertiser: Advertiser | None = None
    if advertise:
        advertiser = Advertiser(
            [(pid, port) for pid in sorted(config.projects)]
            if advertisable(host) and port
            else []
        )
    state.advertiser = advertiser
    handler = make_handler(state)
    server = ThreadingHTTPServer((host, port), handler)
    return server, state


def serve_forever(
    config: HostConfig,
    *,
    listen: Optional[str] = None,
    auto_worker: bool = False,
    advertise: bool = True,
    on_ready: Optional[Callable[[ThreadingHTTPServer], None]] = None,
) -> None:
    server, state = create_server(
        config, listen=listen, auto_worker=auto_worker, advertise=advertise
    )
    if on_ready:
        on_ready(server)
    host, port = server.server_address[:2]
    advertiser = state.advertiser
    # Ephemeral binds (127.0.0.1:0) resolve the real port only after bind;
    # rebuild the entry list so discovery advertises the actual port.
    if advertiser is not None:
        advertiser.entries = (
            [(pid, port) for pid in sorted(config.projects)]
            if advertisable(str(host)) and port
            else []
        )
        advertiser.start()
    print(f"edithere-host listening on http://{host}:{port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("edithere-host shutting down", file=sys.stderr)
    finally:
        if advertiser is not None:
            advertiser.stop()
        server.server_close()
