import pytest
from textual.worker import WorkerState
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


async def settle(app, pilot):
    """Loads and actions run in thread workers: wait until none is left, then let the UI catch up."""
    for _ in range(10):
        live = [w for w in app.workers if w.state in (WorkerState.PENDING, WorkerState.RUNNING)]
        if not live:
            break
        await app.workers.wait_for_complete(live)
        await pilot.pause()
    await pilot.pause()


@pytest.mark.asyncio
async def test_tree_groups_and_open():
    acts = FakeActions()
    app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        labels = app.tree_labels()
        assert labels[0].startswith("tpg") and any("Refonte" in l for l in labels) and any("brain" in l for l in labels)
        await app.select_session("a1"); await pilot.press("enter")
        await settle(app, pilot)
        assert ("open", "a1") in acts.calls


@pytest.mark.asyncio
async def test_error_shown_not_crash():
    app = SessionPanel(load=lambda v: ([], "session-rows a échoué : boom"), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 20)) as pilot:
        await settle(app, pilot)
        assert "boom" in app.status_text()


@pytest.mark.asyncio
async def test_palette_commands_present():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(80, 30)) as pilot:
        await settle(app, pilot)
        titles = await app.palette_titles()
        for t in ("Ouvrir Refonte", "Priorité must · Bizdev", "Corbeille · Sessions", "Tri : projet",
                  "Filtre : Mac", "Synchroniser l'index", "Répliquer maintenant", "Prompt : /ai-brain:wrap-up"):
            assert any(t in x for x in titles), t


@pytest.mark.asyncio
async def test_trash_needs_confirmation():
    acts = FakeActions(); app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(80, 30)) as pilot:
        await settle(app, pilot)
        app.request_trash(SESS[2]); await settle(app, pilot)
        assert ("trash", "c3") not in acts.calls
        assert any("Confirmer la corbeille de Bizdev" in t for t in await app.palette_titles())
        app.request_trash(SESS[2]); await settle(app, pilot)
        assert ("trash", "c3") in acts.calls


# ── beyond the brief ──

@pytest.mark.asyncio
async def test_trash_arming_expires(monkeypatch):
    import panel.app as mod
    now = [1000.0]
    monkeypatch.setattr(mod, "_now", lambda: now[0])
    acts = FakeActions(); app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(80, 30)) as pilot:
        await settle(app, pilot)
        app.request_trash(SESS[2]); now[0] += 11
        app.request_trash(SESS[2]); await settle(app, pilot)
        assert ("trash", "c3") not in acts.calls  # second call re-armed instead of confirming


@pytest.mark.asyncio
async def test_selection_survives_refresh():
    data = [list(SESS)]
    app = SessionPanel(load=lambda v: (data[0], None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await app.select_session("c3")
        data[0] = [S("z9", "aaa", "Nouvelle")] + list(SESS)
        app.refresh_sessions(); await settle(app, pilot)
        assert app.selected_session().id == "c3"


@pytest.mark.asyncio
async def test_text_filter_and_escape():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press("slash")
        await pilot.press(*"biz")
        await pilot.pause()
        labels = app.tree_labels()
        assert any("Bizdev" in l for l in labels) and not any("Refonte" in l for l in labels)
        await pilot.press("escape"); await pilot.pause()
        assert any("Refonte" in l for l in app.tree_labels())


@pytest.mark.asyncio
async def test_empty_state_message():
    app = SessionPanel(load=lambda v: ([], None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 20)) as pilot:
        await settle(app, pilot)
        assert "Aucune session" in app.status_text()


@pytest.mark.asyncio
async def test_global_command_updates_view_and_persists():
    seen = []
    view = ViewState()
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=view, on_view_change=seen.append)
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        app.do_sort("project"); await settle(app, pilot)
        app.do_filter("mac"); await settle(app, pilot)
        assert view.sort == "project" and view.filter == "mac" and len(seen) == 2
        assert "projet" in app.status_text()


@pytest.mark.asyncio
async def test_action_failure_is_reported_not_raised():
    class Boom(FakeActions):
        def sync(self): raise RuntimeError("kaput")
    app = SessionPanel(load=lambda v: (SESS, None), actions=Boom(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        app.do_sync(); await settle(app, pilot)
        assert "kaput" in app.status_text()
