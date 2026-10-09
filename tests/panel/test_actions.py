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
        self._ids = {n: i for i, n in enumerate(self._tabs)}; self._next = 100
    def tabs(self): return [{"tab_id": self._ids.get(n, -1), "name": n} for n in self._tabs]
    def tab_names(self): return list(self._tabs)
    def current_tab_id(self): return self.current
    def go_to_tab(self, n): self.calls.append(("go", n))
    def go_to_tab_id(self, i): self.calls.append(("go", i))
    def new_tab(self, n, cwd, cmd):
        self.calls.append(("new", n, cwd, cmd)); self._tabs.append(n); self.current = len(self._tabs) - 1
        self._next += 1; self._ids[n] = self._next; return self._next
    def rename(self, old, new): self._tabs[self._tabs.index(old)] = new; self._ids[new] = self._ids.pop(old)
    def panel_panes(self): return [{"id": i} for i in self.panels]
    def close_pane(self, i): self.calls.append(("close", i))
    def open_panel_in_tab(self, t, cmd): self.calls.append(("panel", t))
    def focused_terminal_in_current_tab(self, exclude_title="sessions-panel"): return self.focused
    def write_to_pane(self, i, t): self.calls.append(("write", i, t))

@pytest.fixture
def mk(tmp_path, monkeypatch):
    monkeypatch.setenv("ZELLIJ_SESSION_NAME", "cc-tpg")
    def make(z, runner=None, session=None):
        return Actions(z, "mac", tmp_path, runner=runner or (lambda *a, **k: subprocess.CompletedProcess(a[0], 0, "", "")),
                       cwd_for=lambda s: "/tmp", session=session)
    return make

def test_tab_name_rules(mk):
    a = mk(FakeZ())
    assert a.tab_name_for(S(title='A "very" long title that goes on and on'), []) == "A very long title that g"
    assert a.tab_name_for(S(), ["Refonte pricing"]) == "Refonte pricing ·aaaa"

def test_command_rules(mk):
    a = mk(FakeZ())
    assert a.command_for(S()) == ["session-open", "aaaa1111-0000"]
    assert a.command_for(S(owner="nexus"))[0] == "bash" and "session-migrate aaaa1111-0000" in a.command_for(S(owner="nexus"))[2]
    assert a.command_for(S(owner="nexus", diverged=True)) == ["session-diverge", "aaaa1111-0000"]
    assert a.command_for(S(diverged=True)) == ["session-open", "aaaa1111-0000"]   # owner's copy is never "diverged"
    blind = Actions(FakeZ(), "", a.state_dir, cwd_for=lambda s: "/tmp")           # machine unknown
    assert blind.command_for(S(owner="nexus", diverged=True)) == ["session-open", "aaaa1111-0000"]
    with pytest.raises(ValueError): a.command_for(S(id="../x"))

def test_open_new_then_existing_then_stale(mk, tmp_path):
    z = FakeZ(panels=[3]); a = mk(z)
    a.open(S())                                    # new tab + panel moved
    assert ("new", "Refonte pricing", "/tmp", ["session-open", "aaaa1111-0000"]) in z.calls
    assert ("close", 3) in z.calls and ("panel", 1) in z.calls
    z.calls.clear(); a.open(S())                    # existing tab → go (by its stable id)
    assert z.calls[0] == ("go", 101)
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

class BadZ(FakeZ):
    def new_tab(self, n, cwd, cmd): raise RuntimeError("zellij: échec")

def test_open_failure_returns_message_and_records_nothing(mk, tmp_path):
    msg = mk(BadZ()).open(S())
    assert "échec" in msg
    assert not list(tmp_path.glob("tabs*.json"))

def test_panel_opened_before_old_closed(mk):
    z = FakeZ(panels=[3]); mk(z).move_panel_to_current_tab()
    assert [c[0] for c in z.calls] == ["panel", "close"]

def test_script_errors_return_message(mk):
    def boom(cmd, **kw): raise OSError("nope")
    a = mk(FakeZ(), runner=boom)
    for m in (a.sync(), a.replicate(), a.trash(S()), a.set_priority(S(), "must")):
        assert isinstance(m, str) and m
    assert "invalide" in a.trash(S(id="../x"))

def test_send_prompt_failure(mk):
    class W(FakeZ):
        def write_to_pane(self, i, t): raise RuntimeError("boom")
    assert "boom" in mk(W()).send_prompt("x")

def test_tab_name_strips(mk):
    assert mk(FakeZ()).tab_name_for(S(title="  x  "), []) == "x"

def test_tab_name_reuse_does_not_corrupt_registry(mk, tmp_path):
    z = FakeZ(); a = mk(z)
    A, B = S(id="aaaa1111"), S(id="bbbb2222")
    a.open(A); z._tabs.remove("Refonte pricing")      # A's tab closed by hand
    a.open(B)                                          # B takes the plain name
    z.calls.clear(); a.open(A)                         # A must get its own tab, not jump to B's
    assert z.calls[0][0] == "new" and z.calls[0][1] == "Refonte pricing ·aaaa"
    reg = json.loads((tmp_path / "tabs-cc-tpg.json").read_text())
    assert reg == {"bbbb2222": {"tab_id": 102, "name": "Refonte pricing"},
                   "aaaa1111": {"tab_id": 103, "name": "Refonte pricing ·aaaa"}}

