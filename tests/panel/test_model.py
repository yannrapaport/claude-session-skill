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
