"""Sessions panel: a Textual app living in a pinned Zellij floating pane."""
from __future__ import annotations
import time
from functools import partial
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Provider, Hit, Hits, DiscoveryHit
from textual import events
from textual.containers import Vertical
from textual.content import Content
from textual.markup import escape
from textual.widgets import Tree, Static, Input
from textual.worker import get_current_worker
from .model import Session, ViewState, group_by_subject

BADGE = {"must": ("!!", "bold red"), "should": ("! ", "bold yellow"), "may": ("· ", "dim")}
SORT_FR = {"activity": "activité", "project": "projet", "priority": "priorité"}
FILTER_FR = {"": "aucun", "mac": "Mac", "nexus": "Nexus", "prio": "priorisées"}
ARM_SECONDS = 10
LEAF_INDENT = 4   # tree guides (2 levels × guide_depth 2)
SCROLLBAR = 1
_now = time.monotonic   # indirection so tests can move the clock


def leaf_label(s: Session, width: int = 36, is_open: bool = False) -> Text:
    """badge · age · owner · title · markers, title shortened so markers always fit.

    A session whose tab is open gets a cyan ▸ before a bold cyan title."""
    badge, style = BADGE.get(s.priority, ("  ", ""))
    marks = [m for m, on in (("●", s.running), ("⇢", s.lag), ("⚠", s.diverged)) if on]
    fixed = 2 + 1 + 3 + 1 + 1 + 1 + (1 + len(marks) if marks else 0)
    room = max(6, width - fixed)
    title = s.title or s.id[:8]
    if len(title) > room:
        title = title[: room - 1] + "…"
    t = Text(no_wrap=True, overflow="ellipsis")
    t.append(badge, style=style)
    t.append(f" {(s.age or '')[:3]:>3} ", style="dim")
    t.append((s.owner or "?")[:1], style="dim italic")
    t.append("▸" if is_open else " ", style="bold cyan")
    t.append(title, style="bold cyan" if is_open else "bold" if s.running else "")
    if marks:
        t.append(" ")
        for m in marks:
            t.append(m, style={"●": "green", "⇢": "yellow", "⚠": "bold red"}[m])
    return t


def subject_label(subject: str, items: list[Session]) -> Text:
    t = Text(no_wrap=True, overflow="ellipsis")
    if subject == "~":
        t.append("sans sujet", style="italic")
    else:
        t.append(subject, style="bold")
    t.append(f"  {len(items)}", style="dim")
    running = sum(1 for s in items if s.running)
    if running:
        t.append(f"  ●{running}", style="green")
    if any(s.priority == "must" for s in items):
        t.append("  !!", style="bold red")
    return t


def _highlight(matcher, title: str) -> Content:
    """Matcher.highlight() parses markup; highlight the plain title instead."""
    content = Content(title)
    _, offsets = matcher.fuzzy_search.match(matcher.query, title)
    for o in offsets:
        if not title[o].isspace():
            content = content.stylize(matcher.match_style, o, o + 1)
    return content


class _ListProvider(Provider):
    """Provider over a list of (title, callback, help) — same discover/search for all three sources."""

    def _items(self):
        return []

    # Titles and help carry user data (session titles, prompt lines): never let Textual parse them as markup.
    async def discover(self) -> Hits:
        for title, cb, help_ in self._items():
            yield DiscoveryHit(Content(title), cb, text=title, help=escape(help_) if help_ else None)

    async def search(self, query: str) -> Hits:
        m = self.matcher(query)
        for title, cb, help_ in self._items():
            if (score := m.match(title)) > 0:
                yield Hit(score, _highlight(m, title), cb, text=title, help=escape(help_) if help_ else None)


class SessionCommands(_ListProvider):
    """Open any session; priority / trash / migrate apply to the selected one."""

    def _items(self):
        app = self.app
        for s in app.sessions:
            yield f"Ouvrir {s.title}", partial(app.do_open, s), "Onglet existant ou nouveau"
        s = app.selected_session()
        if s is None:
            return
        this = getattr(app.acts, "this", None)
        if this and s.owner and s.owner != this:
            yield "Migrer ici", partial(app.do_open, s), f"{s.title} — depuis {s.owner}"
        for lvl in ("must", "should", "may", "aucune"):
            yield f"Priorité {lvl}", partial(app.do_priority, s, "none" if lvl == "aucune" else lvl), s.title
        if app.trash_armed_for(s):
            yield "Confirmer la corbeille", partial(app.request_trash, s), s.title
        else:
            yield "Corbeille", partial(app.request_trash, s), f"{s.title} — deux fois pour confirmer"


