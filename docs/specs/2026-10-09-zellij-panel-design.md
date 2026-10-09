# Volet de sessions Zellij + Textual — Design

**Date** : 2026-10-09
**Repo** : `claude-session-skill` (+ `cc` pour le lancement)
**Statut** : design validé en conversation
**Remplace** : l'interface tmux + fzf de `2026-10-08-session-manager-design.md` (section « Interface »). Tout le reste de ce design (index, `meta/`, migration, réplique, réconciliation, corbeille, verrou) est inchangé et réutilisé tel quel.

## Problème

L'interface tmux + fzf livrée le 2026-10-08 n'est « pas gérable » : trop austère, pas assez graphique. Termius, le terminal de Yann, est fermé (ni plugin, ni API, ni volet tiers) : l'intégration doit donc vivre **dans** le terminal, et marcher pareil sur le Mac et sur Nexus via ssh.

## Décisions

| # | Décision | Pourquoi |
|---|----------|----------|
| 1 | **Zellij** remplace tmux comme multiplexeur des sessions Claude. | Volets flottants épinglés, actions scriptables (`zellij action …`), onglets nommés. Fonctionne dans Termius, local ou ssh. |
| 2 | **Application Textual** (Python) pour le volet, pas un plugin Zellij en Rust. | Interface riche (arbre repliable, couleurs, souris, palette floue native), même langage que le repo, rien à compiler, réutilise les scripts existants. |
| 3 | **Un onglet Zellij par session Claude**, nommé d'après son titre. | Navigation native, plusieurs sessions ouvertes en parallèle. |
| 4 | **Un seul volet à la fois** : ouvrir le volet ferme celui d'un autre onglet ; ouvrir une session déplace le volet dans son onglet. | Un seul processus Textual — Nexus a peu de RAM. |
| 5 | Repli = **fermer / rouvrir** le volet (`Ctrl+Espace`), pas masquer. | Vérifié le 2026-10-09 (Zellij 0.45.1) : un volet flottant épinglé reste visible quand on masque la couche flottante. |
| 6 | Le volet se **cale lui-même** à gauche au démarrage (`change-floating-pane-coordinates` sur `terminal_$ZELLIJ_PANE_ID`, x 0, y 0, largeur 36, hauteur 100 %). | Vérifié : un `Run` de keybind ignore x/y/width/height. |
| 7 | Lancement par `uv run --script` avec dépendances inline (PEP 723). | Pas d'environnement virtuel à gérer ; même commande sur les deux machines. |

## Volet

- `Ctrl+Espace` (keybind Zellij global) : ouvre le volet épinglé, calé à gauche (36 col.). Re-presser ferme. S'il existe dans un autre onglet, il y est fermé.
- **Contenu** : arbre de sessions groupées par sujet `cc` (nœuds repliables), chaque feuille : badge priorité coloré · âge · machine propriétaire (m/n) · titre · marqueurs (● en cours, ⇢ réplique en retard, ⚠ divergente). Session dont l'onglet est ouvert : surlignée.
- Clavier + souris : flèches, `Entrée` ouvrir, `/` filtrer, `Échap` effacer le filtre, `Ctrl+P` palette, `q` ou `Ctrl+Espace` fermer.
- Rafraîchissement : toutes les 30 s et après chaque action.

## Onglets

`Entrée` sur une session :
- un onglet nommé `<titre court>` existe et porte cette session (registre local `tabs.json` id → nom d'onglet) → `go-to-tab-name` ;
- sinon `new-tab --name <titre court>` avec, selon l'état :
  - session locale → `session-open <id>`,
  - autre propriétaire → `session-migrate <id> && session-open <id>` (les confirmations s'affichent dans l'onglet ; refus → message + `⏎ pour fermer`),
  - divergente sur cette machine → `session-diverge <id>` ;
- puis le volet se déplace dans le nouvel onglet.

Nom court : titre tronqué à 24 caractères, sans `"`; collision → suffixe ` ·<4 premiers car. de l'id>`.

## Palette (`Ctrl+P`)

Recherche floue (palette native Textual), trois sources :
1. **Sessions** : « Ouvrir … », « Migrer ici … », « Priorité must/should/may/aucune … », « Corbeille … » pour chaque session.
2. **Commandes globales** : Tri activité / projet / priorité · Filtre Mac / Nexus / priorisées / aucun · Sujet courant ↔ toutes · Synchroniser l'index · Répliquer maintenant.
3. **Prompts favoris** : lignes de `~/.config/session-panel/prompts.txt` (une par ligne, `#` = commentaire ; défaut créé à l'installation avec `/ai-brain:wrap-up` et `/ai-brain:save`). Envoyé dans le volet terminal **focalisé de l'onglet courant hors volet de sessions** via `zellij action write-chars` puis `write 13`.

La corbeille demande confirmation dans la palette (deuxième sélection « Confirmer la corbeille de … »), pas dans un terminal.

## Lancement

- `cc <sujet>` : ouvre ou rejoint la session Zellij `cc-<sujet>` (`zellij attach -c cc-<sujet>`), cwd = racine du sujet. `cc agents [<sujet>]` garde la vue agents. `cc tmux` est retiré.
- `sessions` en terminal : idem `cc` avec le sujet déduit du cwd (ou `cc-sessions`). `sessions --plain` inchangé.
- Config Zellij versionnée dans le repo (`zellij/config.kdl`) : keybind `Ctrl Space` → `Run "session-panel"` flottant épinglé ; `show_startup_tips false`. Installée par `install.sh` dans `~/.config/zellij/config.kdl` **seulement si absent** (sinon message : ajouter le keybind à la main).

## Retiré

`session-layout`, `session-tui`, `session-tui-act`, `session-home` et leurs tests ; le mode `cc tmux`.

## Installation

Mac : `brew install zellij`, `uv` déjà présent. Nexus : binaire Zellij et `uv` dans `~/.local/bin` (pas de paquet système). Textual téléchargé au premier `uv run` puis en cache.

## Tests

- Python pur, sans terminal : `panel/model.py` (lignes, groupes, tri/filtres), `panel/zj.py` (appels Zellij via un exécutable `zellij` stub qui journalise et sert du JSON), `panel/actions.py` (décisions d'ouverture, nommage d'onglet, déplacement du volet, envoi de prompt).
- Textual : `App.run_test()` + pilote (touches, palette) sur un modèle et des actions factices.
- Lancés par `tests/run_tests.sh` (un `tests/test_panel.sh` qui exécute `uv run --with textual --with pytest pytest tests/panel`).

## Hors périmètre

Nouvelle session depuis la palette ; vue côte à côte ; application web ; plugin Zellij natif.