def test_move_panel_own_pane_last_and_none_tab(mk, monkeypatch):
    monkeypatch.setenv("ZELLIJ_PANE_ID", "3")
    z = FakeZ(panels=[3, 5, 6]); mk(z).move_panel_to_current_tab()
    assert [c for c in z.calls if c[0] == "close"] == [("close", 5), ("close", 6), ("close", 3)]
    z2 = FakeZ(panels=[3]); z2.current = None; mk(z2).move_panel_to_current_tab()
    assert z2.calls == []

def test_id_validation_strict(mk):
    a = mk(FakeZ())
    for bad in ("aaaa\n", "-abc", "", "../x"):
        with pytest.raises(ValueError): a.command_for(S(id=bad))

def test_save_failure_still_moves_panel(mk, monkeypatch):
    z = FakeZ(panels=[3]); a = mk(z)
    monkeypatch.setattr(a, "_save_tabs", lambda d: (_ for _ in ()).throw(OSError("ro")))
    msg = a.open(S())
    assert "non mémorisé" in msg and "Échec" not in msg and ("panel", 1) in z.calls

def test_script_nonzero_exit_message(mk):
    def run(cmd, **kw): return subprocess.CompletedProcess(cmd, 2, "out\n", "bad thing\n")
    assert mk(FakeZ(), runner=run).sync() == "Échec : bad thing"


def test_open_ids(mk):
    z = FakeZ(); a = mk(z)
    assert a.open_ids() == set()
    a.open(S())
    assert a.open_ids() == {"aaaa1111-0000"}
    z._tabs = ["Tab #1"]                      # tab closed by hand
    assert a.open_ids() == set()
    class Broken(FakeZ):
        def tab_names(self): raise RuntimeError("zellij down")
    assert mk(Broken()).open_ids() == set()


# ── final fix wave ──

def test_registry_is_per_zellij_session(mk, tmp_path):
    """Tab names and ids are per Zellij session: two sessions never read each other's tabs."""
    z1, z2 = FakeZ(), FakeZ()
    a1, a2 = mk(z1, session="cc-tpg"), mk(z2, session="cc-brain")
    a1.open(S())
    z2._tabs.append("Refonte pricing"); z2._ids["Refonte pricing"] = 101   # same name AND id, other session
    z2.calls.clear(); a2.open(S())
    assert z2.calls[0][0] == "new"                                     # not a jump into a1's tab
    assert a2.open_ids() == {"aaaa1111-0000"} and a1.open_ids() == {"aaaa1111-0000"}
    assert sorted(p.name for p in tmp_path.glob("tabs*.json")) == ["tabs-cc-brain.json", "tabs-cc-tpg.json"]

def test_registry_file_name_is_sanitised(mk, tmp_path):
    mk(FakeZ(), session="../../evil name").open(S())
    assert [p.parent for p in tmp_path.rglob("tabs*.json")] == [tmp_path]

def test_renamed_tab_is_recreated(mk):
    z = FakeZ(); a = mk(z)
    a.open(S()); z.rename("Refonte pricing", "mine")
    z.calls.clear(); a.open(S())
    assert z.calls[0][0] == "new"
    assert a.open_ids() == {"aaaa1111-0000"}

def test_closed_tab_whose_name_is_reused_is_recreated(mk):
    """Same name, different tab (closed by hand, then a new one with that name): not ours."""
    z = FakeZ(); a = mk(z)
    a.open(S()); z._tabs.remove("Refonte pricing"); z._ids.pop("Refonte pricing")
    z._tabs.append("Refonte pricing"); z._ids["Refonte pricing"] = 999
    assert a.open_ids() == set()
    z.calls.clear(); a.open(S())
    assert z.calls[0][0] == "new"

def test_pruning_is_persisted_on_every_open(mk, tmp_path):
    z = FakeZ(); a = mk(z)
    A, B = S(id="aaaa1111"), S(id="bbbb2222", title="Autre")
    a.open(A); a.open(B)
    z._tabs.remove("Refonte pricing")                  # A's tab closed by hand
    a.open(B)                                          # reuse only — still prunes A
    assert set(json.loads((tmp_path / "tabs-cc-tpg.json").read_text())) == {"bbbb2222"}

def test_legacy_registry_entries_are_ignored(mk, tmp_path):
    (tmp_path / "tabs-cc-tpg.json").write_text(json.dumps({"aaaa1111-0000": "Tab #1"}))
    z = FakeZ(); a = mk(z)
    assert a.open_ids() == set()
    a.open(S()); assert z.calls[0][0] == "new"

def test_new_tab_without_id_falls_back_to_name(mk):
    class NoId(FakeZ):
        def new_tab(self, n, cwd, cmd): super().new_tab(n, cwd, cmd); return None
    z = NoId(); a = mk(z)
    a.open(S()); z.calls.clear(); a.open(S())
    assert z.calls[0] == ("go", "Refonte pricing")

def test_unknown_machine_refuses_to_open(tmp_path):
    z = FakeZ(); a = Actions(z, "", tmp_path, cwd_for=lambda s: "/tmp")
    msg = a.open(S())
    assert "machine inconnue" in msg and "ouverture désactivée" in msg
    assert z.calls == []