class GlobalCommands(_ListProvider):
    def _items(self):
        app = self.app
        for key, fr in SORT_FR.items():
            yield f"Tri : {fr}", partial(app.do_sort, key), None
        for key in ("mac", "nexus", "prio", ""):
            yield f"Filtre : {FILTER_FR[key]}", partial(app.do_filter, key), None
        yield "Portée : sujet courant ↔ toutes", app.do_scope, None
        yield "Synchroniser l'index", app.do_sync, "session-hub-sync"
        yield "Répliquer maintenant", app.do_replicate, "session-replicate"


class PromptCommands(_ListProvider):
    def _items(self):
        app = self.app
        for line in app.prompt_lines:
            yield f"Prompt : {line}", partial(app.do_prompt, line), "Envoyé au volet de session de l'onglet"


class SessionTree(Tree):
    """Mouse: a single click only moves the cursor (and folds a subject); a double click selects."""

    async def _on_click(self, event: events.Click) -> None:
        event.prevent_default()   # Textual also dispatches Tree._on_click (MRO) unless prevented
        async with self.lock:
            meta = event.style.meta
            if "line" not in meta:
                return
            node = self.get_node_at_line(meta["line"])
            if meta.get("toggle", False):
                if node is not None:
                    self._toggle_node(node)
                return
            self.cursor_line = meta["line"]
            if event.chain >= 2 or (node is not None and node.allow_expand):
                await self.run_action("select_cursor")


