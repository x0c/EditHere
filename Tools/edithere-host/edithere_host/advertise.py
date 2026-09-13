"""Bonjour / DNS-SD advertisement for edithere-host (stdlib only).

Phones resolve the receiver via service type `_edithere._tcp` instead of a
hardcoded LAN IP in `edithere.project.json`. Discovery only supplies
address + port: Submit still requires the project token, and the phone
validates the project binding in the host response. The bundled `baseURL`
remains the fallback when discovery finds nothing.

Uses the OS publisher when present (`dns-sd` on macOS,
`avahi-publish-service` on Linux) and degrades to serve-only otherwise.
"""

from __future__ import annotations

import shutil
import socket
import subprocess
import sys
from dataclasses import dataclass, field


SERVICE_TYPE = "_edithere._tcp"
SERVICE_DOMAIN = "local"
DISCOVERY_VERSION = "1"


def service_name(project_id: str, host_name: str | None = None) -> str:
    """Human-readable instance name; the publisher disambiguates collisions."""
    host = (host_name if host_name is not None else socket.gethostname()).strip()
    if host.lower().endswith(".local"):
        host = host[: -len(".local")]
    host = host.strip() or "host"
    return f"EditHere {project_id} on {host}"[:128]


def txt_records(project_id: str, submit_path: str = "/v1/submissions") -> dict[str, str]:
    """TXT keys the phone matches before attempting Submit."""
    return {
        "project": project_id,
        "dst": f"local-host:{project_id}",
        "path": submit_path,
        "v": DISCOVERY_VERSION,
    }


def publisher_binary() -> str | None:
    """OS DNS-SD publisher, or None when discovery cannot be advertised."""
    for binary in ("dns-sd", "avahi-publish-service"):
        if shutil.which(binary):
            return binary
    return None


def advertise_command(name: str, port: int, txt: dict[str, str]) -> list[str] | None:
    """Publisher argv for one project instance, or None without a publisher."""
    binary = publisher_binary()
    if binary is None:
        return None
    items = [f"{key}={value}" for key, value in sorted(txt.items())]
    if binary == "dns-sd":
        return ["dns-sd", "-R", name, SERVICE_TYPE, SERVICE_DOMAIN, str(port), *items]
    return ["avahi-publish-service", name, SERVICE_TYPE, str(port), *items]


def advertisable(listen_host: str) -> bool:
    """Only advertise when the bound socket is reachable from the LAN."""
    host = (listen_host or "").strip().lower()
    return host not in ("127.0.0.1", "localhost", "::1", "::ffff:127.0.0.1")


@dataclass
class Advertiser:
    """Owns one publisher subprocess per project. Stop on server shutdown."""

    entries: list[tuple[str, int]] = field(default_factory=list)  # (project_id, port)
    _processes: list[subprocess.Popen] = field(default_factory=list, init=False, repr=False)

    def start(self) -> int:
        if not self.entries:
            return 0
        if publisher_binary() is None:
            sys.stderr.write(
                "edithere-host: no DNS-SD publisher (dns-sd/avahi-publish-service) found; "
                "serving without LAN advertisement. Phones fall back to baseURL.\n"
            )
            return 0
        started = 0
        for project_id, port in self.entries:
            cmd = advertise_command(
                service_name(project_id), port, txt_records(project_id)
            )
            if cmd is None:  # publisher vanished between checks; serve on.
                continue
            try:
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
            except OSError as exc:
                sys.stderr.write(
                    f"edithere-host: advertisement failed for {project_id}: {exc}\n"
                )
                continue
            self._processes.append(proc)
            started += 1
        return started

    def stop(self) -> None:
        for proc in self._processes:
            try:
                proc.terminate()
            except OSError:
                pass
        for proc in self._processes:
            try:
                proc.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    proc.kill()
                except OSError:
                    pass
        self._processes.clear()
