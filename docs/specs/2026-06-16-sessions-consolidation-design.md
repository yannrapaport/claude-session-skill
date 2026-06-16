# Consolidation du système de sessions — Design

**Date** : 2026-06-16
**Repo** : `claude-session-skill` (centre de gravité) + touches dans `ai-brain-skills`
**Statut** : design validé, prêt pour plan d'implémentation

## Problème

Trois besoins se télescopaient dans deux systèmes qui se recouvrent :

- **`ai-brain:save/restore`** — checkpoint *sémantique* (résumé du travail, todos, next steps), stocké dans le vault Obsidian git-tracké, synchro cross-machine par git.
- **`session:save/list/migrate/resume`** — `save` écrit aussi un résumé (doublon avec ai-brain), `migrate/resume` transportent le *transcript JSONL réel* via un hub git (`claude-sessions`).
- **`claude --resume` natif** — reprend une session locale, par projet (cwd), aucune vue cross-projets ni cross-machine.

Trois axes confondus :
1. Reprendre le **travail** (le sens) → `ai-brain:save` et `session:save` font **doublon**.
2. Reprendre la **conversation** sur une autre machine → `session:migrate/resume` (manuel).
3. Retrouver **quoi** reprendre, vue globale cross-projets après reboot → **servi par personne**.

Besoin cible exprimé : *retrouver automatiquement la liste de toutes mes sessions (Mac + Nexus) et les reprendre indifféremment sur l'une ou l'autre.* Scénario dominant : bosser sur Mac, continuer la même conversation sur Nexus.

## Décisions

| # | Décision |
|---|----------|
| 1 | **Séparer transport et sens.** `session:*` = transcript, index, reprise, GC. `ai-brain:*` = checkpoints sémantiques, journal, todos. |
| 2 | **Déprécier `session:save`.** Tout checkpoint sémantique passe par `ai-brain:save`. Plus de markdown de résumé côté `session`. |
| 3 | **Index global léger synchronisé par git** (option hybride). Le `registry.json` du hub `claude-sessions` (déjà un repo git) porte l'index. JSONL **pas dans git**. |
| 4 | **Transport JSONL par pull-à-la-demande via Tailscale**, bidirectionnel. Aucun mirror proactif. |
| 5 | **GC à deux horloges** : process (RAM, fréquent) ≠ sessions (10j, prudent). |
| 6 | **GC sessions = cron silencieux** avec rapport a posteriori, sûr car checkpoint-avant-archive. |

## Architecture — 5 composants

### 1. Index global auto-peuplé
`registry.json` dans le repo git `claude-sessions`. Une entrée par session :
`{ id, projet_relatif, machine, derniere_activite, sujet, statut: active|archived }`.

- Chaque machine n'écrit **que ses propres entrées** → partition par machine, zéro conflit git.
- Un job local scanne `~/.claude/projects/*/*.jsonl`, met à jour les entrées de la machine, commit + push.
- Léger (quelques Ko) → git le porte sans souci. Synchro continue par nature.
- Le sujet = premier message user "réel" du transcript (filtrer les méta `<...>`, `command-name`).
- **La migration manuelle disparaît** : l'index se peuple seul.

### 2. Commande `sessions` — vue globale
Lit l'index synchronisé, affiche les deux machines unifiées :
`date │ machine │ projet │ sujet │ statut`.
Filtres : `--project <slug>` (cohérent avec le scope-cwd), `--machine`, `--active`.
C'est l'outil lancé avant/après un reboot.

### 3. `session:resume <id>` — reprise indifférente
Depuis n'importe quelle machine :
- JSONL **local** → `claude --resume` direct.
- JSONL **distant** → `rsync` via Tailscale depuis la machine source (les deux sens), installe le transcript à l'emplacement attendu (`~/.claude/projects/<encoded>/`), puis `--resume`.
- Sans argument → liste l'index et demande de choisir.

**Condition résiduelle** : la machine source doit être up et sur le tailnet au moment du resume. Naturel — si elle est éteinte, sa session n'existe nulle part ailleurs.

### 4. GC process — hygiène RAM (fréquent)
launchd (Mac) / cron (Nexus), horaire. Tue les process Claude spare/daemon orphelins inactifs > N heures. **C'est ce qui règle « le Mac rame ».** Sans risque : le JSONL reste sur disque. Cible par session-id / âge, sans toucher aux daemons sains.

### 5. GC sessions — deux paliers (cron quotidien, silencieux)
- **Archive (10j inactif)** : `ai-brain:save` (checkpoint sémantique) → kill des process restants → `statut=archived` dans l'index → rapport. Réversible : `--resume` remarche si on rouvre, JSONL gardé.
- **Purge (90j, désactivé par défaut)** : supprime le JSONL pour l'espace. Réversibilité assurée uniquement par le checkpoint. Activable si le volume devient un sujet (actuellement 604 Mo / 407 fichiers, non urgent).

Le cron silencieux est sûr **parce que** le checkpoint précède toujours l'archive : zéro perte de sens même sans validation manuelle.

## Flux

```
Mac:  scan → maj entrées Mac ──┐        ┌── maj entrées Nexus ← scan  :Nexus
                               ▼        ▼
                   [ registry.json — repo git claude-sessions ]
                               │  (synchro continue, léger)
              ┌────────────────┼────────────────┐
          sessions         resume <id>          GC
          (vue globale)  (rsync Tailscale       (checkpoint → archive
                          si JSONL distant)       → purge optionnelle)
```

## Répartition repos

- **`claude-session-skill`** (`~/.claude/skills/session`) — gros du travail : index auto, `sessions`, `resume` étendu, GC process, GC sessions, jobs launchd/cron. Helpers existants à réutiliser/étendre : `session-cleanup`, `session-registry-get/set`, `session-hub-sync`, `session-hub-push`, `session-detect-id`, `session-encode-path`.
- **`ai-brain-skills`** — marginal : le GC appelle `ai-brain:save` ; documenter la dépréciation de `session:save` au profit d'`ai-brain:save`.
- **Hub `claude-sessions`** — porte `registry.json` enrichi (champ `statut`, `sujet`). Ne porte plus de JSONL.

## Dépréciations

- `session:save` → remplacé par `ai-brain:save`.
- `session:migrate` (manuel) → inutile (index auto + pull à la demande). Peut survivre comme "push forcé" optionnel, non requis dans le flux normal.

## Points à trancher à l'implémentation (non bloquants)

- Lire `session-cleanup` existant et décider étendre vs réécrire.
- Seuils exacts : âge "process orphelin" (ex. 6h ?), fréquence des crons.
- launchd (Mac) vs cron/systemd (Nexus) — fichiers d'unité concrets.
- Mécanique précise du "kill par session-id" sans toucher aux daemons sains (mapping process → session-id via les sockets `cc-daemon-*`).
- Résolution de l'IP/host Tailscale de chaque machine (config `session-migrate.yml` ou `tailscale status`).
- Format de l'encodage de chemin projet pour poser le JSONL au bon endroit (`session-encode-path` existe déjà).

## Risques

- **Machine source éteinte au resume** : accepté, comportement naturel.
- **Kill trop agressif du GC process** : risque de tuer une session active. Mitigation : ne cibler que les spare/daemon orphelins, pas les sessions avec `--agent claude` rattachées à un tty vivant.
- **Divergence d'index si deux scans concurrents** : évitée par la partition par machine (chacun n'écrit que ses entrées) + `pull --rebase --autostash` déjà en place dans `session-hub-sync`.
