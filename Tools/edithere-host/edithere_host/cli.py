"""CLI entry for edithere-host."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional

from . import __version__
from .config import config_path, doctor_report, load_config
from .envelope import (
    EXIT_AUTH,
    EXIT_CONFLICT,
    EXIT_FAIL,
    EXIT_NOT_FOUND,
    EXIT_OK,
    EXIT_USAGE,
    emit,
    envelope,
    error_body,
    want_json,
)
from .advertise import SERVICE_TYPE, advertise_command, advertisable, service_name, txt_records
from .executors import MissingExecutor, UnknownExecutor
from .executors.dispatch import dump_accepted_task, read_executor_name, require_known_executor
from .package_util import (
    compute_content_digest,
    load_manifest,
    load_package_dir_assets,
    validate_package_and_assets,
)
from .server import serve_forever
from .store import ConflictError, TaskStore
from .worker import enqueue_worker

DESCRIBE = {
    "name": "edithere-host",
    "version": __version__,
    "destinationID": "local-host",
    "commands": {
        "serve": {
            "summary": "Run the durable HTTP receiver.",
            "flags": ["--config", "--listen", "--auto-worker", "--dry-run", "--json", "--no-advertise"],
        },
        "doctor": {
            "summary": "Validate host config, token env presence, and project checkouts.",
            "flags": ["--config", "--json"],
        },
        "status": {
            "summary": "List tasks (dormant; not the live dump path).",
            "flags": ["--config", "--json"],
        },
        "replay": {
            "summary": "Ingest a local exported package directory as if submitted.",
            "flags": ["PACKAGE_DIR", "--project", "--config", "--json", "--dry-run", "--auto-worker"],
        },
        "describe": {
            "summary": "Machine-readable CLI self-description.",
            "flags": ["--json"],
        },
    },
    "exitCodes": {
        "0": "ok",
        "1": "fail",
        "2": "usage",
        "3": "not_found",
        "4": "auth",
        "5": "conflict",
        "6": "timeout",
    },
    "http": {
        "POST /v1/submissions": "multipart accept evidence package",
        "GET /v1/submissions/{submissionID}?projectID=": "dormant task lookup (not the live dump path)",
        "GET /v1/projects/{projectID}/submissions/{submissionID}": "dormant task lookup (nested)",
        "GET /v1/tasks/{remoteTaskID}": "dormant task lookup",
        "POST /v1/tasks/{remoteTaskID}/cancel": "dormant cancel route; not the live dump path",
    },
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="edithere-host",
        description="EditHere development-host receiver (local HTTP destination).",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    p_serve = sub.add_parser("serve", help="Run the HTTP receiver")
    p_serve.add_argument("--config", default=None, help="Path to host.json")
    p_serve.add_argument("--listen", default=None, help="Override HOST:PORT")
    p_serve.add_argument(
        "--auto-worker",
        action="store_true",
        help=(
            "Dormant. Named executor dump is the live path; missing executor "
            "fails accept. Do not use this to skip setting executor."
        ),
    )
    p_serve.add_argument("--dry-run", action="store_true", help="Validate config; do not bind or write")
    p_serve.add_argument("--json", action="store_true", help="JSON envelope on stdout")
    p_serve.add_argument(
        "--no-advertise",
        action="store_true",
        help="Serve without Bonjour/DNS-SD advertisement (phones use bundled baseURL).",
    )

    p_doctor = sub.add_parser("doctor", help="Check configuration")
    p_doctor.add_argument("--config", default=None)
    p_doctor.add_argument("--json", action="store_true")

    p_status = sub.add_parser("status", help="List tasks")
    p_status.add_argument("--config", default=None)
    p_status.add_argument("--json", action="store_true")

    p_replay = sub.add_parser("replay", help="Ingest a local package directory")
    p_replay.add_argument("package_dir", metavar="PACKAGE_DIR")
    p_replay.add_argument("--project", required=True, help="projectID from host.json")
    p_replay.add_argument("--config", default=None)
    p_replay.add_argument("--json", action="store_true")
    p_replay.add_argument("--dry-run", action="store_true")
    p_replay.add_argument("--auto-worker", action="store_true")

    p_desc = sub.add_parser("describe", help="Self-description")
    p_desc.add_argument("--json", action="store_true")

    return parser


def _load_or_fail(config_arg: Optional[str], as_json: bool) -> tuple[Any, int]:
    try:
        return load_config(config_arg), EXIT_OK
    except FileNotFoundError as exc:
        payload = envelope(
            ok=False,
            error=error_body("not_found", str(exc), hint=f"Copy host.example.json to {config_path()}"),
            meta={"configPath": str(config_path(config_arg))},
        )
        return emit(payload, as_json=as_json, human_lines=[str(exc)]), EXIT_NOT_FOUND
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        payload = envelope(ok=False, error=error_body("config_error", str(exc)))
        return emit(payload, as_json=as_json, human_lines=[str(exc)]), EXIT_FAIL


def cmd_describe(args: argparse.Namespace) -> int:
    as_json = want_json(args.json)
    payload = envelope(ok=True, data=DESCRIBE, meta={"version": __version__})
    lines = [
        f"edithere-host {__version__}",
        "Commands: serve, doctor, status, replay, describe",
        "Destination: local-host",
    ]
    return emit(payload, as_json=as_json, human_lines=lines)


def cmd_doctor(args: argparse.Namespace) -> int:
    as_json = want_json(args.json)
    cfg, code = _load_or_fail(args.config, as_json)
    if code != EXIT_OK:
        return code
    report = doctor_report(cfg)
    ok = bool(report.get("ok"))
    payload = envelope(
        ok=ok,
        data=report,
        error=None if ok else error_body("doctor_failed", "Host configuration is incomplete."),
        meta={"configPath": str(cfg.path)},
    )
    if as_json:
        return emit(payload, as_json=True, exit_code=EXIT_OK if ok else EXIT_FAIL)
    lines = [
        f"config: {report['configPath']}",
        f"listen: {report['listen']}",
        f"dataDir: {report['dataDir']} (writable={report['dataDirWritable']})",
        f"token env {report['tokenEnv']}: {'present' if report['tokenPresent'] else 'MISSING'}",
        f"projects: {report['projectCount']}",
    ]
    for row in report["projects"]:
        lines.append(
            f"  - {row['projectID']}: checkout={'ok' if row['checkoutExists'] else 'MISSING'} "
            f"projectConfig={'ok' if row['projectConfigExists'] else 'MISSING'}"
        )
    lines.append("doctor: OK" if ok else "doctor: FAILED")
    return emit(payload, as_json=False, human_lines=lines, exit_code=EXIT_OK if ok else EXIT_FAIL)


def cmd_status(args: argparse.Namespace) -> int:
    as_json = want_json(args.json)
    cfg, code = _load_or_fail(args.config, as_json)
    if code != EXIT_OK:
        return code
    store = TaskStore(cfg.data_dir)
    tasks = store.list_tasks()
    data = {
        "dataDir": str(cfg.data_dir),
        "taskCount": len(tasks),
        "tasks": [
            {
                "remoteTaskID": t.get("remoteTaskID"),
                "submissionID": t.get("submissionID"),
                "projectID": t.get("projectID"),
                "state": t.get("state"),
                "updatedAt": t.get("updatedAt"),
            }
            for t in tasks
        ],
    }
    payload = envelope(ok=True, data=data, meta={"configPath": str(cfg.path)})
    if as_json:
        return emit(payload, as_json=True)
    lines = [f"dataDir: {cfg.data_dir}", f"tasks: {len(tasks)}"]
    for t in data["tasks"]:
        lines.append(
            f"  - {t['remoteTaskID']} project={t['projectID']} state={t['state']} submission={t['submissionID']}"
        )
    return emit(payload, as_json=False, human_lines=lines)


def cmd_serve(args: argparse.Namespace) -> int:
    as_json = want_json(args.json)
    cfg, code = _load_or_fail(args.config, as_json)
    if code != EXIT_OK:
        return code
    listen = args.listen or cfg.listen
    if args.dry_run:
        bind_port = _listen_port(listen)
        data = {
            "wouldListen": listen,
            "dataDir": str(cfg.data_dir),
            "autoWorker": bool(args.auto_worker),
            "tokenPresent": cfg.has_token(),
            "projectCount": len(cfg.projects),
            "advertise": advertise_plan(cfg, listen, disabled=args.no_advertise),
        }
        payload = envelope(ok=True, data=data, meta={"dryRun": True})
        lines = [
            f"dry-run: would listen on {listen}",
            f"dataDir: {cfg.data_dir}",
            f"auto-worker: {bool(args.auto_worker)}",
            f"token present: {cfg.has_token()}",
            f"advertise: {_advertise_line(data['advertise'])}",
        ]
        if bind_port is None:
            lines.append("advertise: LAN port unknown until bind; advertisement starts after bind.")
        return emit(payload, as_json=as_json, human_lines=lines)

    if not cfg.has_token():
        payload = envelope(
            ok=False,
            error=error_body(
                "unauthorized",
                f"Environment variable {cfg.token_env} is not set.",
                hint="Export a shared token before serving; never commit it.",
            ),
        )
        return emit(
            payload,
            as_json=as_json,
            human_lines=[f"Set {cfg.token_env} before serve."],
            exit_code=EXIT_AUTH,
        )

    # Bind and serve (blocking). Advertisement starts after the port is known.
    if as_json:
        # Emit a ready envelope then block; useful for agents that parse first line.
        ready = envelope(
            ok=True,
            data={
                "listen": listen,
                "autoWorker": bool(args.auto_worker),
                "advertise": advertise_plan(cfg, listen, disabled=args.no_advertise),
            },
            meta={"phase": "starting"},
        )
        sys.stdout.write(json.dumps(ready, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    try:
        serve_forever(
            cfg,
            listen=listen,
            auto_worker=bool(args.auto_worker),
            advertise=not args.no_advertise,
        )
    except OSError as exc:
        payload = envelope(ok=False, error=error_body("bind_failed", str(exc)))
        return emit(payload, as_json=as_json, human_lines=[str(exc)], exit_code=EXIT_FAIL)
    return EXIT_OK


def cmd_replay(args: argparse.Namespace) -> int:
    as_json = want_json(args.json)
    cfg, code = _load_or_fail(args.config, as_json)
    if code != EXIT_OK:
        return code

    package_dir = Path(args.package_dir).expanduser().resolve()
    if not package_dir.is_dir():
        payload = envelope(
            ok=False,
            error=error_body("not_found", f"Package directory not found: {package_dir}"),
        )
        return emit(payload, as_json=as_json, human_lines=[str(package_dir)], exit_code=EXIT_NOT_FOUND)

    project_id = args.project
    if project_id not in cfg.projects:
        payload = envelope(
            ok=False,
            error=error_body(
                "not_found",
                f"Unknown projectID {project_id}",
                hint="Register it under host.json projects.",
            ),
        )
        return emit(payload, as_json=as_json, human_lines=[f"Unknown project {project_id}"], exit_code=EXIT_NOT_FOUND)

    try:
        package = load_manifest(package_dir)
        package_bytes = (package_dir / "manifest.json").read_bytes()
        # Includes root agent-prompt.txt and page-*.png plus assets/.
        assets = load_package_dir_assets(package_dir, package)
        submission_id = str(package.get("id") or "")
        _, problems = validate_package_and_assets(
            package_bytes, assets, submission_id=submission_id or None
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        payload = envelope(ok=False, error=error_body("invalid_package", str(exc)))
        return emit(payload, as_json=as_json, human_lines=[str(exc)], exit_code=EXIT_FAIL)

    if problems:
        payload = envelope(
            ok=False,
            error=error_body("incomplete_assets", "Package assets incomplete.", hint="; ".join(problems[:8])),
        )
        return emit(payload, as_json=as_json, human_lines=problems, exit_code=EXIT_FAIL)

    if not submission_id:
        payload = envelope(ok=False, error=error_body("invalid_package", "manifest.json missing id"))
        return emit(payload, as_json=as_json, human_lines=["missing id"], exit_code=EXIT_FAIL)

    # Digest matches Swift: package bytes + sorted capture asset keys only.
    content_digest = compute_content_digest(package_bytes, assets, package)

    if args.dry_run:
        data = {
            "projectID": project_id,
            "submissionID": submission_id,
            "contentDigest": content_digest,
            "assetCount": len(assets),
            "wouldPersist": True,
            "autoWorker": bool(args.auto_worker),
        }
        payload = envelope(ok=True, data=data, meta={"dryRun": True})
        lines = [
            f"dry-run replay project={project_id} submission={submission_id}",
            f"digest={content_digest}",
            f"assets={len(assets)}",
        ]
        return emit(payload, as_json=as_json, human_lines=lines)

    try:
        executor_name = read_executor_name(cfg, project_id)
        require_known_executor(executor_name)
    except MissingExecutor as exc:
        payload = envelope(
            ok=False,
            error=error_body(
                "missing_executor",
                str(exc),
                hint="Set executor in the project JSON to a registered name such as corral-cursor.",
            ),
        )
        return emit(payload, as_json=as_json, human_lines=[str(exc)], exit_code=EXIT_FAIL)
    except UnknownExecutor as exc:
        payload = envelope(
            ok=False,
            error=error_body(
                "unknown_executor",
                str(exc),
                hint="Set executor to a registered name such as corral-cursor.",
            ),
        )
        return emit(payload, as_json=as_json, human_lines=[str(exc)], exit_code=EXIT_FAIL)

    store = TaskStore(cfg.data_dir)
    # Accept always starts submitted; named executor dump is the live path.
    initial_state = "submitted"
    try:
        task, created = store.accept_or_reuse(
            project_id=project_id,
            submission_id=submission_id,
            content_digest=content_digest,
            package_bytes=package_bytes,
            assets=assets,
            initial_state=initial_state,
        )
    except ConflictError as exc:
        payload = envelope(
            ok=False,
            data={"remoteTaskID": exc.remote_task_id, "existingDigest": exc.existing_digest},
            error=error_body("conflict", "Same submissionID with a different contentDigest."),
        )
        return emit(payload, as_json=as_json, human_lines=["conflict"], exit_code=EXIT_CONFLICT)

    worker_meta: dict[str, Any] = {}
    if created and executor_name:
        dump_accepted_task(cfg, store, task, wait=True)
    elif created and args.auto_worker:
        # Dormant opt-in path. Named executor dump is the live path.
        worker_meta = enqueue_worker(store, task, config=cfg, state=None, async_start=False)
        task = worker_meta.get("task") or task

    data = {
        "task": task,
        "created": created,
        "reused": not created,
        "workerRequestPath": worker_meta.get("workerRequestPath"),
    }
    payload = envelope(ok=True, data=data, meta={"configPath": str(cfg.path)})
    lines = [
        f"{'created' if created else 'reused'} remoteTaskID={task['remoteTaskID']}",
        f"state={task.get('state')} digest={task.get('contentDigest')}",
    ]
    return emit(payload, as_json=as_json, human_lines=lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return EXIT_USAGE
    try:
        if args.command == "describe":
            return cmd_describe(args)
        if args.command == "doctor":
            return cmd_doctor(args)
        if args.command == "status":
            return cmd_status(args)
        if args.command == "serve":
            return cmd_serve(args)
        if args.command == "replay":
            return cmd_replay(args)
        parser.error(f"unknown command {args.command}")
        return EXIT_USAGE
    except BrokenPipeError:
        return EXIT_OK
    except KeyboardInterrupt:
        return EXIT_FAIL


def _listen_port(listen: str) -> int | None:
    try:
        return int(listen.rsplit(":", 1)[1])
    except (IndexError, ValueError):
        return None


def advertise_plan(cfg: Any, listen: str, *, disabled: bool) -> dict[str, Any]:
    """Machine-readable LAN advertisement plan for serve/dry-run output."""
    port = _listen_port(listen)
    host = listen.rsplit(":", 1)[0] if ":" in listen else ""
    if disabled:
        return {"enabled": False, "reason": "no-advertise flag", "services": []}
    if not advertisable(host):
        return {
            "enabled": False,
            "reason": f"listen {host or '(empty)'} is loopback-only",
            "services": [],
        }
    services = []
    for project_id in sorted(cfg.projects):
        entry: dict[str, Any] = {
            "projectID": project_id,
            "serviceType": SERVICE_TYPE,
            "instance": service_name(project_id),
            "txt": txt_records(project_id),
        }
        if port:
            entry["port"] = port
        services.append(entry)
    return {"enabled": True, "services": services}


def _advertise_line(plan: dict[str, Any]) -> str:
    if not plan.get("enabled"):
        return f"off ({plan.get('reason', 'disabled')})"
    names = [s.get("instance", s["projectID"]) for s in plan.get("services", [])]
    return f"{SERVICE_TYPE} ({', '.join(names) or 'no projects'})"


# Re-export for tests that build ephemeral configs without files.
__all__ = ["main", "build_parser", "advertise_plan"]
