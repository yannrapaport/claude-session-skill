"""Thin adapter over `zellij action …` — the panel's only way to touch Zellij."""
from __future__ import annotations
import json, os, shutil, subprocess

PANEL_TITLE = "sessions-panel"
PANEL_WIDTH = 36


class Zellij:
    def __init__(self, binary: str = "zellij", session: str | None = None, runner=subprocess.run):
        self.binary, self.session, self.runner = binary, session, runner

    def _cmd(self, *args: str) -> list[str]:
        base = [self.binary] + (["-s", self.session] if self.session else [])
        return base + ["action", *args]

    def _run(self, *args: str) -> str:
        try:
            p = self.runner(self._cmd(*args), capture_output=True, text=True, timeout=15)
        except FileNotFoundError:
            raise RuntimeError("zellij introuvable — installe-le (brew install zellij).") from None
        except OSError as e:
            raise RuntimeError(f"zellij : exécution impossible ({e}).") from None
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"zellij {args[0] if args else ''} : trop long (timeout 15 s).") from None
        if p.returncode != 0:
            raise RuntimeError(f"zellij {' '.join(args)} : {(p.stderr or '').strip()[:200]}")
        return p.stdout or ""

    def available(self) -> str | None:
        if not (os.path.isfile(self.binary) and os.access(self.binary, os.X_OK)) and not shutil.which(self.binary):
            return "zellij introuvable — installe-le (brew install zellij)."
        if not self.session and not os.environ.get("ZELLIJ"):
            return "Hors d'une session Zellij — lance « cc <sujet> » ou « sessions »."
        return None

    def _json_list(self, *args: str, keys: tuple[str, ...] = ()) -> list[dict]:
        """Run a listing command; any malformed output becomes a RuntimeError."""
        try:
            data = json.loads(self._run(*args) or "[]")
            if not isinstance(data, list) or not all(isinstance(d, dict) and all(k in d for k in keys) for d in data):
                raise ValueError("unexpected shape")
        except ValueError:
            raise RuntimeError(f"zellij {args[0]} : réponse illisible (JSON inattendu).") from None
        return data

    def panes(self) -> list[dict]:
        return [p for p in self._json_list("list-panes", "-a", "-j", keys=("id",)) if not p.get("is_plugin")]

    def tabs(self) -> list[dict]:
        return self._json_list("list-tabs", "-j", keys=("tab_id", "name"))

    def tab_names(self) -> list[str]:
        return [t["name"] for t in self.tabs()]

    def current_tab_id(self) -> int | None:
        return next((t["tab_id"] for t in self.tabs() if t.get("active")), None)

    @staticmethod
    def _is_panel(p: dict) -> bool:
        return p.get("title") == PANEL_TITLE or "session-panel" in (p.get("pane_command") or "")

    def go_to_tab(self, name: str) -> None:
        self._run("go-to-tab-name", "--", name)

    def new_tab(self, name: str, cwd: str, command: list[str]) -> None:
        self._run("new-tab", f"--name={name}", f"--cwd={cwd}", "--", *command)

    def panel_panes(self) -> list[dict]:
        return [p for p in self.panes() if self._is_panel(p)]

    def close_pane(self, pane_id: int) -> None:
        self._run("close-pane", "--pane-id", f"terminal_{pane_id}")

    def dock(self, pane_id: int) -> None:
        self._run("change-floating-pane-coordinates", "--pane-id", f"terminal_{pane_id}",
                  "-x", "0", "-y", "0", "--width", str(PANEL_WIDTH), "--height", "100%")

    def open_panel_in_tab(self, tab_id: int, command: list[str]) -> None:
        self._run("new-pane", "--floating", "--pinned", "true", "--close-on-exit", "--name", PANEL_TITLE,
                  "--tab-id", str(tab_id), "--", *command)

    def focused_terminal_in_current_tab(self, exclude_title: str = PANEL_TITLE) -> int | None:
        cur = self.current_tab_id()
        cands = [p for p in self.panes() if p.get("tab_id") == cur and p.get("title") != exclude_title and not self._is_panel(p)]
        focused = [p for p in cands if p.get("is_focused")]
        pick = (focused or [p for p in cands if not p.get("is_floating")] or [None])[0]
        return pick["id"] if pick else None

    def write_to_pane(self, pane_id: int, text: str) -> None:
        self._run("write-chars", "--pane-id", f"terminal_{pane_id}", "--", text)
        self._run("write", "--pane-id", f"terminal_{pane_id}", "13")
