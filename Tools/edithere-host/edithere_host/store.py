"""Durable task store under dataDir/tasks/<remoteTaskID>/."""

from __future__ import annotations

import json
import os
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


DESTINATION_ID_PREFIX = "local-host"


def destination_id_for_project(project_id: str) -> str:
    return f"{DESTINATION_ID_PREFIX}:{project_id}"


VALID_STATES = frozenset(
    {
        "submitted",
        "waitingForComputer",
        "working",
        "needsInformation",
        "readyForReview",
        "failed",
        "cancelled",
    }
)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_verification() -> dict[str, Any]:
    return {
        "codeChanged": False,
        "checksPassed": None,
        "artifactReady": False,
        "installed": False,
        "visuallyVerified": False,
    }


def new_task(
    *,
    remote_task_id: str,
    submission_id: str,
    project_id: str,
    content_digest: str,
    state: str = "submitted",
) -> dict[str, Any]:
    now = utc_now()
    return {
        "remoteTaskID": remote_task_id,
        "submissionID": submission_id,
        "projectID": project_id,
        "contentDigest": content_digest,
        "destinationID": destination_id_for_project(project_id),
        "state": state,
        "summary": "",
        "markOutcomes": [],
        "verification": default_verification(),
        "createdAt": now,
        "updatedAt": now,
    }


class TaskStore:
    """Thread-safe on-disk task persistence with project-scoped submission index."""

    def __init__(self, data_dir: Path):
        self.data_dir = Path(data_dir)
        self.tasks_dir = self.data_dir / "tasks"
        self.index_path = self.data_dir / "index" / "submissions.json"
        self._lock = threading.RLock()
        self.tasks_dir.mkdir(parents=True, exist_ok=True)
        self.index_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.index_path.is_file():
            self._write_json(self.index_path, {})

    def _read_json(self, path: Path) -> Any:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)

    def _write_json(self, path: Path, obj: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)

    def _load_index(self) -> dict[str, Any]:
        if not self.index_path.is_file():
            return {}
        return self._read_json(self.index_path)

    def _save_index(self, index: dict[str, Any]) -> None:
        self._write_json(self.index_path, index)

    @staticmethod
    def _index_key(project_id: str, submission_id: str) -> str:
        return f"{project_id}::{submission_id}"

    def task_dir(self, remote_task_id: str) -> Path:
        return self.tasks_dir / remote_task_id

    def package_dir(self, remote_task_id: str) -> Path:
        return self.task_dir(remote_task_id) / "package"

    def task_json_path(self, remote_task_id: str) -> Path:
        return self.task_dir(remote_task_id) / "task.json"

    def load_task(self, remote_task_id: str) -> Optional[dict[str, Any]]:
        path = self.task_json_path(remote_task_id)
        if not path.is_file():
            return None
        return self._read_json(path)

    def save_task(self, task: dict[str, Any]) -> None:
        with self._lock:
            task = dict(task)
            task["updatedAt"] = utc_now()
            remote = task["remoteTaskID"]
            self.task_dir(remote).mkdir(parents=True, exist_ok=True)
            self._write_json(self.task_json_path(remote), task)
            index = self._load_index()
            # Drop legacy sid:: overwrite keys — recovery is project-scoped only.
            sid_key = f"sid::{task['submissionID']}"
            if sid_key in index:
                del index[sid_key]
            key = self._index_key(task["projectID"], task["submissionID"])
            index[key] = {
                "remoteTaskID": remote,
                "projectID": task["projectID"],
                "submissionID": task["submissionID"],
                "contentDigest": task["contentDigest"],
            }
            self._save_index(index)

    def find_by_submission(
        self, submission_id: str, project_id: Optional[str] = None
    ) -> Optional[dict[str, Any]]:
        """Lookup by projectID::submissionID. project_id is required for recovery."""
        with self._lock:
            if not project_id:
                return None
            index = self._load_index()
            entry = index.get(self._index_key(project_id, submission_id))
            if not entry:
                # Fallback scan for older stores / partial indexes.
                for task in self.list_tasks():
                    if (
                        task.get("submissionID") == submission_id
                        and task.get("projectID") == project_id
                    ):
                        return task
                return None
            return self.load_task(entry["remoteTaskID"])

    def list_tasks(self) -> list[dict[str, Any]]:
        tasks: list[dict[str, Any]] = []
        if not self.tasks_dir.is_dir():
            return tasks
        for child in sorted(self.tasks_dir.iterdir()):
            if not child.is_dir():
                continue
            path = child / "task.json"
            if path.is_file():
                try:
                    tasks.append(self._read_json(path))
                except (OSError, json.JSONDecodeError):
                    continue
        return tasks

    def accept_or_reuse(
        self,
        *,
        project_id: str,
        submission_id: str,
        content_digest: str,
        package_bytes: bytes,
        assets: dict[str, bytes],
        initial_state: str = "submitted",
    ) -> tuple[dict[str, Any], bool]:
        """
        Persist a new submission or reuse an identical one.

        Reuse only when recomputed digest equals the stored task digest for the
        same project + submission. content_digest must already be the
        server-recomputed value.

        Returns (task, created).
        """
        with self._lock:
            existing = self.find_by_submission(submission_id, project_id=project_id)
            if existing is not None:
                if existing.get("contentDigest") == content_digest:
                    return existing, False
                raise ConflictError(
                    existing_digest=existing.get("contentDigest") or "",
                    remote_task_id=existing.get("remoteTaskID") or "",
                )

            remote_task_id = str(uuid.uuid4())
            task = new_task(
                remote_task_id=remote_task_id,
                submission_id=submission_id,
                project_id=project_id,
                content_digest=content_digest,
                state=initial_state,
            )
            pkg_dir = self.package_dir(remote_task_id)
            pkg_dir.mkdir(parents=True, exist_ok=True)
            (pkg_dir / "manifest.json").write_bytes(package_bytes)
            for rel, data in assets.items():
                dest = pkg_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            self.save_task(task)
            return task, True


class ConflictError(Exception):
    def __init__(self, existing_digest: str, remote_task_id: str):
        super().__init__("submission content digest conflict")
        self.existing_digest = existing_digest
        self.remote_task_id = remote_task_id


class StoreError(Exception):
    pass