class SessionPanel(App):
    TITLE = "Sessions"
    CSS = """
    Screen { background: $background; }
    #top { height: 1; padding: 0 1; background: $panel; }
    #filter { height: 1; border: none; padding: 0 1; margin: 0; background: $boost; }
    #filter:focus { border: none; }
    #tree { height: 1fr; padding: 0; background: $background; scrollbar-size-vertical: 1; }
    #empty { height: 1fr; content-align: center middle; text-align: center; color: $text-muted; padding: 0 2; }
    #status { height: auto; max-height: 3; padding: 0 1; }
    #keys { height: 1; padding: 0 1; background: $panel; color: $text-muted; }
    /* narrow pane: keep the palette compact */
    CommandPalette > Vertical { margin-top: 1; }
    CommandPalette #--input { border: none; border-bottom: hkey $border; }
    CommandPalette #--input Label { margin-top: 0; }
    CommandPalette CommandInput { padding: 0 1; }
    """
    COMMANDS = {SessionCommands, GlobalCommands, PromptCommands}
    # Zellij binds Ctrl p (pane mode): Textual's default palette key never arrives. Declaring our own
    # command_palette bindings replaces it (Textual only adds the default when none is declared).
    COMMAND_PALETTE_BINDING = "ctrl+k"
    BINDINGS = [
        Binding("enter", "open", "Ouvrir"),
        Binding("slash", "filter", "Filtrer"),
        Binding("escape", "clear", "Effacer"),
        Binding("r", "reload", "Rafraîchir"),
        Binding("s", "cycle_sort", "Tri"),
        Binding("p", "command_palette", "Menu"),
        Binding("ctrl+k", "command_palette", "Menu", show=False, priority=True),
        Binding("q", "quit", "Fermer"),
        Binding("ctrl+space,ctrl+@", "quit", "Fermer", show=False),
    ]

    def __init__(self, load, actions, view: ViewState, on_view_change=None, load_light=None, refresh_seconds: float = 30):
        """load_light: cheaper load for timer refreshes (no running markers — the previous ones are kept)."""
        super().__init__()
        self.load, self.acts, self.view = load, actions, view
        self.load_light, self.refresh_seconds = load_light, refresh_seconds
        self._refresh_timer = None
        self.on_view_change = on_view_change or (lambda v: None)
        self.sessions: list[Session] = []
        self._error: str | None = None
        self._loaded = False
        self._loading = False
        self._message: tuple[str, str] = ("", "")   # (text, style)
        self._pending_trash: tuple[str, float] | None = None
        self._text = ""
        self._collapsed: set[str] = set()
        self._open_ids: set[str] = set()
        self.prompt_lines: list[str] = []
        self._busy = False
        self._arm_msg = ""

    # ── layout ──
    def compose(self) -> ComposeResult:
        # widgets are kept by reference: when the palette is up, app.query_one() would search its screen
        self._top, self._filter = Static(id="top"), Input(placeholder="filtrer…", id="filter")
        yield self._top
        yield self._filter
        with Vertical():
            tree: Tree = SessionTree("Sessions", id="tree")
            self._tree = tree
            tree.show_root = False
            tree.guide_depth = 2
            tree.auto_expand = True
            yield tree
            self._empty = Static(id="empty")
            yield self._empty
        self._status = Static(id="status")
        yield self._status
        yield Static(self._keys_hint(), id="keys")

    @staticmethod
    def _keys_hint() -> Text:
        t = Text(no_wrap=True, overflow="ellipsis")
        for i, (k, label) in enumerate((("⏎", "ouvrir"), ("/", "filtre"), ("p", "menu"), ("q", "✕"))):
            if i:
                t.append("  ")
            t.append(k, style="bold")
            t.append(f" {label}")
        return t

    def on_mount(self) -> None:
        self._filter.display = False
        self._empty.display = False
        self._tree.focus()
        if getattr(self.acts, "this", "?") == "":
            self._message = ("machine inconnue — ouverture désactivée (vérifie ~/.claude/session-migrate.yml)", "bold red")
        self._render_status()
        self.refresh_sessions()
        self._refresh_timer = self.set_interval(self.refresh_seconds, self.timer_refresh)

    def on_resize(self) -> None:
        if self._loaded:
            self._rebuild()

    # ── loading ──
    def timer_refresh(self) -> None:
        """Periodic refresh: light load; skipped while another load runs (never cancel a full one)."""
        if not self._loading:
            self.refresh_sessions(light=True)

    def refresh_sessions(self, light: bool = False) -> None:
        """Reload rows in a thread; the tree is rebuilt on the UI thread when they land."""
        keep_running = light and self.load_light is not None
        load = self.load_light if keep_running else self.load
        self._loading = True
        if self.is_mounted:
            self._render_status()
        def job():
            try:
                sessions, err = load(self.view)
                sessions = list(sessions or [])
            except Exception as e:  # load must never take the panel down
                sessions, err = [], f"Chargement impossible : {e}"
            open_ids, prompts = self._side_info()
            if not get_current_worker().is_cancelled:
                self._from_thread(self._apply, sessions, err, open_ids, prompts, keep_running)
        self.run_worker(job, thread=True, group="load", exclusive=True, exit_on_error=False)

    def _side_info(self) -> tuple[set[str], list[str]]:
        """Open-tab ids and prompt lines, read off the UI thread with the rows."""
        try:
            open_ids = set(getattr(self.acts, "open_ids", lambda: set())() or ())
        except Exception:
            open_ids = set()
        try:
            prompts = list(self.acts.prompts() or [])
        except Exception:
            prompts = []
        return open_ids, prompts

    def _apply(self, sessions: list[Session], err: str | None, open_ids=frozenset(), prompts=(), keep_running=False) -> None:
        if keep_running:
            was = {s.id for s in self.sessions if s.running}
            for s in sessions:
                s.running = s.id in was
        self.sessions, self._error, self._loaded, self._loading = sessions, err, True, False
        self._open_ids, self.prompt_lines = set(open_ids), list(prompts)
        self._rebuild()

    def _from_thread(self, fn, *args) -> None:
        try:
            self.call_from_thread(fn, *args)
        except RuntimeError:
            pass  # app is shutting down

    def _visible(self) -> list[Session]:
        q = self._text.lower().strip()
        if not q:
            return self.sessions
        return [s for s in self.sessions
                if q in (s.title or "").lower() or q in (s.proj or "").lower() or q in (s.subject or "").lower()]

    def _rebuild(self) -> None:
        tree = self._tree
        keep = self.selected_session()
        keep_id = keep.id if keep else None
        keep_subject = None
        if keep is None and tree.cursor_node is not None and isinstance(tree.cursor_node.data, str):
            keep_subject = tree.cursor_node.data
        width = max(20, tree.size.width or self.size.width) - LEAF_INDENT - SCROLLBAR
        tree.clear()
        target = None
        visible = self._visible()
        for subject, items in group_by_subject(visible):
            node = tree.root.add(subject_label(subject, items), data=subject, expand=subject not in self._collapsed)
            if subject == keep_subject:
                target = node
            for s in items:
                leaf = node.add_leaf(leaf_label(s, width, s.id in self._open_ids), data=s)
                if s.id == keep_id:
                    target = leaf
        if target is not None:
            if isinstance(target.data, Session) and target.parent is not None:
                target.parent.expand()
            _ = tree._tree_lines  # force line layout so the node has a line number
            tree.move_cursor(target)
        empty = self._empty
        if not visible and not self._error:
            empty.update(Text(f"Aucune session ne correspond à « {self._text} »." if self.sessions
                              else "Aucune session ici.\n\nr pour rafraîchir · p pour changer de filtre"))
        empty.display = not visible and not self._error
        tree.display = bool(visible) or bool(self._error)
        self._render_status()

    # ── status line ──
    def _summary(self) -> Text:
        t = Text(no_wrap=True, overflow="ellipsis")
        t.append("Sessions", style="bold")
        if not self._loaded:
            t.append("  chargement…", style="dim")
            return t
        n, shown = len(self.sessions), len(self._visible())
        t.append(f"  {shown}/{n}" if shown != n else f"  {n}", style="dim")
        t.append(f" · {SORT_FR.get(self.view.sort, self.view.sort)}", style="dim")
        if self.view.filter:
            t.append(f" · {FILTER_FR.get(self.view.filter, self.view.filter)}", style="cyan")
        if self.view.scope == "subject" and self.view.subject:
            t.append(f" · {self.view.subject}", style="cyan")
        if self._loading:
            t.append(" ↻", style="dim")
        return t

    def _render_status(self) -> None:
        self._top.update(self._summary())
        line = Text(overflow="fold")
        if self._error:
            line.append("⚠ " + self._error, style="bold red")
        elif self._message[0]:
            line.append(*self._message)
        status = self._status
        status.update(line)
        status.display = bool(line.plain)

    def notify_status(self, text: str, style: str | None = None) -> None:
        if style is None:
            style = "bold red" if text.startswith(("Échec", "Erreur")) else "green"
        self._message = (text, style)
        self._render_status()

    # ── public helpers (tests + palette) ──
    def tree_labels(self) -> list[str]:
        out: list[str] = []
        for node in self._tree.root.children:
            out.append(node.label.plain)
            out.extend(c.label.plain for c in node.children)
        return out

    def status_text(self) -> str:
        parts = [self._summary().plain]
        empty = self._empty
        if empty.display:
            parts.append(str(empty.render()))
        if self._error:
            parts.append(self._error)
        elif self._message[0]:
            parts.append(self._message[0])
        return "\n".join(parts)

    async def select_session(self, sid: str) -> bool:
        tree = self._tree
        for node in tree.root.children:
            for leaf in node.children:
                if isinstance(leaf.data, Session) and leaf.data.id == sid:
                    node.expand()
                    _ = tree._tree_lines
                    tree.move_cursor(leaf)
                    tree.focus()
                    return True
        return False

    def selected_session(self) -> Session | None:
        node = self._tree.cursor_node
        return node.data if node is not None and isinstance(node.data, Session) else None

    async def palette_titles(self) -> list[str]:
        titles: list[str] = []
        for cls in (SessionCommands, GlobalCommands, PromptCommands):
            async for hit in cls(self.screen).discover():
                titles.append(hit.text or str(hit.display))
        return titles

    def trash_armed_for(self, s: Session) -> bool:
        p = self._pending_trash
        return bool(p and p[0] == s.id and _now() - p[1] <= ARM_SECONDS)

    # ── actions (slow ones run in thread workers) ──
    def _bg(self, pending: str, fn, *args) -> bool:
        """Run one action at a time; a second request while one runs is refused."""
        if self._busy:
            self.notify_status("Une action est déjà en cours — patiente un instant.", "yellow")
            return False
        self._busy = True
        self.notify_status(pending, "dim")

        def job():
            try:
                msg = fn(*args)
            except Exception as e:  # actions promise not to raise; never trust it
                msg = f"Échec : {e}"
            self._from_thread(self._after_action, str(msg or "ok"))
        self.run_worker(job, thread=True, group="action", exit_on_error=False)
        return True

    def _after_action(self, msg: str) -> None:
        self._busy = False
        self.notify_status(msg)
        self.refresh_sessions()

    def do_open(self, s: Session) -> None:
        self._bg(f"Ouverture de {s.title}…", self.acts.open, s)

    def do_priority(self, s: Session, level: str) -> None:
        self._bg(f"Priorité {level} · {s.title}…", self.acts.set_priority, s, level)

    def request_trash(self, s: Session) -> None:
        if self.trash_armed_for(s):
            if self._bg(f"Corbeille · {s.title}…", self.acts.trash, s):
                self._pending_trash = None
        else:
            self._pending_trash = (s.id, _now())
            self._arm_msg = f"Corbeille de « {s.title} » : encore une fois pour confirmer (10 s)"
            self.notify_status(self._arm_msg, "bold yellow")
            self.set_timer(ARM_SECONDS + 0.1, self.expire_trash)

    def expire_trash(self) -> None:
        """Drop an expired arming and its yellow prompt."""
        p = self._pending_trash
        if p and _now() - p[1] <= ARM_SECONDS:
            return
        self._pending_trash = None
        if self._arm_msg and self._message[0] == self._arm_msg:
            self._message = ("", "")
            self._render_status()
        self._arm_msg = ""

    def do_sync(self) -> None:
        self._bg("Synchronisation de l'index…", self.acts.sync)

    def do_replicate(self) -> None:
        self._bg("Réplication…", self.acts.replicate)

    def do_prompt(self, text: str) -> None:
        self._bg(f"Envoi : {text}…", self.acts.send_prompt, text)

    def _view_changed(self, message: str) -> None:
        try:
            self.on_view_change(self.view)
        except Exception as e:
            message = f"Échec de l'enregistrement de la vue : {e}"
        self.notify_status(message, None if message.startswith("Échec") else "cyan")
        self.refresh_sessions()

    def do_sort(self, key: str) -> None:
        self.view.sort = key
        self._view_changed(f"Tri : {SORT_FR.get(key, key)}")

    def do_filter(self, key: str) -> None:
        self.view.set_filter(key)
        self._view_changed(f"Filtre : {FILTER_FR.get(self.view.filter, self.view.filter)}")

    def do_scope(self) -> None:
        if not self.view.subject and (s := self.selected_session()) and s.subject:
            self.view.subject = s.subject
        scope = self.view.toggle_scope()
        self._view_changed(f"Portée : {self.view.subject}" if scope == "subject" else "Portée : toutes")

    # ── keys & events ──
    def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
        if isinstance(event.node.data, Session):
            self.do_open(event.node.data)

    def on_tree_node_collapsed(self, event: Tree.NodeCollapsed) -> None:
        if isinstance(event.node.data, str):
            self._collapsed.add(event.node.data)

    def on_tree_node_expanded(self, event: Tree.NodeExpanded) -> None:
        if isinstance(event.node.data, str):
            self._collapsed.discard(event.node.data)

    def on_input_changed(self, event: Input.Changed) -> None:
        self._text = event.value
        self._rebuild()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._tree.focus()

    def action_open(self) -> None:
        if (s := self.selected_session()) is not None:
            self.do_open(s)

    def action_filter(self) -> None:
        box = self._filter
        box.display = True
        box.focus()

    def action_clear(self) -> None:
        box = self._filter
        if box.value or box.display:
            box.value = ""
            box.display = False
            self._text = ""
            self._rebuild()
        self._pending_trash = None
        self._message = ("", "")
        self._render_status()
        self._tree.focus()

    def action_reload(self) -> None:
        self.refresh_sessions()

    def action_cycle_sort(self) -> None:
        self.view.cycle_sort()
        self._view_changed(f"Tri : {SORT_FR.get(self.view.sort, self.view.sort)}")
