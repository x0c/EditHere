"""Named-executor dump: fire-and-forget, no result wait."""

from __future__ import annotations

import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
import sys

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(TESTS) not in sys.path:
    sys.path.insert(0, str(TESTS))

from edithere_host.config import parse_config  # noqa: E402
from edithere_host.executors import MissingExecutor, UnknownExecutor, get, register  # noqa: E402
from edithere_host.executors.corral_cursor import CorralCursorExecutor, _image_files  # noqa: E402
from edithere_host.executors.dispatch import (  # noqa: E402
    dump_accepted_task,
    read_executor_name,
    require_known_executor,
)
from edithere_host.package_util import compute_content_digest  # noqa: E402
from edithere_host.server import create_server  # noqa: E402
from edithere_host.store import TaskStore  # noqa: E402

from test_host import (  # noqa: E402
    _canonical_prompt_text,
    _encode_multipart,
    _minimal_package,
    _sha256,
)

from http.client import HTTPConnection  # noqa: E402


class _ProbeExecutor:
    name = "probe"

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.started = threading.Event()

    def dump(self, *, task, package_dir, checkout) -> None:
        self.calls.append(
            {
                "task": task["remoteTaskID"],
                "package_dir": Path(package_dir),
                "checkout": Path(checkout),
                "results_existed": (Path(package_dir).parent / "results.json").is_file(),
            }
        )
        self.started.set()


class ExecutorDumpTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmpdir.name)
        self.data_dir = self.tmp / "data"
        self.checkout = self.tmp / "checkout"
        self.checkout.mkdir(parents=True)
        self.project_cfg = self.checkout / "edithere.project.json"
        self.project_cfg.write_text(
            json.dumps({"schemaVersion": "1", "projectID": "edithere-sample"}) + "\n",
            encoding="utf-8",
        )
        raw = {
            "schemaVersion": "1",
            "listen": "127.0.0.1:0",
            "dataDir": str(self.data_dir),
            "tokenEnv": "EDITHHERE_HOST_TOKEN_EXEC",
            "projects": {
                "edithere-sample": {
                    "checkout": str(self.checkout),
                    "projectConfig": "edithere.project.json",
                }
            },
        }
        cfg_path = self.tmp / "host.json"
        cfg_path.write_text(json.dumps(raw), encoding="utf-8")
        self.config = parse_config(raw, cfg_path)
        self.token = "exec-token"
        os.environ["EDITHHERE_HOST_TOKEN_EXEC"] = self.token
        os.environ.pop("EDITHHERE_WORKER_CMD", None)
        self.probe = _ProbeExecutor()
        register(self.probe)
        self.server, self.state = create_server(self.config, listen="127.0.0.1:0")
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
        self.asset_rel = "assets/page-1.png"
        self.asset_bytes = png
        self.package = _minimal_package(self.asset_rel, _sha256(png), len(png))
        self.package_bytes = json.dumps(self.package, separators=(",", ":"), sort_keys=True).encode()
        self.prompt_bytes = _canonical_prompt_text().encode("utf-8")
        self.assets = {self.asset_rel: png, "agent-prompt.txt": self.prompt_bytes}
        self.digest = compute_content_digest(self.package_bytes, self.assets, self.package)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self._tmpdir.cleanup()
        os.environ.pop("EDITHHERE_HOST_TOKEN_EXEC", None)

    def _write_executor(self, name: str | None) -> None:
        payload: dict = {"schemaVersion": "1", "projectID": "edithere-sample"}
        if name is not None:
            payload["executor"] = name
        self.project_cfg.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    def _post(self) -> tuple[int, dict]:
        fields = {
            "projectID": "edithere-sample",
            "submissionID": self.package["id"],
            "contentDigest": self.digest,
            "package": self.package_bytes,
        }
        body, content_type = _encode_multipart(fields, self.assets)
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
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def test_absent_executor_rejects_before_accept(self) -> None:
        status, body = self._post()
        self.assertEqual(status, 400, body)
        self.assertEqual(body["error"]["code"], "missing_executor")
        self.assertFalse(self.probe.started.wait(0.3))
        self.assertEqual(self.probe.calls, [])
        store = TaskStore(self.data_dir)
        self.assertEqual(store.list_tasks(), [])

    def test_unknown_executor_rejects_before_accept(self) -> None:
        self._write_executor("not-a-real-executor")
        status, body = self._post()
        self.assertEqual(status, 400, body)
        self.assertEqual(body["error"]["code"], "unknown_executor")
        store = TaskStore(self.data_dir)
        self.assertEqual(store.list_tasks(), [])

    def test_named_executor_dumps_without_results_file(self) -> None:
        self._write_executor("probe")
        status, body = self._post()
        self.assertEqual(status, 200, body)
        self.assertTrue(self.probe.started.wait(2.0), "dump thread did not run")
        self.assertEqual(len(self.probe.calls), 1)
        self.assertFalse(self.probe.calls[0]["results_existed"])
        remote = body["data"]["remoteTaskID"]
        self.assertEqual(self.probe.calls[0]["task"], remote)
        self.assertEqual(body["data"]["state"], "submitted")
        results = self.data_dir / "tasks" / remote / "results.json"
        self.assertFalse(results.is_file())


