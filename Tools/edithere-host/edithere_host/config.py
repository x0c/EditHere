"""Host configuration loading and validation."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional


DEFAULT_CONFIG_PATH = Path.home() / ".config" / "edithere" / "host.json"
CONFIG_ENV = "EDITHHERE_HOST_CONFIG"


@dataclass
class ProjectConfig:
    project_id: str
    checkout: Path
    project_config: str
    token_env: Optional[str] = None


@dataclass
class HostConfig:
    path: Path
    schema_version: str
    listen: str
    data_dir: Path
    token_env: str
    projects: dict[str, ProjectConfig] = field(default_factory=dict)

    def token(self, project_id: Optional[str] = None) -> Optional[str]:
        """Resolve token; prefer project-scoped env when configured."""
        if project_id and project_id in self.projects:
            proj_env = self.projects[project_id].token_env
            if proj_env:
                value = os.environ.get(proj_env)
                if value is None or value == "":
                    return None
                return value
        value = os.environ.get(self.token_env)
        if value is None or value == "":
            return None
        return value

    def authorize(self, token: Optional[str], project_id: str) -> bool:
        """True when the presented token authorizes the given project."""
        if not token:
            return False
        expected = self.token(project_id)
        if expected is None:
            return False
        return token == expected

    def has_token(self) -> bool:
        if any(p.token_env for p in self.projects.values()):
            return all(self.token(pid) is not None for pid in self.projects)
        return self.token() is not None

    @property
    def host(self) -> str:
        host, _, _ = _split_listen(self.listen)
        return host

    @property
    def port(self) -> int:
        _, port, _ = _split_listen(self.listen)
        return port


def _expand(path: str | Path) -> Path:
    return Path(os.path.expanduser(str(path))).resolve()


def _split_listen(listen: str) -> tuple[str, int, str]:
    raw = listen.strip()
    if ":" not in raw:
        raise ValueError(f"listen must be HOST:PORT, got {listen!r}")
    host, port_s = raw.rsplit(":", 1)
    try:
        port = int(port_s)
    except ValueError as exc:
        raise ValueError(f"invalid listen port in {listen!r}") from exc
    if not host:
        host = "0.0.0.0"
    return host, port, f"{host}:{port}"


def config_path(override: Optional[str] = None) -> Path:
    if override:
        return _expand(override)
    env = os.environ.get(CONFIG_ENV)
    if env:
        return _expand(env)
    return DEFAULT_CONFIG_PATH


def load_config(path: Optional[str | Path] = None) -> HostConfig:
    cfg_path = _expand(path) if path else config_path()
    if not cfg_path.is_file():
        raise FileNotFoundError(f"host config not found: {cfg_path}")
    with cfg_path.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)
    return parse_config(raw, cfg_path)


def parse_config(raw: dict[str, Any], path: Path) -> HostConfig:
    schema = str(raw.get("schemaVersion") or "1")
    listen = str(raw.get("listen") or "0.0.0.0:8787")
    _split_listen(listen)  # validate
    data_dir = _expand(raw.get("dataDir") or "~/.local/share/edithere-host")
    token_env = str(raw.get("tokenEnv") or "EDITHHERE_HOST_TOKEN")
    projects_raw = raw.get("projects") or {}
    if not isinstance(projects_raw, dict):
        raise ValueError("projects must be an object")
    projects: dict[str, ProjectConfig] = {}
    for project_id, entry in projects_raw.items():
        if not isinstance(entry, dict):
            raise ValueError(f"project {project_id!r} must be an object")
        checkout = entry.get("checkout")
        project_config = entry.get("projectConfig")
        if not checkout or not project_config:
            raise ValueError(f"project {project_id!r} requires checkout and projectConfig")
        projects[str(project_id)] = ProjectConfig(
            project_id=str(project_id),
            checkout=_expand(checkout),
            project_config=str(project_config),
            token_env=str(entry["tokenEnv"]) if entry.get("tokenEnv") else None,
        )
    return HostConfig(
        path=path,
        schema_version=schema,
        listen=listen,
        data_dir=data_dir,
        token_env=token_env,
        projects=projects,
    )


def doctor_report(cfg: HostConfig) -> dict[str, Any]:
    token_set = cfg.has_token()
    project_rows = []
    for pid, proj in sorted(cfg.projects.items()):
        project_json = (proj.checkout / proj.project_config).resolve()
        project_rows.append(
            {
                "projectID": pid,
                "checkoutExists": proj.checkout.is_dir(),
                "checkout": str(proj.checkout),
                "projectConfigExists": project_json.is_file(),
                "projectConfig": str(project_json),
            }
        )
    ok = token_set and bool(cfg.projects) and all(
        row["checkoutExists"] and row["projectConfigExists"] for row in project_rows
    )
    return {
        "ok": ok,
        "configPath": str(cfg.path),
        "listen": cfg.listen,
        "dataDir": str(cfg.data_dir),
        "dataDirWritable": _writable(cfg.data_dir),
        "tokenEnv": cfg.token_env,
        "tokenPresent": token_set,
        "projectCount": len(cfg.projects),
        "projects": project_rows,
    }


def _writable(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / ".edithere-host-write-probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink(missing_ok=True)
        return True
    except OSError:
        return False
