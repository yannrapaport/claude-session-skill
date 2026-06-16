# Claude Session Skill

A git-synced lightweight index that auto-discovers every Claude Code session across machines, with on-demand JSONL transport over ssh, cross-machine resume, and two-clock garbage collection. Transport (`session:*`) is separated from semantic checkpoints (`ai-brain:*`): only the index lives in git — transcripts move over ssh on demand.

---

## Components

### 1. Auto-populated index (`session-index-scan`, scheduled)

Walks `~/.claude/projects/*/*.jsonl` on this machine, derives `cwd`, `last_activity` (file mtime), and `subject` from each file, and upserts this machine's subtree of `registry.json` in the hub repo. Prunes entries whose JSONL no longer exists. Commits and pushes when done.

Scheduled: every 15 minutes (launchd on Mac, cron on Nexus).

### 2. Global view (`sessions` CLI / `/session:list`)

```
sessions [--project <slug>] [--machine <m>] [--active]
```

Syncs the hub, then renders a cross-machine table: date, machine, status (`act`/`arch`), project path, subject. An asterisk marks sessions that live on this machine.

### 3. Cross-machine resume (`/session:resume <id-prefix>`)

Resolves the prefix to a full session id, looks up the owning machine in the registry, and resumes:

- **Local session** — `claude --resume <id>` directly.
- **Remote session** — rsync the JSONL over ssh from `peer_<machine>`, then `claude --resume <id>`.

If the remote machine is unreachable, fails with a clear message (the machine must be up and on the network).

### 4. GC process (`session-gc-process`, hourly)

Reaps detached idle `claude` CLI processes (no controlling tty) whose elapsed time exceeds `gc_process_idle_hours`. RAM hygiene only — no registry changes. Dry-run unless `--kill` is passed. The scheduled launchd/cron jobs run with `--kill`.

### 5. GC sessions (`session-gc-sessions`, daily at 04:00)

Two-phase:

- **Archive** — sessions on this machine with `status: active` and `last_activity` older than `gc_archive_days` days are checkpointed (via `GC_CHECKPOINT_CMD`) then flipped to `status: archived` in the registry.
- **Purge** (optional) — archived JSONL files older than `gc_purge_days` days are deleted from `~/.claude/projects/`. Disabled by default (`gc_purge_days: 0`).

See the [GC checkpoint limitation](#gc-checkpoint-dependency) below before enabling purge.

---

## Registry schema v2

```json
{
  "version": 2,
  "machines": {
    "mac": {
      "<session-id>": {
        "project_relative": "projects/tpg/rakam",
        "cwd": "/Users/yann/projects/tpg/rakam",
        "last_activity": "2026-06-10T14:23:00Z",
        "subject": "Refactor pricing model",
        "status": "active"
      }
    },
    "nexus": {
      "<session-id>": { "..." : "..." }
    }
  }
}
```

**Machine partitioning** — each machine writes only its own subtree (`machines.<machine>`). Every push is therefore a clean non-conflicting merge (no cross-machine clobber). The JSONL transcripts are **not** in git; only the lightweight index is. Transcripts move over ssh on demand via `rsync` during `/session:resume`.

---

## Config (`~/.claude/session-migrate.yml`)

Copy `config.yml.template` to `~/.claude/session-migrate.yml` and fill in your values. Never commit this file.

| Key | Description | Default |
|-----|-------------|---------|
| `hub` | URL of the private git hub repo for the session index | required |
| `machine` | Name of this machine (e.g. `mac`, `nexus`) | required |
| `home` | Absolute home path on this machine | required |
| `peer_<machine>` | ssh target for each **other** machine (anything `ssh` accepts: alias, `user@host`, Tailscale hostname) | one per peer |
| `gc_process_idle_hours` | Idle threshold (hours) before a detached `claude` process is killed | `6` |
| `gc_archive_days` | Sessions inactive longer than this (days) are archived | `10` |
| `gc_purge_days` | Delete archived JSONL after this many days (`0` = never) | `0` |

---

## Usage

```bash
# List all sessions across machines
sessions

# Filter
sessions --project rakam
sessions --machine mac
sessions --active

# Same from inside Claude Code
/session:list

# Resume any session (local or remote)
/session:resume <id-prefix>
```

**Deprecated:** `session:save` and `session:migrate` are no longer needed. Use `/ai-brain:save` for semantic checkpoints; migration from the old flat registry to v2 is handled automatically by `session-registry-migrate`.

---

## Scheduling

Scheduled jobs live in `units/`:

| File | Platform | Jobs |
|------|----------|------|
| `units/com.yann.session-index.plist` | Mac (launchd) | `session-index-scan` every 15 min |
| `units/com.yann.session-gc-process.plist` | Mac (launchd) | `session-gc-process --kill` every hour |
| `units/com.yann.session-gc-sessions.plist` | Mac (launchd) | `session-gc-sessions` daily at 04:00 |
| `units/crontab.nexus` | Linux (cron) | equivalent cron lines |

`install.sh` handles activation automatically:

- **Darwin** — copies plists to `~/Library/LaunchAgents/` and loads them via `launchctl`.
- **Linux** — prints the `crontab -` install command; you run it.

**Note:** once installed, these are always-on background jobs. The hourly GC process job runs with `--kill` (live mode, not dry-run).

---

## GC checkpoint dependency

The daily `session-gc-sessions` job is configured with `GC_CHECKPOINT_CMD=true` — a shell no-op. This is intentional: a headless, session-id-targeted `ai-brain:save` entrypoint does not yet exist, so there is no way for the GC to create a real semantic checkpoint before archiving.

**Consequence:** GC ships archive-only, with `gc_purge_days: 0` (the default). Archived sessions:

- Keep their JSONL on disk.
- Can still be resumed with `/session:resume`.
- Are fully reversible — flip `status` back to `active` in `registry.json` if needed.

The session id being archived is passed to the hook as the `$GC_SID` environment variable, ready for a future headless entrypoint. **Do not set `gc_purge_days > 0` until a real checkpoint command is wired in.**
