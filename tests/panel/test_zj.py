import json, pathlib, stat
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
    assert "action go-to-tab-name -- Refonte" in L
    assert "action close-pane --pane-id terminal_3" in L
    assert any(l.startswith("action change-floating-pane-coordinates --pane-id terminal_5 -x 0 -y 0 --width 36 --height 100%") for l in L)
    assert "action write-chars --pane-id terminal_0 -- /ai-brain:wrap-up" in L
    assert "action write --pane-id terminal_0 13" in L

def test_new_tab_and_panel(zj):
    zj.new_tab("Refonte", "/tmp", ["claude", "--resume", "abc"])
    zj.open_panel_in_tab(1, ["panel-cmd"])
    L = log(zj)
    assert "action new-tab --name=Refonte --cwd=/tmp -- claude --resume abc" in L
    assert "action new-pane --floating --pinned true --name sessions-panel --tab-id 1 -- panel-cmd" in L

def test_unavailable(monkeypatch, tmp_path):
    monkeypatch.delenv("ZELLIJ", raising=False); monkeypatch.delenv("ZELLIJ_SESSION_NAME", raising=False)
    assert "Zellij" in Zellij(binary=str(STUB)).available()
    assert "introuvable" in Zellij(binary=str(tmp_path / "nope")).available()
    assert Zellij(binary=str(STUB), session="s").available() is None

def test_run_errors_are_french_runtime_errors(tmp_path, monkeypatch):
    monkeypatch.setenv("ZELLIJ", "0")
    with pytest.raises(RuntimeError, match="introuvable"):
        Zellij(binary=str(tmp_path / "nope")).tabs()
    import subprocess
    def boom(*a, **k): raise subprocess.TimeoutExpired("zellij", 15)
    with pytest.raises(RuntimeError, match="trop long"):
        Zellij(runner=boom).tabs()

def _set(zj, name, data):
    (zj.log.parent / name).write_text(data if isinstance(data, str) else json.dumps(data))

@pytest.mark.parametrize("bad", ["garbage", '{"a": 1}', '[1, 2]', '[{"tab_id": 0}]'])
def test_malformed_tabs(zj, bad):
    _set(zj, "t.json", bad)
    with pytest.raises(RuntimeError, match="illisible"):
        zj.tab_names()

def test_malformed_panes(zj):
    _set(zj, "p.json", "nope")
    with pytest.raises(RuntimeError, match="illisible"):
        zj.panes()

def test_oserror_and_nonzero(zj, monkeypatch):
    def denied(*a, **k): raise PermissionError("denied")
    with pytest.raises(RuntimeError, match="impossible"):
        Zellij(runner=denied).tabs()
    class P: returncode, stdout, stderr = 1, "", "boom"
    with pytest.raises(RuntimeError, match="boom"):
        Zellij(runner=lambda *a, **k: P()).tabs()

def test_dash_leading_text(zj):
    zj.write_to_pane(0, "-rf")
    assert "action write-chars --pane-id terminal_0 -- -rf" in log(zj)

def test_panel_detected_by_command_when_title_rewritten(zj):
    panes = [
        {"id": 0, "is_plugin": False, "is_floating": False, "is_focused": False, "title": "zsh", "tab_id": 0},
        {"id": 4, "is_plugin": False, "is_floating": True, "is_focused": True, "title": "Textual", "pane_command": "python -m session-panel", "tab_id": 0},
    ]
    _set(zj, "p.json", panes)
    assert [p["id"] for p in zj.panel_panes()] == [4]
    assert zj.focused_terminal_in_current_tab() == 0

def test_panel_focused_falls_back_to_first_nonfloating(zj):
    panes = [
        {"id": 7, "is_plugin": False, "is_floating": True, "is_focused": False, "title": "other", "tab_id": 0},
        {"id": 0, "is_plugin": False, "is_floating": False, "is_focused": False, "title": "zsh", "tab_id": 0},
        {"id": 3, "is_plugin": False, "is_floating": True, "is_focused": True, "title": "sessions-panel", "tab_id": 0},
    ]
    _set(zj, "p.json", panes)
    assert zj.focused_terminal_in_current_tab() == 0

def test_new_tab_dash_name(zj):
    zj.new_tab("-dash tab", "/tmp", ["claude"])
    assert "action new-tab --name=-dash tab --cwd=/tmp -- claude" in log(zj)
