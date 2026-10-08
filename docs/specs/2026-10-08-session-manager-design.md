# Gestionnaire de sessions cross-machine — Design

**Date** : 2026-10-08
**Repo** : `claude-session-skill` (centre de gravité) + touches dans `cc` (`~/projects/admin/cc`) et les dotfiles
**Statut** : design validé en conversation, spec à relire avant plan d'implémentation
**Remplace** : la décision 4 de `2026-06-16-sessions-consolidation-design.md` (« aucun mirror proactif »)

## Problème

L'outil actuel indexe les sessions Mac + Nexus et les reprend à la demande, mais :

1. **Pas de migration** : `/session:resume` copie le JSONL, il ne déplace pas la session. Deux copies vivantes, aucune ne fait foi.
2. **Rien quand l'autre machine dort** : le transport est un rsync à la demande. Mac fermé → la session est inaccessible depuis Nexus. C'est le scénario dominant : bosser sur le Mac, rabattre l'écran, continuer sur Nexus.
3. **Pas d'organisation** : ni priorité, ni tri, ni filtre interactif ; une liste à numéros qu'on relit puis qu'on retape.
4. **Reprise hors contexte** : il faut quitter Claude pour reprendre. Corrigé partiellement par la PR #2 (`--resume --bg`), qui a elle-même un défaut (voir *Primitive de reprise*).

## Besoin

- Gérer les sessions Mac et Nexus dans un même outil, identique sur les deux machines.
- **Migrer** une session d'une machine à l'autre : une seule copie vivante ensuite.
- Migrer **même si la machine d'origine est injoignable** — en pratique, Mac fermé, depuis Nexus.
- Lister par projet, trier par dernière activité ou par projet, filtrer.
- Priorité posée à la main : `must` / `should` / `may` / aucune (convention des todos).
- Interface terminal : la liste reste dans un volet, la session choisie s'affiche dans le volet principal (tmux).

## Décisions

| # | Décision | Pourquoi |
|---|----------|----------|
| 1 | **Réplication proactive Mac → Nexus** (hook `Stop` + rattrapage 15 min). Pas de réplication Nexus → Mac. | Mac fermé = seul cas d'indisponibilité réel ; Nexus est toujours joignable. |
| 2 | **Session = trois éléments** : `projects/<cwd>/<id>.jsonl`, `projects/<cwd>/<id>/`, `file-history/<id>/`. | Le JSONL seul perd sous-agents, tool-results et historique de fichiers. |
| 3 | **Aucune réécriture de chemin dans le JSONL.** | Vérifié le 2026-10-08 : session Mac copiée telle quelle sur Nexus, reprise en `--bg` sous le même id, contexte intact, cwd Nexus correct. |
| 4 | **Correspondance des répertoires par `CC_DIRS`.** | `~/vaults/ai-brain` (Mac) ≠ `~/ai-brain` (Nexus) : remplacer le home ne suffit pas. `CC_DIRS` est déjà commun aux deux machines. |
| 5 | **Jamais de `rm` automatique.** La copie source part en corbeille si elle est identique à l'empreinte de migration, sinon elle est marquée divergente et laissée intacte. | La réplique peut être en retard ; supprimer la source détruirait la copie la plus complète. |
| 6 | **Décisions (propriétaire, priorité) dans `meta/<id>.json`**, hors des sous-arbres machine de `registry.json`. | Un flip de propriétaire touche deux machines ; un fichier par session évite les conflits git. |
| 7 | **Une migration n'existe qu'une fois poussée.** Push en échec → rollback de l'installation. | Le hub est la seule source de vérité partagée. |
| 8 | **Interface bash + fzf dans tmux**, sur les scripts existants. | Réutilise 75 tests et l'outillage ; fzf + tmux couvrent volet persistant et respawn. |

Écarté : JSONL dans git (churn de ~340 Mo), Syncthing (filtrage headless, fichiers de conflit, démon sur un Nexus saturé), Nexus comme unique maison des sessions avec le Mac en client (Nexus saturé, Mac doit marcher hors ligne).

## Données

### Inventaire — `registry.json` (inchangé)
Ce que chaque machine **observe** sur son disque. Partitionné par machine, écrit uniquement par le scan de cette machine.

