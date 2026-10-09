"""Sessions panel: a Textual app living in a pinned Zellij floating pane."""
from __future__ import annotations
import time
from functools import partial
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Provider, Hit, Hits, DiscoveryHit
from textual.containers import Vertical
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


def leaf_label(s: Session, width: int = 36) -> Text:
    """badge · age · owner · title · markers, title shortened so markers always fit."""
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
    t.append(" ")
    t.append(title, style="bold" if s.running else "")
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


class _ListProvider(Provider):
    """Provider over a list of (title, callback, help) — same discover/search for all three sources."""

    def _items(self):
        return []

    async def discover(self) -> Hits:
        for title, cb, help_ in self._items():
            yield DiscoveryHit(title, cb, text=title, help=help_)

    async def search(self, query: str) -> Hits:
        m = self.matcher(query)
        for title, cb, help_ in self._items():
            if (score := m.match(title)) > 0:
                yield Hit(score, m.highlight(title), cb, text=title, help=help_)


class SessionCommands(_ListProvider):
    """Per session: open, migrate here, priority, trash."""

    def _items(self):
        app = self.app
        this = getattr(app.acts, "this", None)
        for s in app.sessions:
            yield f"Ouvrir {s.title}", partial(app.do_open, s), "Bascule vers son onglet ou le crée"
            if this and s.owner and s.owner != this:
                yield f"Migrer ici · {s.title}", partial(app.do_open, s), f"Rapatrie depuis {s.owner} puis ouvre"
            for lvl in ("must", "should", "may", "aucune"):
                yield f"Priorité {lvl} · {s.title}", partial(app.do_priority, s, "none" if lvl == "aucune" else lvl), None
            if app.trash_armed_for(s):
                yield f"Confirmer la corbeille de {s.title}", partial(app.request_trash, s), "Définitif côté index"
            else:
                yield f"Corbeille · {s.title}", partial(app.request_trash, s), "Deux fois pour confirmer"


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
        try:
            lines = app.acts.prompts()
        except Exception:
            lines = []
        for line in lines:
            yield f"Prompt : {line}", partial(app.do_prompt, line), "Envoyé au volet de session de l'onglet"


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
    BINDINGS = [
        Binding("enter", "open", "Ouvrir"),
        Binding("slash", "filter", "Filtrer"),
        Binding("escape", "clear", "Effacer"),
        Binding("r", "reload", "Rafraîchir"),
        Binding("s", "cycle_sort", "Tri"),
        Binding("q", "quit", "Fermer"),
        Binding("ctrl+space,ctrl+@", "quit", "Fermer", show=False),
    ]

    def __init__(self, load, actions, view: ViewState, on_view_change=None):
        super().__init__()
        self.load, self.acts, self.view = load, actions, view
        self.on_view_change = on_view_change or (lambda v: None)
        self.sessions: list[Session] = []
        self._error: str | None = None
        self._loaded = False
        self._loading = False
        self._message: tuple[str, str] = ("", "")   # (text, style)
        self._pending_trash: tuple[str, float] | None = None
        self._text = ""
        self._collapsed: set[str] = set()

    # ── layout ──
    def compose(self) -> ComposeResult:
        yield Static(id="top")
        yield Input(placeholder="filtrer…", id="filter")
        with Vertical():
            tree: Tree = Tree("Sessions", id="tree")
            tree.show_root = False
            tree.guide_depth = 2
            tree.auto_expand = True
            yield tree
            yield Static(id="empty")
        yield Static(id="status")
        yield Static(self._keys_hint(), id="keys")

    @staticmethod
    def _keys_hint() -> Text:
        t = Text(no_wrap=True, overflow="ellipsis")
        for i, (k, label) in enumerate((("⏎", "ouvrir"), ("/", "filtre"), ("^P", "menu"), ("q", "✕"))):
            if i:
                t.append("  ")
            t.append(k, style="bold")
            t.append(f" {label}")
        return t

    def on_mount(self) -> None:
        self.query_one("#filter").display = False
        self.query_one("#empty").display = False
        self.query_one("#tree").focus()
        self._render_status()
        self.refresh_sessions()
        self.set_interval(30, self.refresh_sessions)

    def on_resize(self) -> None:
        if self._loaded:
            self._rebuild()

    # ── loading ──
    def refresh_sessions(self) -> None:
        """Reload rows in a thread; the tree is rebuilt on the UI thread when they land."""
        self._loading = True
        if self.is_mounted:
            self._render_status()
        def job():
            try:
                sessions, err = self.load(self.view)
            except Exception as e:  # load must never take the panel down
                sessions, err = [], f"Chargement impossible : {e}"
            if not get_current_worker().is_cancelled:
                self._from_thread(self._apply, list(sessions or []), err)
        self.run_worker(job, thread=True, group="load", exclusive=True, exit_on_error=False)

    def _apply(self, sessions: list[Session], err: str | None) -> None:
        self.sessions, self._error, self._loaded, self._loading = sessions, err, True, False
        self._pending_trash = None   # arming never survives a refresh
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
        tree: Tree = self.query_one("#tree", Tree)
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
                leaf = node.add_leaf(leaf_label(s, width), data=s)
                if s.id == keep_id:
                    target = leaf
        if target is not None:
            if isinstance(target.data, Session) and target.parent is not None:
                target.parent.expand()
            _ = tree._tree_lines  # force line layout so the node has a line number
            tree.move_cursor(target)
        empty = self.query_one("#empty", Static)
        if not visible and not self._error:
            empty.update(f"Aucune session ne correspond à « {self._text} »." if self.sessions
                         else "Aucune session ici.\n\nr pour rafraîchir · ^P pour changer de filtre")
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
        self.query_one("#top", Static).update(self._summary())
        line = Text(overflow="fold")
        if self._error:
            line.append("⚠ " + self._error, style="bold red")
        elif self._message[0]:
            line.append(*self._message)
        status = self.query_one("#status", Static)
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
        for node in self.query_one("#tree", Tree).root.children:
            out.append(node.label.plain)
            out.extend(c.label.plain for c in node.children)
        return out

    def status_text(self) -> str:
        parts = [self._summary().plain]
        empty = self.query_one("#empty", Static)
        if empty.display:
            parts.append(str(empty.render()))
        if self._error:
            parts.append(self._error)
        elif self._message[0]:
            parts.append(self._message[0])
        return "\n".join(parts)

    async def select_session(self, sid: str) -> bool:
        tree = self.query_one("#tree", Tree)
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
        node = self.query_one("#tree", Tree).cursor_node
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
    def _bg(self, pending: str, fn, *args) -> None:
        self.notify_status(pending, "dim")

        def job():
            try:
                msg = fn(*args)
            except Exception as e:  # actions promise not to raise; never trust it
                msg = f"Échec : {e}"
            self._from_thread(self._after_action, str(msg or "ok"))
        self.run_worker(job, thread=True, group="action", exit_on_error=False)

    def _after_action(self, msg: str) -> None:
        self.notify_status(msg)
        self.refresh_sessions()

    def do_open(self, s: Session) -> None:
        self._bg(f"Ouverture de {s.title}…", self.acts.open, s)

    def do_priority(self, s: Session, level: str) -> None:
        self._bg(f"Priorité {level} · {s.title}…", self.acts.set_priority, s, level)

    def request_trash(self, s: Session) -> None:
        if self.trash_armed_for(s):
            self._pending_trash = None
            self._bg(f"Corbeille · {s.title}…", self.acts.trash, s)
        else:
            self._pending_trash = (s.id, _now())
            self.notify_status(f"Corbeille de « {s.title} » : encore une fois pour confirmer (10 s)", "bold yellow")

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
        self.query_one("#tree").focus()

    def action_open(self) -> None:
        if (s := self.selected_session()) is not None:
            self.do_open(s)

    def action_filter(self) -> None:
        box = self.query_one("#filter", Input)
        box.display = True
        box.focus()

    def action_clear(self) -> None:
        box = self.query_one("#filter", Input)
        if box.value or box.display:
            box.value = ""
            box.display = False
            self._text = ""
            self._rebuild()
        self._pending_trash = None
        self._message = ("", "")
        self._render_status()
        self.query_one("#tree").focus()

    def action_reload(self) -> None:
        self.refresh_sessions()

    def action_cycle_sort(self) -> None:
        self.view.cycle_sort()
        self._view_changed(f"Tri : {SORT_FR.get(self.view.sort, self.view.sort)}")
