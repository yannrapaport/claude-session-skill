# Volet de sessions Zellij + Textual — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer l'interface tmux + fzf par un volet Textual repliable dans Zellij (un onglet par session Claude, palette de commandes), en réutilisant tous les scripts de gestion de sessions existants.

**Architecture:** Un package Python `panel/` (modèle, adaptateur Zellij, actions, application Textual) lancé par `bin/session-panel` via `uv run --script`. Le modèle lit `session-rows --json` ; les actions appellent les scripts `bin/` existants et `zellij action …`. Zellij est piloté uniquement par sa CLI ; les tests remplacent `zellij` par un stub.

**Tech Stack:** Python ≥ 3.11, Textual 8.x, pytest, uv, Zellij ≥ 0.45, bash (scripts existants).

**Spec:** `docs/specs/2026-10-09-zellij-panel-design.md`

## Global Constraints

- Ne rien changer à la logique existante (index, meta, migration, réplique, réconciliation, corbeille, verrou) hormis l'ajout de `--json` à `session-rows`.
- Zellij piloté exclusivement par `zellij action …` (ou `zellij -s <session> action …` hors de Zellij). Volets : `list-panes -a -j` → liste d'objets `{id, is_plugin, is_floating, is_focused, title, tab_id, tab_name, …}` ; onglets : `list-tabs -j` → `{tab_id, position, name, active, …}`. Un volet terminal se désigne `terminal_<id>`.
- Le volet de sessions s'appelle exactement `sessions-panel` (titre Zellij) ; largeur 36, x 0, y 0, hauteur 100 %, flottant, épinglé.
- Un seul volet `sessions-panel` à la fois dans la session Zellij.
- Nom d'onglet de session : titre réduit à 24 caractères (espaces normalisés, `"` retirés), collision → suffixe ` ·<id[:4]>`.
- Fichiers d'état locaux : `$CLAUDE_DIR/session-panel/tabs.json` (`{session_id: tab_name}`), `$CLAUDE_DIR/session-panel/state.json` (`{sort, scope, subject, filter}`). Écriture atomique (mkstemp + os.replace).
- Prompts : `${XDG_CONFIG_HOME:-~/.config}/session-panel/prompts.txt`.
- Messages utilisateur en français ; code et commentaires en anglais.
- Les ids de session sont validés `^[0-9a-fA-F-]+$` avant tout usage dans une commande.
- Tests Python sous `tests/panel/`, lancés par `tests/test_panel.sh` (sourcé par `run_tests.sh`) : `uv run --quiet --with 'textual>=8,<9' --with pytest --with pytest-asyncio pytest -q tests/panel` ; le script fait `assert_eq "panel pytest" "0" "$rc"`.

## Review Focus

1. Ouvrir une session dont l'onglet a été fermé à la main → `tabs.json` pointe vers un onglet disparu : il faut recréer l'onglet, pas basculer dans le vide. Test : Task 3.
2. Deux sessions au même titre → noms d'onglet distincts (suffixe). Test : Task 3.
3. `zellij` absent ou hors session Zellij → le volet affiche un message clair au lieu de planter. Test : Task 2.
4. Envoi d'un prompt alors que l'onglet courant n'a pas d'autre volet terminal que le volet de sessions → message, rien n'est écrit. Test : Task 3.
5. `session-rows --json` vide ou en erreur → liste vide + message, pas de crash. Test : Task 1.

---

## File Structure

