import pytest
from textual.worker import WorkerState
from panel.model import Session, ViewState
from panel.app import SessionPanel


def S(i, subj, title, **kw):
    base = dict(id=i, owner="mac", machine="mac", priority="", subject=subj, proj=subj, title=title, age="1h",
                last_activity="", running=False, lag=False, diverged=False)
    return Session(**{**base, **kw})


class FakeActions:
    def __init__(self): self.calls = []; self.prompt_reads = 0
    def open(self, s): self.calls.append(("open", s.id)); return "→ ok"
    def set_priority(self, s, lvl): self.calls.append(("prio", s.id, lvl)); return "ok"
    def trash(self, s): self.calls.append(("trash", s.id)); return "ok"
    def sync(self): self.calls.append(("sync",)); return "ok"
    def replicate(self): self.calls.append(("replicate",)); return "ok"
    def prompts(self): self.prompt_reads += 1; return ["/ai-brain:wrap-up"]
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
        assert "Priorité must" not in titles and "Corbeille" not in titles   # nothing selected yet
        await app.select_session("c3")
        titles = await app.palette_titles()
        for t in ("Ouvrir Refonte", "Ouvrir Sessions", "Priorité must", "Priorité aucune", "Corbeille", "Tri : projet",
                  "Filtre : Mac", "Synchroniser l'index", "Répliquer maintenant", "Prompt : /ai-brain:wrap-up"):
            assert any(t in x for x in titles), t
        assert not any("·" in t and "Priorité" in t for t in titles)   # short titles, session in the help


@pytest.mark.asyncio
async def test_trash_needs_confirmation():
    acts = FakeActions(); app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(80, 30)) as pilot:
        await settle(app, pilot)
        app.request_trash(SESS[2]); await settle(app, pilot)
        assert ("trash", "c3") not in acts.calls
        await app.select_session("c3")
        assert "Confirmer la corbeille" in await app.palette_titles()
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


# ── review fixes ──

