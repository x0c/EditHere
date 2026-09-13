"""Bonjour/DNS-SD advertisement plan and builder."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from edithere_host.advertise import (  # noqa: E402
    SERVICE_TYPE,
    Advertiser,
    advertise_command,
    advertisable,
    service_name,
    txt_records,
)
from edithere_host.cli import advertise_plan  # noqa: E402
from edithere_host.config import parse_config  # noqa: E402


def _config(tmp: Path, *, listen: str = "0.0.0.0:8787") -> object:
    raw = {
        "schemaVersion": "1",
        "listen": listen,
        "dataDir": str(tmp / "data"),
        "tokenEnv": "EDITHHERE_HOST_TOKEN_ADV",
        "projects": {
            "edithere-sample": {
                "checkout": str(tmp / "co"),
                "projectConfig": "edithere.project.json",
            }
        },
    }
    return parse_config(raw, tmp / "host.json")


class AdvertiseTests(unittest.TestCase):
    def test_contract_service_type_and_txt(self) -> None:
        # Phone mirror: Sources/.../LocalHostDestination.discoveryServiceType.
        self.assertEqual(SERVICE_TYPE, "_edithere._tcp")
        self.assertEqual(
            txt_records("edithere-sample"),
            {
                "project": "edithere-sample",
                "dst": "local-host:edithere-sample",
                "path": "/v1/submissions",
                "v": "1",
            },
        )
        self.assertIn("edithere-sample", service_name("edithere-sample"))

    def test_advertise_command_darwin_and_linux_shapes(self) -> None:
        txt = txt_records("edithere-sample")
        name = service_name("edithere-sample")
        with patch(
            "edithere_host.advertise.publisher_binary", return_value="dns-sd"
        ):
            cmd = advertise_command(name, 8787, txt)
            assert cmd is not None
            self.assertEqual(cmd[:5], ["dns-sd", "-R", name, SERVICE_TYPE, "local"])
            self.assertIn("8787", cmd)
        with patch(
            "edithere_host.advertise.publisher_binary",
            return_value="avahi-publish-service",
        ):
            cmd = advertise_command(name, 8787, txt)
            assert cmd is not None
            self.assertEqual(cmd[:4], ["avahi-publish-service", name, SERVICE_TYPE, "8787"])
        with patch("edithere_host.advertise.publisher_binary", return_value=None):
            self.assertIsNone(advertise_command(name, 8787, txt))

    def test_advertisable_only_for_lan_binds(self) -> None:
        self.assertTrue(advertisable("0.0.0.0"))
        self.assertFalse(advertisable("127.0.0.1"))
        self.assertFalse(advertisable("localhost"))
        self.assertFalse(advertisable("::1"))

    def test_plan_lists_projects_and_loopback_off(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            plan = advertise_plan(_config(tmp), "0.0.0.0:8787", disabled=False)
            self.assertTrue(plan["enabled"])
            self.assertEqual(len(plan["services"]), 1)
            self.assertEqual(plan["services"][0]["projectID"], "edithere-sample")
            self.assertEqual(plan["services"][0]["serviceType"], SERVICE_TYPE)
            off = advertise_plan(_config(tmp), "127.0.0.1:8787", disabled=False)
            self.assertFalse(off["enabled"])
            flagged = advertise_plan(_config(tmp), "0.0.0.0:8787", disabled=True)
            self.assertFalse(flagged["enabled"])

    def test_advertiser_starts_and_stops(self) -> None:
        adv = Advertiser([("edithere-sample", 8787)])
        started: list[list[str]] = []

        class _Proc:
            def terminate(self) -> None:
                return None

            def wait(self, timeout: float | None = None) -> None:
                return None

        with patch(
            "edithere_host.advertise.publisher_binary", return_value="dns-sd"
        ), patch("subprocess.Popen", side_effect=lambda *a, **k: (started.append(list(a[0])), _Proc())[1]):
            self.assertEqual(adv.start(), 1)
            self.assertEqual(len(started), 1)
            self.assertIn(SERVICE_TYPE, started[0])
        adv.stop()
        self.assertEqual(adv._processes, [])

    def test_serve_dry_run_prints_plan(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            cfg_path = tmp / "host.json"
            raw = {
                "schemaVersion": "1",
                "listen": "0.0.0.0:8787",
                "dataDir": str(tmp / "data"),
                "tokenEnv": "EDITHHERE_HOST_TOKEN_ADV",
                "projects": {
                    "edithere-sample": {
                        "checkout": str(tmp / "co"),
                        "projectConfig": "edithere.project.json",
                    }
                },
            }
            cfg_path.write_text(json.dumps(raw), encoding="utf-8")
            from edithere_host.cli import main

            self.assertEqual(
                main(["serve", "--config", str(cfg_path), "--dry-run"]), 0
            )


if __name__ == "__main__":
    unittest.main()
