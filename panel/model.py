"""Session list model for the panel: rows from `session-rows --json`, view state."""
from __future__ import annotations
import json, os, subprocess, tempfile
from dataclasses import dataclass, asdict, field
from pathlib import Path

SORTS = ["activity", "project", "priority"]


@dataclass
class Session:
    id: str
    owner: str
    machine: str
    priority: str
    subject: str
    proj: str
    title: str
    age: str
    last_activity: str
    running: bool
    lag: bool
    diverged: bool


@dataclass
class ViewState:
    sort: str = "activity"
    scope: str = "all"
    subject: str = ""
    filter: str = ""

    def cycle_sort(self) -> str:
        self.sort = SORTS[(SORTS.index(self.sort) + 1) % len(SORTS)] if self.sort in SORTS else SORTS[0]
        return self.sort

    def toggle_scope(self) -> str:
        self.scope = "all" if self.scope == "subject" or not self.subject else "subject"
        return self.scope

    def set_filter(self, value: str) -> str:
        self.filter = "" if self.filter == value else value
        return self.filter

    def as_env(self, directory: Path) -> dict:
        """Write the state files session-rows reads from $SESSIONS_STATE."""
        directory.mkdir(parents=True, exist_ok=True)
        for k in ("sort", "scope", "subject", "filter"):
            (directory / k).write_text(getattr(self, k) + "\n")
        return {**os.environ, "SESSIONS_STATE": str(directory)}

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        with os.fdopen(fd, "w") as fh:
            json.dump(asdict(self), fh)
        os.replace(tmp, path)

    @classmethod
    def load(cls, path: Path) -> "ViewState":
        try:
            data = json.loads(Path(path).read_text())
            return cls(**{k: str(data.get(k, getattr(cls(), k))) for k in ("sort", "scope", "subject", "filter")})
        except (OSError, ValueError, TypeError):
            return cls()


def load_sessions(state: ViewState, runner=subprocess.run, state_dir: Path | None = None):
    """Return (sessions, error_message). Never raises on bad output."""
    env = state.as_env(state_dir or Path(tempfile.mkdtemp(prefix="session-panel-")))
    try:
        p = runner(["session-rows", "--json"], capture_output=True, text=True, env=env, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return [], f"session-rows injoignable : {e}"
    if p.returncode != 0:
        return [], f"session-rows a échoué : {(p.stderr or '').strip()[:200]}"
    try:
        rows = json.loads(p.stdout or "[]")
        return [Session(**{k: r.get(k) for k in Session.__dataclass_fields__}) for r in rows], None
    except (ValueError, TypeError, AttributeError) as e:
        return [], f"sortie de session-rows illisible : {e}"


def group_by_subject(sessions: list[Session]) -> list[tuple[str, list[Session]]]:
    groups: dict[str, list[Session]] = {}
    for s in sessions:
        groups.setdefault(s.subject or "~", []).append(s)
    return list(groups.items())