class DispatchHelpersTests(unittest.TestCase):
    def test_require_known_blank_raises(self) -> None:
        with self.assertRaises(MissingExecutor):
            require_known_executor("")

    def test_require_known_corral_cursor(self) -> None:
        require_known_executor("corral-cursor")
        self.assertIsNotNone(get("corral-cursor"))

    def test_require_unknown_raises(self) -> None:
        with self.assertRaises(UnknownExecutor):
            require_known_executor("nope")

    def test_read_executor_name(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        try:
            checkout = Path(tmp.name) / "co"
            checkout.mkdir()
            (checkout / "p.json").write_text(
                '{"executor":"corral-cursor"}\n', encoding="utf-8"
            )
            cfg = parse_config(
                {
                    "schemaVersion": "1",
                    "listen": "127.0.0.1:9",
                    "dataDir": str(Path(tmp.name) / "d"),
                    "tokenEnv": "T",
                    "projects": {
                        "p": {"checkout": str(checkout), "projectConfig": "p.json"}
                    },
                },
                Path(tmp.name) / "host.json",
            )
            self.assertEqual(read_executor_name(cfg, "p"), "corral-cursor")
        finally:
            tmp.cleanup()

    def test_dump_wait_does_not_look_for_results(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        try:
            root = Path(tmp.name)
            checkout = root / "co"
            checkout.mkdir()
            (checkout / "p.json").write_text('{"executor":"probe"}\n', encoding="utf-8")
            cfg = parse_config(
                {
                    "schemaVersion": "1",
                    "listen": "127.0.0.1:9",
                    "dataDir": str(root / "d"),
                    "tokenEnv": "T",
                    "projects": {
                        "p": {"checkout": str(checkout), "projectConfig": "p.json"}
                    },
                },
                root / "host.json",
            )
            store = TaskStore(root / "d")
            png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8
            package = _minimal_package("assets/page-1.png", _sha256(png), len(png))
            package_bytes = json.dumps(package, separators=(",", ":")).encode()
            assets = {
                "assets/page-1.png": png,
                "agent-prompt.txt": _canonical_prompt_text().encode(),
            }
            digest = compute_content_digest(package_bytes, assets, package)
            task, created = store.accept_or_reuse(
                project_id="p",
                submission_id=package["id"],
                content_digest=digest,
                package_bytes=package_bytes,
                assets=assets,
                initial_state="submitted",
            )
            self.assertTrue(created)
            probe = _ProbeExecutor()
            register(probe)
            name = dump_accepted_task(cfg, store, task, wait=True)
            self.assertEqual(name, "probe")
            self.assertEqual(len(probe.calls), 1)
            self.assertFalse(probe.calls[0]["results_existed"])
            self.assertFalse((store.task_dir(task["remoteTaskID"]) / "results.json").is_file())
        finally:
            tmp.cleanup()


class CorralCursorUnitTests(unittest.TestCase):
    def test_prefers_root_page_png(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        try:
            pkg = Path(tmp.name)
            (pkg / "page-1.png").write_bytes(b"page")
            (pkg / "assets").mkdir()
            (pkg / "assets" / "page-annotated.png").write_bytes(b"ann")
            package = {
                "captures": [
                    {"annotatedImage": {"relativePath": "assets/page-annotated.png"}}
                ]
            }
            files = _image_files(package, pkg)
            self.assertEqual(files, [pkg / "page-1.png"])
        finally:
            tmp.cleanup()

    def test_dump_injects_images_then_prompt_and_returns(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        try:
            pkg = Path(tmp.name)
            (pkg / "page-1.png").write_bytes(b"img-bytes")
            (pkg / "manifest.json").write_text("{}", encoding="utf-8")
            (pkg / "agent-prompt.txt").write_text(
                _canonical_prompt_text(), encoding="utf-8"
            )
            checkout = pkg / "co"
            checkout.mkdir()
            hub = MagicMock()
            hub.new_session.return_value = {"key": "sess-1"}
            with patch(
                "edithere_host.executors.corral_cursor._ensure_corral_on_path",
                return_value=Path("/unused"),
            ), patch(
                "edithere_host.executors.corral_cursor._settle_seconds",
                return_value=0.0,
            ), patch.dict(
                "sys.modules",
                {
                    "corral": MagicMock(),
                    "corral.remote": MagicMock(),
                    "corral.remote.sessions": MagicMock(
                        SessionHub=MagicMock(return_value=hub),
                        default_title_spawn_fn=object(),
                    ),
                },
            ):
                # Import inside patched modules: instantiate and dump.
                executor = CorralCursorExecutor()
                with patch(
                    "corral.remote.sessions.SessionHub",
                    return_value=hub,
                ), patch(
                    "corral.remote.sessions.default_title_spawn_fn",
                    object(),
                ):
                    executor.dump(
                        task={"remoteTaskID": "t1"},
                        package_dir=pkg,
                        checkout=checkout,
                    )
            hub.new_session.assert_called_once_with("cursor", str(checkout))
            hub.send_image.assert_called_once_with("sess-1", b"img-bytes")
            hub.send_text.assert_called_once()
            self.assertIn("Rename the title", hub.send_text.call_args.args[1])
            self.assertFalse((pkg / "results.json").is_file())
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