### Décisions — `meta/<id>.json` (nouveau, dans le hub)
```json
{
  "owner": "nexus",
  "priority": "must",
  "migrated_at": "2026-10-08T10:02:00Z",
  "migrated_from": "mac",
  "fingerprint": { "size": 663578, "sha256": "…", "last_uuid": "…" }
}
```
- Absent = propriétaire implicite (la machine qui a la session dans son inventaire), pas de priorité.
- `fingerprint` décrit le JSONL **tel qu'installé** à la migration.
- Écrit par l'outil uniquement (migration, changement de priorité), commit + push immédiat.

### Réplique — `nexus:~/.claude/session-replica/mac/<id>/`
```
<id>.jsonl
<id>/              # sous-agents, tool-results (si présent)
file-history/      # si présent
source.json        # { "cwd": "/Users/…", "replicated_at": "…", "size": … }
```
Hors de `~/.claude/projects` : ne pollue ni `/resume` ni l'inventaire Nexus.

### Correspondance des répertoires
`CC_DIRS` sort du `.zshrc` vers un fichier dédié (`~/projects/admin/cc/subjects.zsh`, sourcé par le `.zshrc` et lu par l'outil). Pour un cwd source :
1. Sujet dont la racine (résolue, `:A`) contient le cwd → racine du même sujet sur la cible + même suffixe.
2. Suffixe absent sur la cible (ex. `.claude/worktrees/…`) → racine du sujet.
3. Hors sujet → remplacement du home.
4. Répertoire cible inexistant → migration refusée, message explicite.

## Réplication Mac → Nexus

- **Hook `Stop`** (settings Mac) : `session-replicate <session_id>` en arrière-plan, `timeout 20`, silencieux si Nexus injoignable. Ignore les sessions non interactives (`entrypoint` ≠ `cli`).
- **Rattrapage** : ajouté au job `session-index-scan` (15 min) — réplique toute session interactive modifiée depuis son `replicated_at`.
- **Uniquement les sessions dont le Mac est propriétaire** : une session migrée vers Nexus (`meta.owner` = `nexus`) n'est plus répliquée, même si une copie locale traîne encore avant réconciliation.
- **Atomicité** : rsync sans `--inplace` (fichier temporaire + rename) ; `source.json` écrit en dernier.
- Pas de suppression dans la réplique au fil de l'eau ; elle est purgée quand la session est migrée vers Nexus ou passe en corbeille côté Mac.

## Migration

Une commande, symétrique, lancée **depuis la machine cible** : `session-migrate <id>`.

1. `session-hub-sync`. Vérifier que le propriétaire est l'autre machine.
2. **Source** — test ssh (3 s) :
   - joignable : si la session y tourne (`claude agents --json`), proposer de l'arrêter (`claude stop`), sinon abandon. Copier depuis la source ;
   - injoignable : utiliser la réplique. Afficher son âge et la dernière activité connue de la source (`registry.json`) ; confirmation obligatoire. Pas de réplique → abandon.
3. Calculer le cwd cible (correspondance ci-dessus). Installer les trois éléments dans `projects/<cwd cible encodé>/` et `file-history/`.
4. Écrire `meta/<id>.json` (owner, migrated_at, migrated_from, fingerprint), commit + push. Échec → retirer les fichiers installés, abandon.
5. Reprendre (voir *Primitive de reprise*).
6. Nettoyer la source : immédiatement via ssh si joignable, sinon au prochain scan de la source.

### Nettoyage de la source (`session-reconcile`, appelé par le scan)
Pour chaque session locale dont `meta.owner` ≠ cette machine :
| Cas | Action |
|-----|--------|
| Session en cours d'exécution localement | Rien. |
| JSONL identique à `fingerprint` (taille + sha256) | Corbeille `~/.claude/session-trash/<date>/`, purge à 30 j. |
| JSONL plus long, préfixe identique (sha256 des `size` premiers octets) | **Divergente** : laissée intacte, marquée dans l'inventaire (`diverged: true`). |
| Autre | **Divergente**, idem. |

Résolution d'une divergence depuis l'interface : garder les deux (la copie locale devient une session à part entière, propriétaire local, via un nouvel id `--fork-session`) ou mettre l'une à la corbeille.

À la migration Mac → Nexus, la réplique de cette session est supprimée sur Nexus une fois l'installation poussée.

### Prérequis
`cleanupPeriodDays: 365` dans `~/.claude/settings.json` sur les deux machines — sinon Claude Code purge lui-même les JSONL à 30 j.

## Primitive de reprise

Corrige la PR #2 : `claude --resume <id> --bg` sur une session déjà connue du superviseur en démarre une **copie** (vérifié le 2026-10-08).

| État (`claude agents --json --all`) | Commande |
|-------------------------------------|----------|
| En cours | `claude attach <short>` |
| Connue, arrêtée | `claude attach <short>` (la reprend sans copie, vérifié) |
| Inconnue du superviseur | `cd <cwd> && claude --resume <id> --bg`, puis `claude attach <short>` |
| Sur l'autre machine | migration, puis ligne précédente |

Sur Nexus, `claude` n'est pas dans le PATH d'un ssh non interactif : chemin absolu en config (`claude_bin`).

## Interface

### Disposition tmux
```
┌─ sessions ────────────┬─ volet principal ──────────────────────┐
│ !must 2h mac  rakam   │                                        │
│▶      1j nex  brain   │   claude attach <id>                   │
│ !may  3j mac⇢ lp   ⚠  │                                        │
│ > filtre_             │                                        │
└───────────────────────┴────────────────────────────────────────┘
```
- **Volet liste** (~35 colonnes) : fzf persistant — `Entrée` agit sans quitter.
- **Volet principal** : par défaut `claude agents --cwd <racine du sujet>` ; une sélection le relance (`tmux respawn-pane -k`) sur la session. La précédente reste en arrière-plan (vérifié : tuer le volet `attach` ne stoppe pas la session). Fin ou détachement → retour à la vue agents.
- L'id du volet principal est stocké en option tmux de la fenêtre (`@sessions_main`).

### Lancement
- `cc tmux <sujet>` crée cette disposition dans `cc-<sujet>`.
- `sessions` : dans tmux, découpe la fenêtre courante ; hors tmux, ouvre ou rejoint `cc-sessions`.
- `sessions --plain` : tableau actuel (scripts, `/session:list`).

### Ligne
`priorité · âge · machine propriétaire · sujet · titre · tours · marqueurs`
Titre = `/rename` > ai-title > premier prompt. Marqueurs : `●` en cours, `⇢` réplique en retard sur la source, `⚠` divergente.

### Touches
| Touche | Action |
|--------|--------|
| frappe | filtre flou (titre, sujet, premier prompt) |
| `Entrée` | reprendre / migrer dans le volet principal ; sur `⚠`, menu de résolution |
| `ctrl-a` | sujet courant ↔ toutes les sessions |
| `ctrl-s` | tri : activité → projet + activité → priorité + activité |
| `alt-p` / `alt-m` / `alt-n` | priorisées seulement / Mac / Nexus |
| `alt-1` `alt-2` `alt-3` `alt-0` | priorité must / should / may / aucune |
| `ctrl-x` | corbeille (confirmation) |

### Données au lancement
`session-hub-sync` (~1 s), puis `registry.json` + `meta/` + `claude agents --json --all` local.

### Dépendances
fzf récent sur Nexus (0.44 en paquet Debian, trop ancien pour `reload` fiable) : binaire dans `~/.local/bin`.

## Hors périmètre
- Split de deux sessions côte à côte (`alt-Entrée` → nouveau volet). Étape 2 ; la disposition le permet sans refonte.
- Renommer depuis l'interface (`/rename` existe), tags libres, app web, réplication Nexus → Mac.

## Tests
Harness sans deux machines : deux `HOME` temporaires (`mac`, `nexus`), `ssh` / `rsync` / `claude` remplacés par des fonctions qui opèrent entre ces `HOME` ou impriment leur argv, hub = repo git bare local. Cas :
- correspondance des répertoires (sujet, worktree absent, hors sujet, cible absente) ;
- réplication (hook, rattrapage, session headless ignorée, Nexus injoignable) ;
- migration source joignable / injoignable / sans réplique / session en cours ;
- échec du push → rollback ;
- réconciliation : identique → corbeille, plus longue → divergente, en cours → intacte ;
- primitive de reprise selon l'état superviseur.

## Livraison
1. Primitive de reprise (corrige la PR #2) + `meta/` + priorité.
2. Interface tmux + fzf (liste, tri, filtre, priorité, reprise locale).
3. Réplication Mac → Nexus.
4. Migration + réconciliation + corbeille.
5. Intégration `cc tmux`, `cleanupPeriodDays`, fzf sur Nexus.

Chaque étape est utilisable seule ; la 2 apporte déjà l'essentiel du confort quotidien.