| Fichier | Rôle |
|---|---|
| `bin/session-rows` *(modif)* | `--json` : lignes structurées (la sortie texte reste identique). |
| `panel/__init__.py` | Package. |
| `panel/model.py` | `Session` dataclass, `load_sessions()`, `group_by_subject()`, état d'affichage (`ViewState`). |
| `panel/zj.py` | Adaptateur Zellij : lecture des volets/onglets, création d'onglet, déplacement/fermeture du volet, envoi de texte. |
| `panel/actions.py` | Décisions : ouvrir (onglet existant / nouveau, commande selon l'état), nommage d'onglet, priorité, corbeille, sync, réplication, prompts. |
| `panel/app.py` | Application Textual : arbre groupé, raccourcis, rafraîchissement, palette (3 providers). |
| `bin/session-panel` | Lanceur `uv run --script` : bascule (ferme si déjà ouvert ailleurs), auto-calage, lance l'app. |
| `zellij/config.kdl` | Keybind `Ctrl Space` → `Run "session-panel"` flottant épinglé ; `show_startup_tips false`. |
| `tests/panel/*.py`, `tests/panel/zellij-stub`, `tests/test_panel.sh` | Tests. |
| `bin/sessions` *(modif)* | TTY → `zellij attach -c cc-<sujet>`. |
| `install.sh`, `README.md` *(modif)* | Config Zellij si absente, prompts par défaut, doc. |
| Retirés : `bin/session-layout`, `bin/session-tui`, `bin/session-tui-act`, `bin/session-home`, `tests/test_tui.sh` | Ancienne interface tmux. |
| Repo `cc` : `cc.zsh`, `test.zsh` | `cc <sujet>` → Zellij ; `cc tmux` retiré. |

---

### Task 1: `session-rows --json` + modèle

**Files:**
- Modify: `bin/session-rows`
- Create: `panel/__init__.py`, `panel/model.py`, `tests/panel/conftest.py`, `tests/panel/test_model.py`, `tests/test_panel.sh`

**Interfaces:**
- Produces: `session-rows --json` → tableau JSON d'objets `{"id", "owner", "machine", "priority", "subject", "proj", "title", "age", "last_activity", "running": bool, "lag": bool, "diverged": bool}` (mêmes filtres/tri/état `SESSIONS_STATE` que la sortie texte).
- Produces: `panel.model.Session` (mêmes champs), `load_sessions(state: ViewState, runner=subprocess.run) -> tuple[list[Session], str | None]` (liste, message d'erreur éventuel), `group_by_subject(sessions) -> list[tuple[str, list[Session]]]` (ordre d'apparition préservé), `ViewState(sort="activity", scope="all", subject="", filter="")` avec `cycle_sort()`, `toggle_scope()`, `set_filter(x)` (même valeur = retire), `load(path)`/`save(path)`.

- [ ] **Step 1: Test pytest du modèle**

`tests/panel/conftest.py` :

```python
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
```

`tests/panel/test_model.py` :

```python
import json, subprocess
from panel.model import Session, ViewState, load_sessions, group_by_subject

ROWS = [
    {"id": "a1", "owner": "mac", "machine": "mac", "priority": "must", "subject": "tpg",
     "proj": "tpg/rakam", "title": "Refonte", "age": "2h", "last_activity": "2026-10-09T08:00:00Z",
     "running": True, "lag": False, "diverged": False},
    {"id": "b2", "owner": "nexus", "machine": "nexus", "priority": "", "subject": "brain",
     "proj": "brain", "title": "Sessions", "age": "1j", "last_activity": "2026-10-08T08:00:00Z",
     "running": False, "lag": False, "diverged": True},
    {"id": "c3", "owner": "mac", "machine": "mac", "priority": "", "subject": "tpg",
     "proj": "tpg", "title": "Bizdev", "age": "3j", "last_activity": "2026-10-06T08:00:00Z",
     "running": False, "lag": True, "diverged": False},
]

def fake_runner(out, rc=0):
    def run(cmd, **kw):
        assert cmd[:2] == ["session-rows", "--json"]
        return subprocess.CompletedProcess(cmd, rc, stdout=out, stderr="boom" if rc else "")
    return run

def test_load_and_group():
    sessions, err = load_sessions(ViewState(), runner=fake_runner(json.dumps(ROWS)))
    assert err is None and [s.id for s in sessions] == ["a1", "b2", "c3"]
    groups = group_by_subject(sessions)
    assert [g for g, _ in groups] == ["tpg", "brain"]
    assert [s.id for s in groups[0][1]] == ["a1", "c3"]

def test_load_error_is_reported_not_raised():
    sessions, err = load_sessions(ViewState(), runner=fake_runner("", rc=1))
    assert sessions == [] and "boom" in err

def test_load_garbage_json():
    sessions, err = load_sessions(ViewState(), runner=fake_runner("not json"))
    assert sessions == [] and err

def test_view_state_cycle_toggle_filter(tmp_path):
    v = ViewState()
    assert [v.cycle_sort() for _ in range(3)] == ["project", "priority", "activity"]
    v.subject = "tpg"; assert v.toggle_scope() == "subject" and v.toggle_scope() == "all"
    v.set_filter("mac"); assert v.filter == "mac"; v.set_filter("mac"); assert v.filter == ""
    p = tmp_path / "state.json"; v.sort = "priority"; v.save(p)
    assert ViewState.load(p).sort == "priority"
    assert ViewState.load(tmp_path / "missing.json").sort == "activity"

def test_session_without_subject_groups_under_tilde():
    s = Session(**{**ROWS[0], "id": "d4", "subject": ""})
    assert group_by_subject([s])[0][0] == "~"
```

`tests/test_panel.sh` :

```bash
#!/usr/bin/env bash
# tests/test_panel.sh — sourced by run_tests.sh: runs the Python panel tests.
echo "--- test_panel ---"
rc=0
( cd "$SCRIPT_DIR/.." && uv run --quiet --with 'textual>=8,<9' --with pytest --with pytest-asyncio \
    pytest -q tests/panel ) || rc=$?
assert_eq "panel pytest" "0" "$rc"
```

Ajouter aussi à `tests/test_rows.sh` (bash) un test de `--json` : sur le registre de test existant, `session-rows --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d[0]))'` contient exactement les clés de l'interface ; `running`/`lag`/`diverged` sont des booléens ; l'ordre des ids est le même que la sortie texte.

- [ ] **Step 2: Lancer, constater l'échec** — `bash tests/run_tests.sh 2>&1 | grep -E 'panel|json|Results'` → FAIL.

- [ ] **Step 3: `--json` dans `bin/session-rows`**

Dans le bloc python, lire un 6e argument `as_json` (passé `1` si `"${1:-}" = --json`). Garder tout le calcul existant ; à la place du `print(f"{r['id']}\t{line}")`, si `as_json` : accumuler

```python
out.append({"id": r["id"], "owner": r["owner"], "machine": r.get("machine", ""),
            "priority": r["priority"], "subject": r.get("cc_subject") or "",
            "proj": r["proj"], "title": title, "age": age(r.get("last_activity") or ""),
            "last_activity": r.get("last_activity") or "",
            "running": r["id"] in running, "lag": "⇢" in marks, "diverged": bool(r.get("diverged"))})
```

et à la fin `print(json.dumps(out))`. Sans `--json`, sortie strictement inchangée.

- [ ] **Step 4: `panel/model.py`**

```python
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
    except (ValueError, TypeError) as e:
        return [], f"sortie de session-rows illisible : {e}"


def group_by_subject(sessions: list[Session]) -> list[tuple[str, list[Session]]]:
    groups: dict[str, list[Session]] = {}
    for s in sessions:
        groups.setdefault(s.subject or "~", []).append(s)
    return list(groups.items())
```

Note : `load_sessions` utilise un répertoire d'état temporaire réutilisé par l'app (l'app passe `state_dir`), pour ne pas créer un tmpdir à chaque rafraîchissement.

- [ ] **Step 5: Lancer, constater le succès** — `bash tests/run_tests.sh 2>&1 | tail -1` → `0 failed`.

- [ ] **Step 6: Commit** — `feat: session-rows --json and the panel's session model`

---

### Task 2: Adaptateur Zellij

**Files:**
- Create: `panel/zj.py`, `tests/panel/zellij-stub`, `tests/panel/test_zj.py`

**Interfaces:**
- Consumes: CLI `zellij action …` (env `ZELLIJ`, `ZELLIJ_SESSION_NAME`, `ZELLIJ_PANE_ID` présents quand on tourne dans Zellij).
- Produces: classe `Zellij(binary="zellij", session=None, runner=subprocess.run)` :
  - `available() -> str | None` : `None` si utilisable, sinon message français (binaire absent, hors session).
  - `panes() -> list[dict]` (non-plugins), `tabs() -> list[dict]`, `current_tab_id() -> int | None` (onglet `active`).
  - `tab_names() -> list[str]`.
  - `go_to_tab(name)`, `new_tab(name, cwd, command: list[str]) -> None` (crée l'onglet nommé puis `new-pane --in-place`? non : `new-tab --name N --cwd C` puis `write-chars` serait fragile — utiliser `new-tab --name N --cwd C -- <command>` si supporté, sinon `new-tab` + `new-pane --close-replaced-pane --in-place -- cmd`; voir Step 3).
  - `panel_panes() -> list[dict]` (titre == `sessions-panel`), `close_pane(pane_id: int)`, `dock(pane_id: int)`.
  - `open_panel_in_tab(tab_id: int, command: list[str])` : `new-pane --floating --pinned true --name sessions-panel --tab-id T -- …`.
  - `focused_terminal_in_current_tab(exclude_title="sessions-panel") -> int | None`.
  - `write_to_pane(pane_id: int, text: str)` : `write-chars --pane-id terminal_<id> <text>` puis `write --pane-id … 13`.

- [ ] **Step 1: Stub**

`tests/panel/zellij-stub` (exécutable) :

```bash
#!/usr/bin/env bash
# zellij stub: logs argv to $ZJ_LOG; serves list-panes/list-tabs from $ZJ_PANES/$ZJ_TABS (JSON files).
echo "$*" >> "${ZJ_LOG:?}"
args=" $* "
case "$args" in
  *" list-panes "*) cat "${ZJ_PANES:?}" ;;
  *" list-tabs "*)  cat "${ZJ_TABS:?}" ;;
  *" new-pane "*)   echo "terminal_${ZJ_NEW_PANE_ID:-9}" ;;
esac
exit "${ZJ_RC:-0}"
```

- [ ] **Step 2: Tests** `tests/panel/test_zj.py` :

```python
import json, os, pathlib, stat
import pytest
from panel.zj import Zellij

STUB = pathlib.Path(__file__).with_name("zellij-stub")

@pytest.fixture
def zj(tmp_path, monkeypatch):
    STUB.chmod(STUB.stat().st_mode | stat.S_IEXEC)
    panes = [
        {"id": 0, "is_plugin": False, "is_floating": False, "is_focused": True, "title": "zsh", "tab_id": 0, "tab_name": "Tab #1"},
        {"id": 3, "is_plugin": False, "is_floating": True, "is_focused": False, "title": "sessions-panel", "tab_id": 0, "tab_name": "Tab #1"},
        {"id": 1, "is_plugin": True, "is_floating": False, "is_focused": False, "title": "tab-bar", "tab_id": 0, "tab_name": "Tab #1"},
    ]
    tabs = [{"tab_id": 0, "position": 0, "name": "Tab #1", "active": True},
            {"tab_id": 1, "position": 1, "name": "Refonte", "active": False}]
    (tmp_path / "p.json").write_text(json.dumps(panes)); (tmp_path / "t.json").write_text(json.dumps(tabs))
    monkeypatch.setenv("ZJ_LOG", str(tmp_path / "log")); monkeypatch.setenv("ZJ_PANES", str(tmp_path / "p.json"))
    monkeypatch.setenv("ZJ_TABS", str(tmp_path / "t.json")); monkeypatch.setenv("ZELLIJ", "0")
    monkeypatch.setenv("ZELLIJ_SESSION_NAME", "cc-tpg")
    z = Zellij(binary=str(STUB)); z.log = tmp_path / "log"
    return z

def log(z): return z.log.read_text().splitlines()

def test_reads(zj):
    assert zj.available() is None
    assert [p["id"] for p in zj.panes()] == [0, 3]          # plugins dropped
    assert zj.tab_names() == ["Tab #1", "Refonte"] and zj.current_tab_id() == 0
    assert [p["id"] for p in zj.panel_panes()] == [3]
    assert zj.focused_terminal_in_current_tab() == 0

def test_writes(zj):
    zj.go_to_tab("Refonte"); zj.close_pane(3); zj.dock(5)
    zj.write_to_pane(0, "/ai-brain:wrap-up")
    L = log(zj)
    assert "action go-to-tab-name Refonte" in L
    assert "action close-pane --pane-id terminal_3" in L
    assert any(l.startswith("action change-floating-pane-coordinates --pane-id terminal_5 -x 0 -y 0 --width 36 --height 100%") for l in L)
    assert "action write-chars --pane-id terminal_0 /ai-brain:wrap-up" in L
    assert "action write --pane-id terminal_0 13" in L

def test_unavailable(monkeypatch, tmp_path):
    monkeypatch.delenv("ZELLIJ", raising=False); monkeypatch.delenv("ZELLIJ_SESSION_NAME", raising=False)
    assert "Zellij" in Zellij(binary=str(STUB)).available()
    assert "introuvable" in Zellij(binary=str(tmp_path / "nope")).available()
```

Vérifier sur le vrai Zellij 0.45.1 (Mac, `brew`) la forme exacte de chaque commande avant de figer : `zellij action close-pane --help`, `write-chars --help`, `write --help`, `new-tab --help` (accepte-t-il `-- <commande>` ? `--cwd` ?). Si `close-pane`/`write-chars`/`write` n'acceptent pas `--pane-id`, utiliser `focus-pane-id terminal_N` d'abord puis l'action sans id ; adapter les assertions en conséquence et le noter dans le rapport.

- [ ] **Step 3: Implémenter `panel/zj.py`**

```python
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

    def _run(self, *args: str, check: bool = True) -> str:
        p = self.runner(self._cmd(*args), capture_output=True, text=True, timeout=15)
        if check and p.returncode != 0:
            raise RuntimeError(f"zellij {' '.join(args)} : {(p.stderr or '').strip()[:200]}")
        return p.stdout or ""

    def available(self) -> str | None:
        if not (os.path.isfile(self.binary) and os.access(self.binary, os.X_OK)) and not shutil.which(self.binary):
            return "zellij introuvable — installe-le (brew install zellij)."
        if not self.session and not os.environ.get("ZELLIJ"):
            return "Hors d'une session Zellij — lance « cc <sujet> » ou « sessions »."
        return None

    def panes(self) -> list[dict]:
        return [p for p in json.loads(self._run("list-panes", "-a", "-j") or "[]") if not p.get("is_plugin")]

    def tabs(self) -> list[dict]:
        return json.loads(self._run("list-tabs", "-j") or "[]")

    def tab_names(self) -> list[str]:
        return [t["name"] for t in self.tabs()]

    def current_tab_id(self) -> int | None:
        return next((t["tab_id"] for t in self.tabs() if t.get("active")), None)

    def go_to_tab(self, name: str) -> None:
        self._run("go-to-tab-name", name)

    def new_tab(self, name: str, cwd: str, command: list[str]) -> None:
        self._run("new-tab", "--name", name, "--cwd", cwd, "--", *command)

    def panel_panes(self) -> list[dict]:
        return [p for p in self.panes() if p.get("title") == PANEL_TITLE]

    def close_pane(self, pane_id: int) -> None:
        self._run("close-pane", "--pane-id", f"terminal_{pane_id}")

    def dock(self, pane_id: int) -> None:
        self._run("change-floating-pane-coordinates", "--pane-id", f"terminal_{pane_id}",
                  "-x", "0", "-y", "0", "--width", str(PANEL_WIDTH), "--height", "100%")

    def open_panel_in_tab(self, tab_id: int, command: list[str]) -> None:
        self._run("new-pane", "--floating", "--pinned", "true", "--name", PANEL_TITLE,
                  "--tab-id", str(tab_id), "--", *command)

    def focused_terminal_in_current_tab(self, exclude_title: str = PANEL_TITLE) -> int | None:
        cur = self.current_tab_id()
        cands = [p for p in self.panes() if p.get("tab_id") == cur and p.get("title") != exclude_title]
        focused = [p for p in cands if p.get("is_focused")]
        pick = (focused or [p for p in cands if not p.get("is_floating")] or [None])[0]
        return pick["id"] if pick else None

    def write_to_pane(self, pane_id: int, text: str) -> None:
        self._run("write-chars", "--pane-id", f"terminal_{pane_id}", text)
        self._run("write", "--pane-id", f"terminal_{pane_id}", "13")
```

Si `new-tab` n'accepte pas `-- <commande>` en 0.45.1 : créer l'onglet (`new-tab --name N --cwd C`) puis `new-pane --in-place --close-replaced-pane -- <commande>` sur son volet ; adapter `new_tab` et son test.

- [ ] **Step 4: Lancer, constater le succès** ; **Step 5: Commit** — `feat: panel Zellij adapter`

---

### Task 3: Actions

**Files:**
- Create: `panel/actions.py`, `tests/panel/test_actions.py`

**Interfaces:**
- Consumes: `panel.model.Session`, `panel.zj.Zellij`.
- Produces: classe `Actions(zj: Zellij, this_machine: str, state_dir: Path, runner=subprocess.run, bin_dir: Path)` :
  - `tab_name_for(session, existing: list[str]) -> str` (règle de nommage + suffixe en collision),
  - `command_for(session) -> list[str]` (`["session-open", id]` local ; `["bash", "-c", "session-migrate ID && session-open ID || { echo; read -r -p '⏎ pour fermer' _; }"]` autre propriétaire ; `["session-diverge", id]` si `diverged` et propriétaire local… voir règle),
  - `open(session) -> str` (message ; bascule ou crée, enregistre dans `tabs.json`, déplace le volet),
  - `move_panel_to_current_tab()` (ferme les autres `sessions-panel`, ouvre dans l'onglet courant),
  - `set_priority(session, level)`, `trash(session)`, `sync()`, `replicate()` → `str` message,
  - `prompts() -> list[str]`, `send_prompt(text) -> str`.

Règle de commande (depuis la spec) : `diverged` (champ de **cette** machine dans `session-rows --json`) → `session-diverge` ; `owner != this_machine` → migrate+open ; sinon `session-open`. Toutes les commandes reçoivent un id validé `^[0-9a-fA-F-]+$` (sinon `ValueError`).

- [ ] **Step 1: Tests** `tests/panel/test_actions.py` :

```python
import json, subprocess
from pathlib import Path
import pytest
from panel.model import Session
from panel.actions import Actions

def S(**kw):
    base = dict(id="aaaa1111-0000", owner="mac", machine="mac", priority="", subject="tpg", proj="tpg",
                title="Refonte pricing", age="2h", last_activity="", running=False, lag=False, diverged=False)
    return Session(**{**base, **kw})

class FakeZ:
    def __init__(self, tabs=("Tab #1",), current=0, panels=(), focused=7):
        self._tabs = list(tabs); self.current = current; self.panels = list(panels); self.focused = focused
        self.calls = []
    def tab_names(self): return list(self._tabs)
    def current_tab_id(self): return self.current
    def go_to_tab(self, n): self.calls.append(("go", n))
    def new_tab(self, n, cwd, cmd): self.calls.append(("new", n, cwd, cmd)); self._tabs.append(n); self.current = len(self._tabs) - 1
    def panel_panes(self): return [{"id": i} for i in self.panels]
    def close_pane(self, i): self.calls.append(("close", i))
    def open_panel_in_tab(self, t, cmd): self.calls.append(("panel", t))
    def focused_terminal_in_current_tab(self, exclude_title="sessions-panel"): return self.focused
    def write_to_pane(self, i, t): self.calls.append(("write", i, t))

@pytest.fixture
def mk(tmp_path):
    def make(z, runner=None):
        return Actions(z, "mac", tmp_path, runner=runner or (lambda *a, **k: subprocess.CompletedProcess(a[0], 0, "", "")),
                       cwd_for=lambda s: "/tmp")
    return make

def test_tab_name_rules(mk):
    a = mk(FakeZ())
    assert a.tab_name_for(S(title='A "very" long title that goes on and on'), []) == "A very long title that g"
    assert a.tab_name_for(S(), ["Refonte pricing"]) == "Refonte pricing ·aaaa"

def test_command_rules(mk):
    a = mk(FakeZ())
    assert a.command_for(S()) == ["session-open", "aaaa1111-0000"]
    assert a.command_for(S(owner="nexus"))[0] == "bash" and "session-migrate aaaa1111-0000" in a.command_for(S(owner="nexus"))[2]
    assert a.command_for(S(diverged=True)) == ["session-diverge", "aaaa1111-0000"]
    with pytest.raises(ValueError): a.command_for(S(id="../x"))

def test_open_new_then_existing_then_stale(mk, tmp_path):
    z = FakeZ(panels=[3]); a = mk(z)
    a.open(S())                                    # new tab + panel moved
    assert ("new", "Refonte pricing", "/tmp", ["session-open", "aaaa1111-0000"]) in z.calls
    assert ("close", 3) in z.calls and ("panel", 1) in z.calls
    z.calls.clear(); a.open(S())                    # existing tab → go
    assert z.calls[0] == ("go", "Refonte pricing")
    z._tabs = ["Tab #1"]; z.calls.clear(); a.open(S())   # tab closed by hand → recreated (Review Focus 1)
    assert z.calls[0][0] == "new"

def test_send_prompt(mk):
    z = FakeZ(); a = mk(z)
    assert "envoyé" in a.send_prompt("/ai-brain:wrap-up") and ("write", 7, "/ai-brain:wrap-up") in z.calls
    z2 = FakeZ(focused=None); assert "aucun" in mk(z2).send_prompt("x").lower()   # Review Focus 4

def test_priority_and_trash_call_scripts(mk):
    seen = []
    def run(cmd, **kw): seen.append(cmd); return subprocess.CompletedProcess(cmd, 0, "", "")
    a = mk(FakeZ(), runner=run)
    a.set_priority(S(), "must"); a.trash(S()); a.sync(); a.replicate()
    assert ["session-priority", "aaaa1111-0000", "must"] in seen
    assert ["session-trash", "aaaa1111-0000"] in seen
    assert ["session-hub-sync"] in seen and ["session-replicate"] in seen

def test_prompts_file(mk, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    (tmp_path / "session-panel").mkdir(); (tmp_path / "session-panel" / "prompts.txt").write_text("# c\n/ai-brain:wrap-up\n\n/ai-brain:save\n")
    assert mk(FakeZ()).prompts() == ["/ai-brain:wrap-up", "/ai-brain:save"]
```

`cwd_for` est injecté : en production il lit le cwd local de la session via `session-cwd` (fichier `projects/*/<id>.jsonl`) ou, pour une session distante (migration), la racine du sujet via `session-subject-roots` ; à défaut `$HOME`.

- [ ] **Step 2: Échec** ; **Step 3: Implémenter `panel/actions.py`**

```python
"""What the panel does when the user acts: tabs, migration, priority, trash, prompts."""
from __future__ import annotations
import json, os, re, subprocess, tempfile
from pathlib import Path
from .model import Session

ID_RE = re.compile(r"^[0-9a-fA-F-]+$")
NAME_MAX = 24


def _valid(sid: str) -> str:
    if not ID_RE.match(sid or ""):
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
        name = " ".join((s.title or s.id).replace('"', "").split())[:NAME_MAX].rstrip()
        return f"{name} ·{s.id[:4]}" if name in existing else name

    def command_for(self, s: Session) -> list[str]:
        sid = _valid(s.id)
        if s.diverged:
            return ["session-diverge", sid]
        if s.owner and s.owner != self.this:
            return ["bash", "-c", f"session-migrate {sid} && session-open {sid} || "
                                  "{ echo; read -r -p '⏎ pour fermer' _; }"]
        return ["session-open", sid]

    # ── actions ──
    def open(self, s: Session) -> str:
        tabs, existing = self._tabs(), self.zj.tab_names()
        name = tabs.get(s.id)
        if name and name in existing:
            self.zj.go_to_tab(name)
        else:
            name = self.tab_name_for(s, existing)
            self.zj.new_tab(name, self.cwd_for(s), self.command_for(s))
            tabs[s.id] = name
            self._save_tabs(tabs)
        self.move_panel_to_current_tab()
        return f"→ {name}"

    def move_panel_to_current_tab(self) -> None:
        for p in self.zj.panel_panes():
            self.zj.close_pane(p["id"])
        tab = self.zj.current_tab_id()
        if tab is not None:
            self.zj.open_panel_in_tab(tab, ["session-panel", "--docked"])

    def _script(self, *cmd: str) -> str:
        p = self.runner(list(cmd), capture_output=True, text=True, timeout=120)
        out = ((p.stdout or "") + (p.stderr or "")).strip().splitlines()
        return out[-1] if out else ("ok" if p.returncode == 0 else f"échec ({p.returncode})")

    def set_priority(self, s: Session, level: str) -> str:
        return self._script("session-priority", _valid(s.id), level)

    def trash(self, s: Session) -> str:
        return self._script("session-trash", _valid(s.id))

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
        pane = self.zj.focused_terminal_in_current_tab()
        if pane is None:
            return "Aucun volet de session dans cet onglet — ouvre une session d'abord."
        self.zj.write_to_pane(pane, text)
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
```

`session-trash` (non `--ask`) : la confirmation est faite dans la palette (Task 4), pas dans un terminal.

- [ ] **Step 4: Succès** ; **Step 5: Commit** — `feat: panel actions — tabs, migration, priority, trash, prompts`

---

### Task 4: Application Textual

**Files:**
- Create: `panel/app.py`, `tests/panel/test_app.py`

**Interfaces:**
- Consumes: `panel.model` (Task 1), `panel.actions.Actions` (Task 3).
- Produces: `SessionPanel(App)` construit avec `load=callable -> (list[Session], err)`, `actions=Actions`, `view=ViewState`, `on_view_change=callable(ViewState)` ; liaisons : `enter` ouvrir, `slash` filtre texte, `escape` effacer, `ctrl+p` palette, `q`/`ctrl+space` quitter ; rafraîchissement `set_interval(30, refresh)` ; providers de palette `SessionCommands`, `GlobalCommands`, `PromptCommands`.

- [ ] **Step 1: Tests** `tests/panel/test_app.py` :

```python
import pytest
from panel.model import Session, ViewState
from panel.app import SessionPanel

def S(i, subj, title, **kw):
    base = dict(id=i, owner="mac", machine="mac", priority="", subject=subj, proj=subj, title=title, age="1h",
                last_activity="", running=False, lag=False, diverged=False)
    return Session(**{**base, **kw})

class FakeActions:
    def __init__(self): self.calls = []
    def open(self, s): self.calls.append(("open", s.id)); return "→ ok"
    def set_priority(self, s, lvl): self.calls.append(("prio", s.id, lvl)); return "ok"
    def trash(self, s): self.calls.append(("trash", s.id)); return "ok"
    def sync(self): self.calls.append(("sync",)); return "ok"
    def replicate(self): self.calls.append(("replicate",)); return "ok"
    def prompts(self): return ["/ai-brain:wrap-up"]
    def send_prompt(self, t): self.calls.append(("prompt", t)); return "ok"

SESS = [S("a1", "tpg", "Refonte", priority="must", running=True), S("b2", "brain", "Sessions", diverged=True), S("c3", "tpg", "Bizdev")]

@pytest.mark.asyncio
async def test_tree_groups_and_open():
    acts = FakeActions()
    app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        labels = app.tree_labels()
        assert labels[0].startswith("tpg") and any("Refonte" in l for l in labels) and any("brain" in l for l in labels)
        await app.select_session("a1"); await pilot.press("enter")
        assert ("open", "a1") in acts.calls

@pytest.mark.asyncio
async def test_error_shown_not_crash():
    app = SessionPanel(load=lambda v: ([], "session-rows a échoué : boom"), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 20)):
        assert "boom" in app.status_text()

@pytest.mark.asyncio
async def test_palette_commands_present():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(80, 30)):
        titles = await app.palette_titles()
        for t in ("Ouvrir Refonte", "Priorité must · Bizdev", "Corbeille · Sessions", "Tri : projet",
                  "Filtre : Mac", "Synchroniser l'index", "Répliquer maintenant", "Prompt : /ai-brain:wrap-up"):
            assert any(t in x for x in titles), t

@pytest.mark.asyncio
async def test_trash_needs_confirmation():
    acts = FakeActions(); app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(80, 30)):
        app.request_trash(SESS[2]); assert ("trash", "c3") not in acts.calls
        app.request_trash(SESS[2]); assert ("trash", "c3") in acts.calls
```

`tree_labels()`, `select_session(id)`, `status_text()`, `palette_titles()` et `request_trash(s)` sont de petites méthodes publiques de l'app, utilisées par les tests et par la palette (pas de détour par les internes de Textual dans les tests).

- [ ] **Step 2: Échec** ; **Step 3: Implémenter `panel/app.py`**

Structure (code complet à écrire par l'implémenteur selon ce squelette) :

```python
"""Sessions panel: a Textual app living in a pinned Zellij floating pane."""
from __future__ import annotations
from functools import partial
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Provider, Hit, Hits, DiscoveryHit
from textual.widgets import Tree, Static, Input
from .model import Session, ViewState, group_by_subject

BADGE = {"must": "[b red]!![/]", "should": "[b yellow]! [/]", "may": "[dim]· [/]"}


def leaf_label(s: Session) -> str:
    marks = ("[green]●[/]" if s.running else "") + ("[yellow]⇢[/]" if s.lag else "") + ("[red]⚠[/]" if s.diverged else "")
    return f"{BADGE.get(s.priority, '  ')} {s.age:>3} {s.owner[:1]} {marks} {s.title}"


class SessionCommands(Provider):          # ouvrir / migrer / priorité / corbeille, par session
    def _items(self):
        app = self.app
        for s in app.sessions:
            yield f"Ouvrir {s.title}", partial(app.do_open, s), "Bascule ou crée son onglet"
            for lvl in ("must", "should", "may", "aucune"):
                yield f"Priorité {lvl} · {s.title}", partial(app.do_priority, s, "none" if lvl == "aucune" else lvl), None
            yield f"Corbeille · {s.title}", partial(app.request_trash, s), "Deux fois pour confirmer"

    async def discover(self) -> Hits:
        for title, cb, help_ in self._items():
            yield DiscoveryHit(title, cb, help=help_)

    async def search(self, query: str) -> Hits:
        m = self.matcher(query)
        for title, cb, help_ in self._items():
            if (score := m.match(title)) > 0:
                yield Hit(score, m.highlight(title), cb, help=help_)

# GlobalCommands : "Tri : activité/projet/priorité", "Filtre : Mac/Nexus/priorisées/aucun",
#   "Portée : sujet courant ↔ toutes", "Synchroniser l'index", "Répliquer maintenant"
# PromptCommands : "Prompt : <ligne>" pour chaque actions.prompts()
# (même forme que SessionCommands)


class SessionPanel(App):
    CSS = "Tree { height: 1fr; } #status { height: auto; color: $text-muted; }"
    COMMANDS = {SessionCommands, GlobalCommands, PromptCommands}
    BINDINGS = [Binding("enter", "open", "Ouvrir"), Binding("slash", "filter", "Filtrer"),
                Binding("escape", "clear", "Effacer"), Binding("q", "quit", "Fermer"),
                Binding("ctrl+space", "quit", "Fermer", show=False)]

    def __init__(self, load, actions, view: ViewState, on_view_change=None):
        super().__init__()
        self.load, self.acts, self.view, self.on_view_change = load, actions, view, on_view_change or (lambda v: None)
        self.sessions: list[Session] = []; self._error = None; self._pending_trash = None; self._text = ""

    def compose(self) -> ComposeResult:
        yield Input(placeholder="filtre…", id="filter")      # caché tant que '/' n'est pas pressé
        yield Tree("Sessions", id="tree")
        yield Static(id="status")

    def on_mount(self):
        self.query_one("#filter").display = False
        self.refresh_sessions(); self.set_interval(30, self.refresh_sessions)

    def refresh_sessions(self):
        self.sessions, self._error = self.load(self.view)
        ... # reconstruire l'arbre : un nœud par sujet (déplié), une feuille par session (data=session),
            # filtrée par self._text (sous-chaîne insensible à la casse sur titre/proj) ; status = erreur ou "N sessions · tri · filtre"

    # helpers publics : tree_labels(), select_session(id), status_text(), palette_titles() (await sur les providers),
    # do_open(s), do_priority(s, lvl), request_trash(s) (1er appel : arme + message "Encore une fois pour confirmer" ; 2e : trash),
    # do_sort(x), do_filter(x), do_scope(), do_sync(), do_replicate(), do_prompt(t) — chacun notifie le résultat dans #status et rafraîchit
    # action_open : session sous le curseur → do_open ; action_filter : affiche/focalise #filter ; action_clear : vide le filtre
```

L'implémenteur écrit le corps complet ; contraintes : aucune action ne lève vers Textual (try/except → message dans `#status`), la sélection est conservée après rafraîchissement (par id), les nœuds sujet restent dépliés.

- [ ] **Step 4: Succès** ; **Step 5: Commit** — `feat: Textual sessions panel with command palette`

---

### Task 5: Lanceur, config Zellij, intégration

**Files:**
- Create: `bin/session-panel`, `zellij/config.kdl`, `tests/test_panel_launcher.sh`
- Modify: `bin/sessions`, `install.sh`, `README.md`, `config.yml.template`
- Delete: `bin/session-layout`, `bin/session-tui`, `bin/session-tui-act`, `bin/session-home`, `tests/test_tui.sh`
- Repo `cc` : `cc.zsh`, `test.zsh`, `README.md`

**Interfaces:**
- Produces: `session-panel` (sans argument = bascule depuis un keybind ; `--docked` = lancé par `move_panel_to_current_tab`) ; `zellij/config.kdl`.

- [ ] **Step 1: `bin/session-panel`**

```python
#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["textual>=8,<9"]
# ///
"""session-panel — the sessions panel in a pinned Zellij floating pane.
No argument (keybind): if a sessions-panel already exists anywhere in this Zellij
session, close it (and exit) — that is the toggle; otherwise dock this pane and run.
--docked: launched by the panel itself in a new tab; dock and run."""
import os, sys, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ["PATH"] = f"{ROOT / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
from panel.zj import Zellij, PANEL_TITLE
from panel.model import ViewState, load_sessions
from panel.actions import Actions
from panel.app import SessionPanel

def main() -> int:
    zj = Zellij()
    if (msg := zj.available()):
        print(msg); input("⏎ "); return 1
    me = int(os.environ.get("ZELLIJ_PANE_ID", "-1"))
    others = [p for p in zj.panel_panes() if p["id"] != me]
    if "--docked" not in sys.argv and others:
        for p in others: zj.close_pane(p["id"])
        return 0                                   # toggle off: our own pane closes on exit
    for p in others: zj.close_pane(p["id"])
    zj.dock(me)
    claude_dir = pathlib.Path(os.environ.get("CLAUDE_DIR", pathlib.Path.home() / ".claude"))
    state_dir = claude_dir / "session-panel"
    view = ViewState.load(state_dir / "state.json")
    zname = os.environ.get("ZELLIJ_SESSION_NAME", "").removeprefix("cc-")
    view.subject = "" if zname == "sessions" else zname
    this = subprocess.run(["session-config", "machine"], capture_output=True, text=True).stdout.strip()
    rows_dir = state_dir / "rows-state"
    app = SessionPanel(load=lambda v: load_sessions(v, state_dir=rows_dir),
                       actions=Actions(zj, this, state_dir), view=view,
                       on_view_change=lambda v: v.save(state_dir / "state.json"))
    app.run()
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

Le keybind lance ce script dans un volet flottant épinglé nommé `sessions-panel` avec `close_on_exit true` : en mode bascule-off, le script ferme l'autre volet puis sort, son propre volet se ferme.

- [ ] **Step 2: `zellij/config.kdl`**

```kdl
// Session manager — installed to ~/.config/zellij/config.kdl when none exists.
show_startup_tips false
show_release_notes false
keybinds {
    shared {
        bind "Ctrl Space" {
            Run "session-panel" { floating true; pinned true; name "sessions-panel"; close_on_exit true; }
        }
    }
}
```

(`Run "session-panel"` suppose `~/.claude/skills/session/bin` dans le PATH du shell qui lance Zellij — c'est le cas via le `.zshrc`.)

- [ ] **Step 3: Test du lanceur** `tests/test_panel_launcher.sh` : avec le stub zellij de `tests/panel/zellij-stub` en tête de PATH sous le nom `zellij`, `ZELLIJ=0`, `ZELLIJ_PANE_ID=5` et un `list-panes` contenant un `sessions-panel` d'id 3 : `session-panel` (sans arg) → journal contient `close-pane --pane-id terminal_3`, sort 0 sans lancer l'app (vérifier qu'aucun `change-floating-pane-coordinates` n'est journalisé). Sans autre volet et avec `SESSION_PANEL_DRY_RUN=1` (ajouter ce garde-fou au lanceur : sort juste avant `app.run()`) → `change-floating-pane-coordinates --pane-id terminal_5 …` journalisé.

- [ ] **Step 4: `bin/sessions`** — remplacer le bloc TTY : `exec zellij attach -c "cc-${SUBJ:-sessions}"` avec `cd` sur la racine du sujet (via `session-subject-roots`) ; garder `--plain`.

- [ ] **Step 5: Retirer l'interface tmux** — `git rm bin/session-layout bin/session-tui bin/session-tui-act bin/session-home tests/test_tui.sh` ; retirer leurs mentions du README ; le stub `tmux` de `tests/lib_machines.sh` peut rester (inoffensif).

- [ ] **Step 6: `install.sh`** — après la section settings :

```bash
# ── 4c. Zellij panel: config (only if none) + default prompts ───────────────
ZCFG="${XDG_CONFIG_HOME:-$HOME/.config}/zellij/config.kdl"
if [ ! -f "$ZCFG" ]; then
  mkdir -p "$(dirname "$ZCFG")"; cp "$INSTALL_DIR/zellij/config.kdl" "$ZCFG"
  echo "✓  Zellij config installed ($ZCFG)"
else
  echo "ℹ️  $ZCFG exists — add the Ctrl Space keybind from $INSTALL_DIR/zellij/config.kdl by hand"
fi
PROMPTS="${XDG_CONFIG_HOME:-$HOME/.config}/session-panel/prompts.txt"
[ -f "$PROMPTS" ] || { mkdir -p "$(dirname "$PROMPTS")"; printf '# One prompt per line — sent by the panel palette\n/ai-brain:wrap-up\n/ai-brain:save\n' > "$PROMPTS"; }
command -v zellij >/dev/null || echo "⚠  zellij not found — Mac: brew install zellij ; Linux: binary in ~/.local/bin"
command -v uv >/dev/null || echo "⚠  uv not found — https://docs.astral.sh/uv/ (needed by session-panel)"
```

- [ ] **Step 7: Repo `cc`** (worktree séparé, branche `feat/zellij`) — `cc <sujet>` : `zellij attach -c cc-<sujet>` lancé depuis la racine du sujet (au lieu de `claude agents --cwd`) ; `cc agents [<sujet>]` = ancienne vue agents filtrée ; `cc all` inchangé ; `cc tmux` retiré (message « remplacé par cc <sujet> »). Mettre à jour `test.zsh` (mock `zellij` imprimant son argv) et le README.

- [ ] **Step 8: README** — section « Session manager » réécrite : Zellij, `Ctrl+Espace`, palette `Ctrl+P` et ses commandes, prompts favoris, `cc <sujet>`, installation (zellij, uv), Nexus (binaires `~/.local/bin`).

- [ ] **Step 9: Suite complète** — `bash tests/run_tests.sh` → `0 failed` ; `zsh ./test.zsh` (cc) → tous ok.

- [ ] **Step 10: Commits** — repo session : `feat: Zellij panel launcher, config, install; drop the tmux UI` ; repo cc : `cc : <sujet> ouvre la session Zellij, cc agents garde la vue agents`.
