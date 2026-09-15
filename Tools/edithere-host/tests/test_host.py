"""stdlib unittest for edithere-host HTTP accept / worker / cancel / digest / recovery."""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import uuid
from http.client import HTTPConnection
from pathlib import Path
from urllib.parse import quote

# Allow `python3 -m unittest` from Tools/edithere-host
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from edithere_host.executors import register  # noqa: E402
from edithere_host.cli import cmd_replay  # noqa: E402
from edithere_host.config import parse_config  # noqa: E402
from edithere_host.package_util import compute_content_digest  # noqa: E402
from edithere_host.server import create_server  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[3] / "Fixtures" / "gate1" / "package"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _minimal_package(
    asset_rel: str,
    asset_sha: str,
    asset_len: int,
    *,
    overall: str = "",
    package_id: str | None = None,
    with_annotation: bool = True,
) -> dict:
    capture_id = str(uuid.uuid4())
    package_id = package_id or str(uuid.uuid4())
    annotations: list[dict] = []
    if with_annotation:
        annotations.append(
            {
                "id": str(uuid.uuid4()),
                "number": 1,
                "captureID": capture_id,
                "selectionKind": "bounds",
                "bounds": {"x": 0, "y": 0, "width": 10, "height": 10},
                "action": "changeText",
                "requestText": "Rename the title",
                "confidence": "high",
                "createdAt": "2026-09-12T00:00:00Z",
            }
        )
    return {
        "id": package_id,
        "schemaVersion": "1.0.0",
        "createdAt": "2026-09-12T00:00:00Z",
        "app": {
            "bundleIdentifier": "top.caozc.edithere.sample",
            "displayName": "EditHere Sample",
            "marketingVersion": "0.1.0",
            "buildNumber": "1",
        },
        "environment": {
            "screenWidth": 390,
            "screenHeight": 844,
            "screenScale": 3,
            "localeIdentifier": "en_US",
        },
        "overallInstruction": overall,
        "captures": [
            {
                "id": capture_id,
                "screenID": "home",
                "capturedAt": "2026-09-12T00:00:00Z",
                "orientation": "portrait",
                "originalImage": {
                    "relativePath": asset_rel,
                    "sha256": asset_sha,
                    "byteCount": asset_len,
                    "width": 10,
                    "height": 10,
                    "scale": 1,
                },
                "annotatedImage": {
                    "relativePath": asset_rel,
                    "sha256": asset_sha,
                    "byteCount": asset_len,
                    "width": 10,
                    "height": 10,
                    "scale": 1,
                },
                "coordinateSpace": "capture-pixels-top-left",
            }
        ],
        "annotations": annotations,
        "destinationID": "local-host",
    }


def _encode_multipart(fields: dict[str, str | bytes], files: dict[str, bytes]) -> tuple[bytes, str]:
    boundary = "----EditHereBoundary7MA4YWxkTrZu0gW"
    buf = io.BytesIO()
    for name, value in fields.items():
        buf.write(f"--{boundary}\r\n".encode())
        buf.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        if isinstance(value, bytes):
            buf.write(value)
        else:
            buf.write(value.encode("utf-8"))
        buf.write(b"\r\n")
    for name, data in files.items():
        filename = Path(name).name
        buf.write(f"--{boundary}\r\n".encode())
        buf.write(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode()
        )
        buf.write(b"Content-Type: application/octet-stream\r\n\r\n")
        buf.write(data)
        buf.write(b"\r\n")
    buf.write(f"--{boundary}--\r\n".encode())
    content_type = f"multipart/form-data; boundary={boundary}"
    return buf.getvalue(), content_type


def _canonical_prompt_text() -> str:
    return (
        "App: EditHere Sample\n"
        "Marks: blue rounded outline.\n"
        "Page 1 · home — marks 1\n"
        "\n"
        "1. Page 1 · home\n"
        "Rename the title\n"
        "On screen: Recent items\n"
    )


class _NoopDump:
    name = "host-test"

    def dump(self, *, task, package_dir, checkout) -> None:
        return


class HostHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmpdir.name)
        self.data_dir = self.tmp / "data"
        self.checkout = self.tmp / "checkout"
        self.checkout.mkdir(parents=True)
        project_cfg = self.checkout / "edithere.project.json"
        project_cfg.write_text(
            '{"schemaVersion":"1","projectID":"edithere-sample","executor":"host-test"}\n',
            encoding="utf-8",
        )

        self.checkout_b = self.tmp / "checkout-b"
        self.checkout_b.mkdir(parents=True)
        (self.checkout_b / "edithere.project.json").write_text(
            '{"schemaVersion":"1","projectID":"another-project","executor":"host-test"}\n',
            encoding="utf-8",
        )

        cfg_path = self.tmp / "host.json"
        raw = {
            "schemaVersion": "1",
            "listen": "127.0.0.1:0",
            "dataDir": str(self.data_dir),
            "tokenEnv": "EDITHHERE_HOST_TOKEN_TEST",
            "projects": {
                "edithere-sample": {
                    "checkout": str(self.checkout),
                    "projectConfig": "edithere.project.json",
                },
                "another-project": {
                    "checkout": str(self.checkout_b),
                    "projectConfig": "edithere.project.json",
                },
            },
        }
        cfg_path.write_text(json.dumps(raw), encoding="utf-8")
        self.config = parse_config(raw, cfg_path)
        self.token = "test-token-not-for-production"
        os.environ["EDITHHERE_HOST_TOKEN_TEST"] = self.token
        # Ensure no leftover worker cmd from other tests.
        os.environ.pop("EDITHHERE_WORKER_CMD", None)

        register(_NoopDump())
        self.server, self.state = create_server(self.config, listen="127.0.0.1:0", auto_worker=False)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
        self.asset_rel = "assets/page-1.png"
        self.asset_bytes = png
        self.asset_sha = _sha256(png)
        self.package = _minimal_package(self.asset_rel, self.asset_sha, len(png))
        self.submission_id = self.package["id"]
        self.package_bytes = json.dumps(self.package, separators=(",", ":"), sort_keys=True).encode()
        self.prompt_bytes = _canonical_prompt_text().encode("utf-8")
        self.default_assets = {
            self.asset_rel: self.asset_bytes,
            "agent-prompt.txt": self.prompt_bytes,
        }
        self.content_digest = compute_content_digest(
            self.package_bytes, self.default_assets, self.package
        )

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self._tmpdir.cleanup()
        os.environ.pop("EDITHHERE_HOST_TOKEN_TEST", None)
        os.environ.pop("EDITHHERE_WORKER_CMD", None)

    def _write_executor(self, name: str | None, *, project: str = "edithere-sample") -> None:
        checkout = self.checkout if project == "edithere-sample" else self.checkout_b
        payload: dict = {"schemaVersion": "1", "projectID": project}
        if name is not None:
            payload["executor"] = name
        (checkout / "edithere.project.json").write_text(
            json.dumps(payload) + "\n", encoding="utf-8"
        )

    def _restart_server(self, *, auto_worker: bool) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server, self.state = create_server(
            self.config, listen="127.0.0.1:0", auto_worker=auto_worker
        )
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

    def _post(
        self,
        *,
        digest: str | None = None,
        package_bytes: bytes | None = None,
        submission_id: str | None = None,
        project_id: str = "edithere-sample",
        assets: dict[str, bytes] | None = None,
        extra_files: dict[str, bytes] | None = None,
    ) -> tuple[int, dict]:
        pkg = package_bytes if package_bytes is not None else self.package_bytes
        sid = submission_id if submission_id is not None else self.submission_id
        fields: dict[str, str | bytes] = {
            "projectID": project_id,
            "submissionID": sid,
            "contentDigest": self.content_digest if digest is None else digest,
            "package": pkg,
        }
        files = dict(assets if assets is not None else self.default_assets)
        if extra_files:
            files.update(extra_files)
        body, content_type = _encode_multipart(fields, files)
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(
                "POST",
                "/v1/submissions",
                body=body,
                headers={
                    "Content-Type": content_type,
                    "X-EditHere-Token": self.token,
                    "Content-Length": str(len(body)),
                },
            )
            resp = conn.getresponse()
            raw = resp.read()
            return resp.status, json.loads(raw.decode("utf-8"))
        finally:
            conn.close()

    def _get_submission(
        self, submission_id: str, *, project_id: str | None = None, use_header: bool = False
    ) -> tuple[int, dict]:
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            path = f"/v1/submissions/{submission_id}"
            headers = {"X-EditHere-Token": self.token}
            if project_id and use_header:
                headers["X-EditHere-Project-ID"] = project_id
            elif project_id:
                path = f"{path}?projectID={quote(project_id)}"
            conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def _cancel(self, remote_task_id: str) -> tuple[int, dict]:
        conn = HTTPConnection("127.0.0.1", self.port, timeout=15)
        try:
            conn.request(
                "POST",
                f"/v1/tasks/{remote_task_id}/cancel",
                headers={"X-EditHere-Token": self.token},
            )
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def _get_task(self, remote_task_id: str) -> tuple[int, dict]:
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(
                "GET",
                f"/v1/tasks/{remote_task_id}",
                headers={"X-EditHere-Token": self.token},
            )
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def test_idempotent_submit_conflict_and_get(self) -> None:
        status1, body1 = self._post()
        self.assertEqual(status1, 200, body1)
        self.assertTrue(body1["ok"])
        task1 = body1["data"]
        remote1 = task1["remoteTaskID"]
        self.assertEqual(task1["state"], "submitted")
        self.assertTrue(body1["meta"].get("created"))

        status2, body2 = self._post()
        self.assertEqual(status2, 200, body2)
        self.assertTrue(body2["ok"])
        task2 = body2["data"]
        self.assertEqual(task2["remoteTaskID"], remote1)
        self.assertTrue(body2["meta"].get("reused"))
        self.assertFalse(body2["meta"].get("created"))

        tasks_root = self.data_dir / "tasks"
        task_dirs = [p for p in tasks_root.iterdir() if p.is_dir()]
        self.assertEqual(len(task_dirs), 1)

        status3, body3 = self._post(digest="0" * 64)
        self.assertEqual(status3, 400, body3)
        self.assertFalse(body3["ok"])
        self.assertEqual(body3["error"]["code"], "digest_mismatch")

        # Real content change with matching recomputed digest → conflict.
        changed = dict(self.package)
        changed["overallInstruction"] = "different work"
        changed_bytes = json.dumps(changed, separators=(",", ":"), sort_keys=True).encode()
        new_digest = compute_content_digest(changed_bytes, self.default_assets, changed)
        status_conflict, body_conflict = self._post(
            package_bytes=changed_bytes, digest=new_digest
        )
        self.assertEqual(status_conflict, 409, body_conflict)
        self.assertEqual(body_conflict["error"]["code"], "conflict")

        status4, body4 = self._get_submission(self.submission_id, project_id="edithere-sample")
        self.assertEqual(status4, 200, body4)
        self.assertTrue(body4["ok"])
        self.assertEqual(body4["data"]["remoteTaskID"], remote1)
        self.assertEqual(body4["data"]["submissionID"], self.submission_id)

    def test_empty_package_rejected(self) -> None:
        empty = b"{}"
        status, body = self._post(
            package_bytes=empty,
            digest=_sha256(empty),
            submission_id=str(uuid.uuid4()),
            assets={},
        )
        self.assertEqual(status, 400, body)
        self.assertFalse(body["ok"])
        self.assertIn(body["error"]["code"], ("invalid_package", "incomplete_assets"))

    def test_stale_digest_with_changed_content_rejected(self) -> None:
        # First accept a valid package.
        status1, body1 = self._post()
        self.assertEqual(status1, 200, body1)

        # Change overallInstruction but claim the old digest (review reproduction).
        changed = dict(self.package)
        changed["overallInstruction"] = "CHANGED REQUEST TEXT"
        changed_bytes = json.dumps(changed, separators=(",", ":"), sort_keys=True).encode()
        status2, body2 = self._post(package_bytes=changed_bytes, digest=self.content_digest)
        self.assertEqual(status2, 400, body2)
        self.assertEqual(body2["error"]["code"], "digest_mismatch")

    def test_project_scoped_recovery(self) -> None:
        # Same submissionID into two projects.
        status_a, body_a = self._post(project_id="edithere-sample")
        self.assertEqual(status_a, 200, body_a)
        remote_a = body_a["data"]["remoteTaskID"]

        status_b, body_b = self._post(project_id="another-project")
        self.assertEqual(status_b, 200, body_b)
        remote_b = body_b["data"]["remoteTaskID"]
        self.assertNotEqual(remote_a, remote_b)

        # Without projectID → 400
        status_missing, body_missing = self._get_submission(self.submission_id)
        self.assertEqual(status_missing, 400, body_missing)
        self.assertEqual(body_missing["error"]["code"], "bad_request")

        status_a2, body_a2 = self._get_submission(self.submission_id, project_id="edithere-sample")
        self.assertEqual(status_a2, 200, body_a2)
        self.assertEqual(body_a2["data"]["remoteTaskID"], remote_a)
        self.assertEqual(body_a2["data"]["projectID"], "edithere-sample")

        status_b2, body_b2 = self._get_submission(self.submission_id, project_id="another-project")
        self.assertEqual(status_b2, 200, body_b2)
        self.assertEqual(body_b2["data"]["remoteTaskID"], remote_b)
        self.assertEqual(body_b2["data"]["projectID"], "another-project")

        # Nested route also works.
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(
                "GET",
                f"/v1/projects/edithere-sample/submissions/{self.submission_id}",
                headers={"X-EditHere-Token": self.token},
            )
            resp = conn.getresponse()
            nested = json.loads(resp.read().decode())
            self.assertEqual(resp.status, 200, nested)
            self.assertEqual(nested["data"]["remoteTaskID"], remote_a)
        finally:
            conn.close()

    def test_auto_worker_without_executor_is_rejected(self) -> None:
        self._write_executor(None)
        self._restart_server(auto_worker=True)
        status, body = self._post()
        self.assertEqual(status, 400, body)
        self.assertEqual(body["error"]["code"], "missing_executor")
        tasks_root = self.data_dir / "tasks"
        self.assertFalse(tasks_root.is_dir() and any(tasks_root.iterdir()))

    def test_missing_prompt_is_assembled_on_the_host(self) -> None:
        assets_no_prompt = {self.asset_rel: self.asset_bytes}
        status, body = self._post(digest="", assets=assets_no_prompt)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"])
        self.assertTrue(body["meta"].get("created"))
        task = body["data"]
        stored = (
            self.data_dir / "tasks" / task["remoteTaskID"] / "package" / "agent-prompt.txt"
        )
        prompt = stored.read_text(encoding="utf-8")
        self.assertIn("1. Page 1 · home", prompt)
        self.assertIn("Rename the title", prompt)

    def test_preview_assembles_prompt_without_dump(self) -> None:
        assets_no_prompt = {self.asset_rel: self.asset_bytes}
        fields: dict[str, str | bytes] = {
            "projectID": "edithere-sample",
            "submissionID": self.submission_id,
            "package": self.package_bytes,
        }
        body, content_type = _encode_multipart(fields, assets_no_prompt)
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(
                "POST",
                "/v1/preview",
                body=body,
                headers={
                    "Content-Type": content_type,
                    "X-EditHere-Token": self.token,
                    "Content-Length": str(len(body)),
                },
            )
            resp = conn.getresponse()
            payload = json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()
        self.assertEqual(resp.status, 200, payload)
        self.assertTrue(payload["ok"])
        self.assertIn("1. Page 1 · home", payload["data"]["prompt"])
        tasks_root = self.data_dir / "tasks"
        self.assertFalse(tasks_root.is_dir() and any(tasks_root.iterdir()))

    def test_options_allows_browser_preflight(self) -> None:
        conn = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(
                "OPTIONS",
                "/v1/preview",
                headers={"Origin": "https://example.com"},
            )
            resp = conn.getresponse()
            resp.read()
        finally:
            conn.close()
        self.assertEqual(resp.status, 204)
        self.assertEqual(resp.getheader("Access-Control-Allow-Origin"), "*")
        allow = resp.getheader("Access-Control-Allow-Headers") or ""
        self.assertIn("X-EditHere-Token", allow)

    def test_stale_digest_without_assembled_prompt_is_rejected(self) -> None:
        assets_no_prompt = {self.asset_rel: self.asset_bytes}
        digest_no_prompt = compute_content_digest(
            self.package_bytes, assets_no_prompt, self.package
        )
        status, body = self._post(digest=digest_no_prompt, assets=assets_no_prompt)
        self.assertEqual(status, 400, body)
        self.assertEqual(body["error"]["code"], "digest_mismatch")

    @unittest.skip(
        "Dormant auto-worker is unreachable: missing executor now fails accept."
    )
    def test_cancel_stops_marker_worker(self) -> None:
        markers = self.tmp / "markers"
        markers.mkdir()
        start_marker = markers / "started"
        second_marker = markers / "second"
        worker_script = self.tmp / "marker_worker.py"
        worker_script.write_text(
            "\n".join(
                [
                    "import os, time, sys",
                    f"start = {str(start_marker)!r}",
                    f"second = {str(second_marker)!r}",
                    "open(start, 'w').write('1')",
                    "time.sleep(2.0)",
                    "open(second, 'w').write('2')",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        os.environ["EDITHHERE_WORKER_CMD"] = f"{sys.executable} {worker_script}"
        self._restart_server(auto_worker=True)

        t0 = time.monotonic()
        status, body = self._post()
        submit_elapsed = time.monotonic() - t0
        self.assertEqual(status, 200, body)
        self.assertLess(submit_elapsed, 1.5, "submit must return before worker finishes")
        remote = body["data"]["remoteTaskID"]
        self.assertIn(body["data"]["state"], ("submitted", "working"))

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not start_marker.is_file():
            time.sleep(0.05)
        self.assertTrue(start_marker.is_file(), "worker did not create start marker")

        cancel_status, cancel_body = self._cancel(remote)
        self.assertEqual(cancel_status, 200, cancel_body)
        self.assertEqual(cancel_body["data"]["state"], "cancelled")

        time.sleep(1.2)
        self.assertFalse(
            second_marker.is_file(),
            "second marker must not be written after cancel",
        )

    @unittest.skip(
        "Dormant auto-worker is unreachable: missing executor now fails accept."
    )
    def test_cancel_before_start_barrier(self) -> None:
        markers = self.tmp / "markers-before"
        markers.mkdir()
        start_marker = markers / "started"
        worker_script = self.tmp / "before_start_worker.py"
        worker_script.write_text(
            "\n".join(
                [
                    "import time",
                    f"open({str(start_marker)!r}, 'w').write('1')",
                    "time.sleep(3.0)",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        os.environ["EDITHHERE_WORKER_CMD"] = f"{sys.executable} {worker_script}"
        self._restart_server(auto_worker=True)
        barrier = threading.Barrier(2, timeout=10)
        self.state.start_barrier = barrier

        status, body = self._post()
        self.assertEqual(status, 200, body)
        remote = body["data"]["remoteTaskID"]
        self.assertEqual(body["data"]["state"], "submitted")

        cancel_status, cancel_body = self._cancel(remote)
        self.assertEqual(cancel_status, 200, cancel_body)
        self.assertEqual(cancel_body["data"]["state"], "cancelled")

        try:
            barrier.wait()
        except threading.BrokenBarrierError:
            pass
        time.sleep(0.8)
        self.assertFalse(start_marker.is_file(), "worker must not start after cancel")

        status_t, body_t = self._get_task(remote)
        self.assertEqual(status_t, 200, body_t)
        self.assertEqual(body_t["data"]["state"], "cancelled")

    @unittest.skip(
        "Dormant auto-worker is unreachable: missing executor now fails accept."
    )
    def test_cancel_after_receiver_restart(self) -> None:
        markers = self.tmp / "markers-restart"
        markers.mkdir()
        start_marker = markers / "started"
        second_marker = markers / "second"
        worker_script = self.tmp / "restart_worker.py"
        worker_script.write_text(
            "\n".join(
                [
                    "import time",
                    f"open({str(start_marker)!r}, 'w').write('1')",
                    "time.sleep(3.0)",
                    f"open({str(second_marker)!r}, 'w').write('2')",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        os.environ["EDITHHERE_WORKER_CMD"] = f"{sys.executable} {worker_script}"
        self._restart_server(auto_worker=True)

        status, body = self._post()
        self.assertEqual(status, 200, body)
        remote = body["data"]["remoteTaskID"]

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not start_marker.is_file():
            time.sleep(0.05)
        self.assertTrue(start_marker.is_file())

        # Drop in-memory worker map; cancel must recover from persisted pid.
        self._restart_server(auto_worker=False)
        cancel_status, cancel_body = self._cancel(remote)
        self.assertEqual(cancel_status, 200, cancel_body)
        self.assertEqual(cancel_body["data"]["state"], "cancelled")

        time.sleep(1.5)
        self.assertFalse(second_marker.is_file())

    @unittest.skip(
        "Dormant auto-worker is unreachable: missing executor now fails accept."
    )
    def test_valid_results_ready_for_review(self) -> None:
        worker_script = self.tmp / "results_ok_worker.py"
        worker_script.write_text(
            "\n".join(
                [
                    "import json, os, pathlib",
                    "task_dir = pathlib.Path(os.environ['EDITHHERE_TASK_DIR'])",
                    "task = json.loads((task_dir / 'task.json').read_text())",
                    "payload = {",
                    "  'remoteTaskID': task['remoteTaskID'],",
                    "  'submissionID': task['submissionID'],",
                    "  'summary': 'Edited title',",
                    "  'markOutcomes': [{",
                    "    'number': 1, 'status': 'changed', 'summary': 'Renamed', 'paths': ['a.swift']",
                    "  }],",
                    "  'verification': {",
                    "    'codeChanged': True, 'checksPassed': True, 'artifactReady': False,",
                    "    'installed': False, 'visuallyVerified': False",
                    "  }",
                    "}",
                    "(task_dir / 'results.json').write_text(json.dumps(payload))",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        os.environ["EDITHHERE_WORKER_CMD"] = f"{sys.executable} {worker_script}"
        self._restart_server(auto_worker=True)

        status, body = self._post()
        self.assertEqual(status, 200, body)
        remote = body["data"]["remoteTaskID"]

        deadline = time.monotonic() + 5.0
        final = None
        while time.monotonic() < deadline:
            _, tbody = self._get_task(remote)
            final = tbody["data"]
            if final["state"] in ("readyForReview", "failed", "cancelled"):
                break
            time.sleep(0.05)
        self.assertIsNotNone(final)
        assert final is not None
        self.assertEqual(final["state"], "readyForReview", final)
        self.assertEqual(final["markOutcomes"][0]["status"], "changed")
        self.assertTrue(final["verification"]["codeChanged"])

    @unittest.skip(
        "Dormant auto-worker is unreachable: missing executor now fails accept."
    )
    def test_invalid_results_fail_not_ready(self) -> None:
        worker_script = self.tmp / "results_bad_worker.py"
        worker_script.write_text(
            "\n".join(
                [
                    "import os, pathlib",
                    "task_dir = pathlib.Path(os.environ['EDITHHERE_TASK_DIR'])",
                    "(task_dir / 'results.json').write_text('{not-json')",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        os.environ["EDITHHERE_WORKER_CMD"] = f"{sys.executable} {worker_script}"
        self._restart_server(auto_worker=True)

        status, body = self._post()
        self.assertEqual(status, 200, body)
        remote = body["data"]["remoteTaskID"]

        deadline = time.monotonic() + 5.0
        final = None
        while time.monotonic() < deadline:
            _, tbody = self._get_task(remote)
            final = tbody["data"]
            if final["state"] in ("readyForReview", "failed", "cancelled"):
                break
            time.sleep(0.05)
        self.assertIsNotNone(final)
        assert final is not None
        self.assertEqual(final["state"], "failed", final)
        self.assertIn("invalid", final["summary"].lower())

    def test_project_scoped_token(self) -> None:
        sample_token = "sample-only-token"
        other_token = "other-only-token"
        os.environ["EDITHHERE_TOKEN_SAMPLE_TEST"] = sample_token
        os.environ["EDITHHERE_TOKEN_OTHER_TEST"] = other_token
        self.addCleanup(lambda: os.environ.pop("EDITHHERE_TOKEN_SAMPLE_TEST", None))
        self.addCleanup(lambda: os.environ.pop("EDITHHERE_TOKEN_OTHER_TEST", None))

        cfg_path = self.tmp / "host-scoped.json"
        raw = {
            "schemaVersion": "1",
            "listen": "127.0.0.1:0",
            "dataDir": str(self.data_dir),
            "tokenEnv": "EDITHHERE_HOST_TOKEN_TEST",
            "projects": {
                "edithere-sample": {
                    "checkout": str(self.checkout),
                    "projectConfig": "edithere.project.json",
                    "tokenEnv": "EDITHHERE_TOKEN_SAMPLE_TEST",
                },
                "another-project": {
                    "checkout": str(self.checkout_b),
                    "projectConfig": "edithere.project.json",
                    "tokenEnv": "EDITHHERE_TOKEN_OTHER_TEST",
                },
            },
        }
        cfg_path.write_text(json.dumps(raw), encoding="utf-8")
        self.config = parse_config(raw, cfg_path)
        self.token = sample_token
        self._restart_server(auto_worker=False)

        status_ok, body_ok = self._post(project_id="edithere-sample")
        self.assertEqual(status_ok, 200, body_ok)

        # Sample token must not authorize another project.
        bad_id = str(uuid.uuid4())
        bad_pkg = dict(self.package)
        bad_pkg["id"] = bad_id
        bad_bytes = json.dumps(bad_pkg, separators=(",", ":"), sort_keys=True).encode()
        bad_digest = compute_content_digest(bad_bytes, self.default_assets, bad_pkg)
        status_bad, body_bad = self._post(
            project_id="another-project",
            submission_id=bad_id,
            package_bytes=bad_bytes,
            digest=bad_digest,
        )
        self.assertEqual(status_bad, 401, body_bad)
        self.assertEqual(body_bad["error"]["code"], "unauthorized")

        self.token = other_token
        other_id = str(uuid.uuid4())
        other_pkg = dict(self.package)
        other_pkg["id"] = other_id
        other_bytes = json.dumps(other_pkg, separators=(",", ":"), sort_keys=True).encode()
        other_digest = compute_content_digest(other_bytes, self.default_assets, other_pkg)
        status_other, body_other = self._post(
            project_id="another-project",
            submission_id=other_id,
            package_bytes=other_bytes,
            digest=other_digest,
        )
        self.assertEqual(status_other, 200, body_other)


class ReplayPromptTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmpdir.name)
        self.data_dir = self.tmp / "data"
        self.checkout = self.tmp / "checkout"
        self.checkout.mkdir(parents=True)
        (self.checkout / "edithere.project.json").write_text(
            '{"schemaVersion":"1","projectID":"edithere-sample","executor":"host-test"}\n',
            encoding="utf-8",
        )
        self.cfg_path = self.tmp / "host.json"
        raw = {
            "schemaVersion": "1",
            "listen": "127.0.0.1:0",
            "dataDir": str(self.data_dir),
            "tokenEnv": "EDITHHERE_HOST_TOKEN_TEST",
            "projects": {
                "edithere-sample": {
                    "checkout": str(self.checkout),
                    "projectConfig": "edithere.project.json",
                }
            },
        }
        self.cfg_path.write_text(json.dumps(raw), encoding="utf-8")
        os.environ["EDITHHERE_HOST_TOKEN_TEST"] = "test-token"
        os.environ.pop("EDITHHERE_WORKER_CMD", None)
        register(_NoopDump())

    def tearDown(self) -> None:
        self._tmpdir.cleanup()
        os.environ.pop("EDITHHERE_HOST_TOKEN_TEST", None)
        os.environ.pop("EDITHHERE_WORKER_CMD", None)

    def test_replay_preserves_gate1_canonical_prompt(self) -> None:
        self.assertTrue(FIXTURES.is_dir(), f"missing fixture {FIXTURES}")
        original = (FIXTURES / "agent-prompt.txt").read_text(encoding="utf-8")
        self.assertIn("1. Page 1", original)
        self.assertIn("Do not guess", original)

        # Copy fixture so we do not mutate the repo copy.
        pkg = self.tmp / "package"
        shutil.copytree(FIXTURES, pkg)

        ns = type(
            "Args",
            (),
            {
                "package_dir": str(pkg),
                "project": "edithere-sample",
                "config": str(self.cfg_path),
                "json": True,
                "dry_run": False,
                "auto_worker": True,
            },
        )()
        code = cmd_replay(ns)
        self.assertEqual(code, 0)

        tasks = list((self.data_dir / "tasks").iterdir())
        self.assertEqual(len(tasks), 1)
        stored = (tasks[0] / "package" / "agent-prompt.txt").read_text(encoding="utf-8")
        self.assertEqual(stored, original)
        self.assertIn("Rename the title to \"Recently used\"", stored)
        self.assertNotIn("marks 1, 2, 3, 4, 5\n\nApp:", stored)  # not catalog-prepended junk

        task = json.loads((tasks[0] / "task.json").read_text(encoding="utf-8"))
        self.assertIn(task["state"], ("waitingForComputer", "submitted"))
        self.assertNotEqual(task["state"], "working")


if __name__ == "__main__":
    unittest.main()
