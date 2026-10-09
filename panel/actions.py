"""What the panel does when the user acts: tabs, migration, priority, trash, prompts."""
from __future__ import annotations
import json, os, re, subprocess, tempfile
from pathlib import Path
from .model import Session

ID_RE = re.compile(r"[0-9a-fA-F][0-9a-fA-F-]*")
NAME_MAX = 24


def _valid(sid: str) -> str:
    if not ID_RE.fullmatch(sid or ""):
        raise ValueError(f"identifiant de session invalide : {sid!r}")
    return sid


class Actions:
    def __init__(self, zj, this_machine: str, state_dir: Path, runner=subprocess.run, cwd_for=None):
        self.zj, self.this, self.state_dir, self.runner = zj, this_machine, Path(state_dir), runner
        self.cwd_for = cwd_for or default_cwd_for

    # ── tabs registry ──
    def _tabs_file(self) -> Path:
        return self.state_dir / "tabs.json"

    def _tabs(self) -> dict:
        try:
            return json.loads(self._tabs_file().read_text())
        except (OSError, ValueError):
            return {}

    def _save_tabs(self, data: dict) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.state_dir, suffix=".tmp")
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, self._tabs_file())

    # ── rules ──
    def tab_name_for(self, s: Session, existing: list[str]) -> str:
        name = " ".join((s.title or s.id).replace('"', "").split())[:NAME_MAX].strip()
        return f"{name} ·{s.id[:4]}" if name in existing else name

    def command_for(self, s: Session) -> list[str]:
        sid = _valid(s.id)
        # Unknown machine (config missing): never divert or migrate — open locally.
        if self.this and s.diverged and s.owner != self.this:
            return ["session-diverge", sid]
        if self.this and s.owner and s.owner != self.this:
            return ["bash", "-c", f"session-migrate {sid} && session-open {sid} || "
                                  "{ echo; read -r -p '⏎ pour fermer' _; }"]
        return ["session-open", sid]

    # ── actions ──
    def open(self, s: Session) -> str:
        saved = True
        try:
            existing = self.zj.tab_names()
            tabs = {k: v for k, v in self._tabs().items() if v in existing}  # prune closed tabs
            name = tabs.get(s.id)
            if name:
                self.zj.go_to_tab(name)
            else:
                taken = list(existing) + list(tabs.values())
                name = self.tab_name_for(s, taken)
                self.zj.new_tab(name, self.cwd_for(s), self.command_for(s))
                tabs[s.id] = name
                try:
                    self._save_tabs(tabs)
                except OSError:
                    saved = False
        except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as e:
            return f"Échec : {e}"
        note = "" if saved else " (onglet ouvert mais non mémorisé)"
        try:
            self.move_panel_to_current_tab()
        except (RuntimeError, OSError) as e:
            return f"→ {name}{note} (panneau non déplacé : {e})"
        return f"→ {name}{note}"

    def open_ids(self) -> set[str]:
        """Ids of sessions whose recorded tab still exists. Never raises (empty set)."""
        try:
            existing = set(self.zj.tab_names())
            return {k for k, v in self._tabs().items() if v in existing}
        except Exception:
            return set()

    def move_panel_to_current_tab(self) -> None:
        # open the new panel first: a failure must never leave the user without one
        tab = self.zj.current_tab_id()
        if tab is None:
            return
        old = [p["id"] for p in self.zj.panel_panes()]
        self.zj.open_panel_in_tab(tab, ["session-panel", "--docked"])
        me = os.environ.get("ZELLIJ_PANE_ID", "")
        # closing our own pane kills this process: do it last
        for i in sorted(old, key=lambda i: str(i) == me):
            self.zj.close_pane(i)

    def _script(self, *cmd: str) -> str:
        try:
            p = self.runner(list(cmd), capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as e:
            return f"Échec : {e}"
        so = (p.stdout or "").strip().splitlines()
        if p.returncode == 0:
            return so[-1] if so else "ok"
        se = (p.stderr or "").strip().splitlines()
        return "Échec : " + (se[-1] if se else so[-1] if so else f"code {p.returncode}")

    def set_priority(self, s: Session, level: str) -> str:
        try:
            return self._script("session-priority", _valid(s.id), level)
        except ValueError as e:
            return f"Échec : {e}"

    def trash(self, s: Session) -> str:
        try:
            return self._script("session-trash", _valid(s.id))
        except ValueError as e:
            return f"Échec : {e}"

    def sync(self) -> str:
        return self._script("session-hub-sync")

    def replicate(self) -> str:
        return self._script("session-replicate")

    def prompts(self) -> list[str]:
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        try:
            lines = (base / "session-panel" / "prompts.txt").read_text().splitlines()
        except OSError:
            return []
        return [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]

    def send_prompt(self, text: str) -> str:
        try:
            pane = self.zj.focused_terminal_in_current_tab()
        except (RuntimeError, OSError) as e:
            return f"Échec : {e}"
        if pane is None:
            return "Aucun volet de session dans cet onglet — ouvre une session d'abord."
        try:
            self.zj.write_to_pane(pane, text)
        except (RuntimeError, OSError) as e:
            return f"Échec : {e}"
        return f"Prompt envoyé : {text}"


def default_cwd_for(s: Session) -> str:
    """Local cwd of the session if it lives here, else its subject root here, else $HOME."""
    home = str(Path.home())
    try:
        p = subprocess.run(["bash", "-c", 'f=$(ls "${CLAUDE_DIR:-$HOME/.claude}"/projects/*/"$1".jsonl 2>/dev/null | head -1); '
                                          '[ -n "$f" ] && session-cwd "$f"', "_", s.id],
                           capture_output=True, text=True, timeout=10)
        cwd = (p.stdout or "").strip()
        if cwd and os.path.isdir(cwd):
            return cwd
        r = subprocess.run(["session-subject-roots"], capture_output=True, text=True, timeout=10)
        for line in (r.stdout or "").splitlines():
            name, _, root = line.partition("\t")
            if name == s.subject and os.path.isdir(root):
                return root
    except (OSError, subprocess.SubprocessError):
        pass
    return home
