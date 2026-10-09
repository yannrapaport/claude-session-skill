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

class BadZ(FakeZ):
    def new_tab(self, n, cwd, cmd): raise RuntimeError("zellij: échec")

def test_open_failure_returns_message_and_records_nothing(mk, tmp_path):
    msg = mk(BadZ()).open(S())
    assert "échec" in msg
    assert not (tmp_path / "tabs.json").exists()

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