@pytest.mark.asyncio
async def test_markup_in_user_text_does_not_crash_palette():
    class A(FakeActions):
        def prompts(self): return ["[b]x"]
    sess = [S("d4", "tpg", "bad [/] title")]
    app = SessionPanel(load=lambda v: (sess, None), actions=A(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await app.select_session("d4")
        titles = await app.palette_titles()
        assert "Ouvrir bad [/] title" in titles and "Prompt : [b]x" in titles
        await pilot.press("ctrl+k"); await pilot.pause(0.3)
        await pilot.press(*"bad"); await pilot.pause(0.3)
        await pilot.press("backspace", "backspace", "backspace", "x"); await pilot.pause(0.3)
        await pilot.press("escape"); await pilot.pause()
        assert app.is_running


@pytest.mark.asyncio
async def test_markup_in_filter_text_does_not_crash():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press("slash")
        app._filter.value = "[/]"; await pilot.pause()
        assert app.is_running and "[/]" in app.status_text()


@pytest.mark.asyncio
async def test_actions_are_serialised():
    import threading
    gate = threading.Event()
    class Slow(FakeActions):
        def open(self, s):
            self.calls.append(("open", s.id)); gate.wait(5); return "→ ok"
    acts = Slow()
    app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await app.select_session("a1")
        await pilot.press("enter"); await pilot.pause()
        await pilot.press("enter"); await pilot.pause()
        assert "déjà en cours" in app.status_text()
        gate.set(); await settle(app, pilot)
        assert acts.calls.count(("open", "a1")) == 1
        await pilot.press("enter"); await settle(app, pilot)   # free again once done
        assert acts.calls.count(("open", "a1")) == 2


@pytest.mark.asyncio
async def test_single_click_selects_double_click_opens():
    acts = FakeActions()
    app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await pilot.click("#tree", offset=(12, 1)); await settle(app, pilot)
        assert app.selected_session().id == "a1" and not any(c[0] == "open" for c in acts.calls)
        await pilot.double_click("#tree", offset=(12, 1)); await settle(app, pilot)
        assert ("open", "a1") in acts.calls


@pytest.mark.asyncio
async def test_trash_arming_survives_refresh_and_expiry_clears_message(monkeypatch):
    import panel.app as mod
    now = [1000.0]
    monkeypatch.setattr(mod, "_now", lambda: now[0])
    acts = FakeActions(); app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        app.request_trash(SESS[2])
        app.refresh_sessions(); await settle(app, pilot)
        app.request_trash(SESS[2]); await settle(app, pilot)
        assert ("trash", "c3") in acts.calls
        app.request_trash(SESS[1]); assert "encore une fois" in app.status_text()
        now[0] += 11; app.expire_trash()
        assert "encore une fois" not in app.status_text() and not app.trash_armed_for(SESS[1])


@pytest.mark.asyncio
async def test_open_tab_is_highlighted():
    class A(FakeActions):
        def open_ids(self): return {"a1"}
    app = SessionPanel(load=lambda v: (SESS, None), actions=A(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        tpg = app._tree.root.children[0]
        refonte, bizdev = tpg.children[0].label, tpg.children[1].label
        assert "▸Refonte" in refonte.plain and "▸" not in bizdev.plain
        assert any("cyan" in str(sp.style) for sp in refonte.spans if refonte.plain[sp.start:sp.end] == "Refonte")


@pytest.mark.asyncio
async def test_bad_load_result_ends_loading_with_error():
    app = SessionPanel(load=lambda v: (5, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 20)) as pilot:
        await settle(app, pilot)
        assert "Chargement impossible" in app.status_text() and "↻" not in app.status_text()


@pytest.mark.asyncio
async def test_prompts_read_per_refresh_not_per_keystroke():
    acts = FakeActions()
    app = SessionPanel(load=lambda v: (SESS, None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        reads = acts.prompt_reads
        for _ in range(5):
            await app.palette_titles()
        assert acts.prompt_reads == reads == 1


@pytest.mark.asyncio
async def test_unknown_machine_is_flagged():
    acts = FakeActions(); acts.this = ""
    app = SessionPanel(load=lambda v: ([], None), actions=acts, view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        assert "machine inconnue" in app.status_text()


# ── final fix wave ──

@pytest.mark.asyncio
@pytest.mark.parametrize("key", ["p", "ctrl+k"])
async def test_palette_keys_reachable_inside_zellij(key):
    """Zellij eats Ctrl p (pane mode): the palette opens on p and Ctrl k."""
    from textual.command import CommandPalette
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press(key); await pilot.pause(0.2)
        assert isinstance(app.screen, CommandPalette)
        assert "^P" not in str(app.query_one("#keys").render())


@pytest.mark.asyncio
async def test_p_in_filter_box_types_a_p():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState())
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        await pilot.press("slash", "p"); await pilot.pause()
        assert app._filter.value == "p"


@pytest.mark.asyncio
async def test_timer_refresh_is_light_and_keeps_running_markers():
    """Timer: light load (no `claude agents`), running markers carried over. r / after an action: full load."""
    calls = []
    full = lambda v: (calls.append("full"), ([S("a1", "tpg", "Refonte", running=True)], None))[1]
    light = lambda v: (calls.append("light"), ([S("a1", "tpg", "Refonte"), S("n1", "tpg", "Neuve")], None))[1]
    acts = FakeActions()
    app = SessionPanel(load=full, load_light=light, actions=acts, view=ViewState(), refresh_seconds=3600)
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        assert calls == ["full"]
        app.timer_refresh(); await settle(app, pilot)
        assert calls == ["full", "light"]
        assert {s.id: s.running for s in app.sessions} == {"a1": True, "n1": False}
        await pilot.press("r"); await settle(app, pilot)
        assert calls[-1] == "full" and app.sessions[0].running
        app.do_sync(); await settle(app, pilot)
        assert calls[-1] == "full"


@pytest.mark.asyncio
async def test_refresh_interval_is_configurable():
    app = SessionPanel(load=lambda v: (SESS, None), actions=FakeActions(), view=ViewState(), refresh_seconds=7)
    async with app.run_test(size=(36, 30)) as pilot:
        await settle(app, pilot)
        assert app._refresh_timer is not None and app._refresh_timer._interval == 7
