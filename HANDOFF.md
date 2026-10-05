# HANDOFF — GridExpHedge MT5 EA

Document de passation pour reprise sur une autre machine / nouvelle session Claude.
Dernière mise à jour : 2026-10-05.

---

## 1. Objectif du projet

Construire un Expert Advisor MetaTrader 5 (`GridExpHedge.mq5`) qui trade **XAUUSD en M5** selon une stratégie de **grid martingale bidirectionnel** (buy et sell indépendants coexistant), inspirée au départ d'une pub Instagram montrant un "bot IA" sur MT5 mobile.

L'EA tourne en **live sur un compte Fusion Markets** (compte `493661`, serveur `FusionMarkets-Live`, mode **Hedge**), avec un VPS MetaQuotes New York activé pour un fonctionnement 24/7 indépendant du Mac local.

**Avertissement important** : la stratégie est un grid martingale exponentiel, structurellement à haut risque. Le compte a déjà été cramé une fois le 19 août 2026 (voir section Problèmes connus). Ne pas reconnecter en live sans avoir au minimum appliqué les 3 fixes de sécurité listés en section « Prochaine étape ».

---

## 2. Décisions prises et pourquoi

### Stratégie — spécification verrouillée

| Paramètre | Valeur | Raison |
|---|---|---|
| Symbole / timeframe | XAUUSD, M5 | Correspond à la pub d'origine (XAUUSDm), bonne volatilité pour grid |
| Signal entrée | **Bollinger Bands (20, 2)** sur **M5 + M15 + H1** avec multiplicateur de confluence | Mean-reversion naturel au grid. Confluence 3 timeframes = filtrage des faux signaux, et le niveau de confluence atteint détermine la taille |
| Direction | Hedge (buy et sell en parallèle, magic numbers séparés) | Fidèle à la pub d'origine |
| Espacement entre niveaux | ATR(14) × 1.5 (dynamique) | Adaptatif à la volatilité, plus robuste que fixe |
| Multiplicateur lot (dans un panier) | 2x par niveau | Martingale classique |
| Plafond niveaux grid (filet) | 15 | Marge réelle plafonnera bien avant sur petit compte, filet théorique |
| Lot de base (tier 1) | 0.02 (après passage de 0.01→0.02 en session) | Augmente avec le capital par palier de +100$ (ex : balance 200-299$ = 0.04) |
| Multiplicateur confluence lot | M5 seul = ×1 / M5+M15 = ×2 / M5+M15+H1 = ×4 | Plus de signaux (M5 suffit à déclencher) mais taille adaptée à la force du signal |
| TP natif par position | **15 points** (ordre TP envoyé au broker à l'ouverture) | Fermeture automatique côté broker, pas dépendant du check EA à chaque tick |
| TP panier (rescue) | +10% du solde initial, net de commission | Mécanisme martingale conservé : si le combiné d'un panier (buy ou sell, filtre magic) repasse en profit suffisant, ferme tout ce qui reste de ce côté |
| Commission | 4.50$ flat round-turn par position (Fusion Markets) | Décomptée du calcul `BasketProfit()` car MT5 ne l'inclut pas dans `POSITION_PROFIT` flottant |
| Kill switch equity | **-50% du solde initial** (actuellement) | Garde-fou global, mais s'est révélé insuffisant en pratique (voir Problèmes connus) |
| Anti-spam retry | Flag `g_buyBlocked`/`g_sellBlocked` : un ordre échoué (ex: marge insuffisante) stoppe les tentatives sur ce panier jusqu'à sa fermeture | Évite boucle de centaines d'ordres/sec (bug observé le 13 août) |

### Décisions environnement

- **MT5 Desktop pour Mac** installé via le site metatrader5.com — version Wine officielle MetaQuotes (prefix : `~/Library/Application Support/net.metaquotes.wine.metatrader5`). ⚠️ Ne pas confondre avec l'app "MetaTrader 5" du Mac App Store (iPad-sur-Mac, pas d'EA possible, pas de MetaEditor dedans).
- **VPS MetaQuotes NY** activé pour tourner 24/7 (15$/mois, auto-renewal). Évite les coupures observées quand le Mac se verrouille (bug Wine qui tue le rendu MT5 en session verrouillée, cause de la perte du TP du 13 août).
- **Compilation CLI** : `MetaEditor64.exe /compile:...` lancé via `wine` dans le prefix Wine. Produit `GridExpHedge.ex5` directement dans `MQL5/Experts/`.
- **Mot de passe investisseur** (read-only) : évoqué pour un visu téléphone sans risque de manip, non confirmé configuré avec succès (user a eu souci "Invalid account", conversation s'est détournée avant résolution).
- **Pas de remote git** configuré — tout est local, commits uniquement sur `main`.

---

## 3. Ce qui est fait (vérifié en session)

- ✅ EA `GridExpHedge.mq5` écrit (~360 lignes MQL5), compilé sans erreur avec le MetaEditor Wine → `GridExpHedge.ex5` présent dans le dossier Experts du terminal.
- ✅ Attaché sur graphique XAUUSD M5 du compte Fusion Markets live (vérifié via screenshots : "GridExpHedge initialized" dans Experts, position buy 0.01 @4383.38 ouverte en live).
- ✅ Migration VPS Fusion→MetaQuotes NY réussie (`running`), EA tourne côté VPS indépendamment du Mac.
- ✅ Compte demo testé 24-48h avant live (balance 100 → 232 EUR, ~19 trades, martingale a bien fermé niveaux 1+2 ensemble aux horodatages identiques).
- ✅ Bug anti-spam retry corrigé (constaté 13 Aug : 100aines d'ordres `buy 0.04 not enough money` en quelques secondes → flag `blocked` ajouté).
- ✅ Multi-timeframe confluence implémenté avec paramètres BB séparés par TF (`InpBBPeriod_M15/H1`, `InpBBDeviation_M15/H1`).
- ✅ Commit git du fichier source : `c60d3d4 Add GridExpHedge MT5 EA: multi-timeframe grid strategy`.

## 4. Ce qui est seulement supposé (NON vérifié)

- ❓ **Comportement du TP panier combiné sous drawdown réel** : jamais déclenché pendant un vrai mouvement adverse en live. Vu uniquement en démo sur paniers 2 niveaux max dans un marché calme.
- ❓ **Comportement du multiplicateur confluence** (×2, ×4) en pratique : logique codée et compilée mais non observée en live/démo car ajoutée juste avant que le compte crame.
- ❓ **Hypothèse de la cause réelle du crash du 19 août** : le kill switch a tiré (log confirmé) mais le solde final a été 0.27$ au lieu des ~53$ attendus. Hypothèses non vérifiées :
  - Slippage énorme à la fermeture pendant mouvement violent
  - Stop-out broker Fusion Markets déclenché AVANT le check equity de l'EA
  - `g_initialBalance` corrompu par les ~10 redéploiements de l'EA pendant la session (chaque `OnInit()` écrase la référence avec la balance du moment)
- ❓ **Comportement du TP natif en points** quand MT5 est en mode "Points" vs "Pips" sur XAUUSD (`_Point` ou `SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)` chez Fusion : non vérifié que 15 "points" dans mon code = 15 cents sur l'or et pas autre chose). Code actuel fait `fillPrice + InpTPPoints` brut, à vérifier que ça donne bien ~1.50$ de profit visé sur 0.01 lot.
- ❓ **Mot de passe investisseur / connexion téléphone** : jamais confirmé fonctionnel, user bloqué sur "Invalid account".

---

## 5. Fichiers concernés

| Chemin | Contenu | État |
|---|---|---|
| `MQL5/Experts/GridExpHedge.mq5` | Source EA complet (seul fichier du projet) | Commité `c60d3d4` |
| `MQL5/Experts/GridExpHedge.ex5` | Binaire compilé (côté dossier terminal MT5 Wine, PAS dans le repo git) | Dernière compile 2026-08-19, non versionné car binaire |
| `HANDOFF.md` | Ce document | Nouveau |

**Chemins externes importants pour la reprise :**
- Terminal MT5 (Wine) : `~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/`
- Dossier Experts du terminal : `~/Library/Application\ Support/net.metaquotes.wine.metatrader5/drive_c/Program\ Files/MetaTrader\ 5/MQL5/Experts/`
- Wine binary : `/Applications/MetaTrader\ 5.app/Contents/SharedSupport/wine/bin/wine`
- Pour recompiler depuis le repo :
  ```bash
  cp MQL5/Experts/GridExpHedge.mq5 "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
  export WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
  cd "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5"
  "/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine" MetaEditor64.exe /compile:"MQL5\\Experts\\GridExpHedge.mq5" &
  sleep 8
  ```

---

## 6. Problèmes connus

### 🔴 CRITIQUE — Compte live cramé le 2026-08-19

**Historique Experts** :
```
2026.08.19 13:16 — GridExpHedge initialized. Initial balance snapshot: 107.2
2026.08.19 18:33 — KILL SWITCH TRIGGERED — equity stop hit. All positions closed. EA disabled.
```
**Résultat** : balance passée de ~107$ à **0.27$** (perte ~106$ sur une position initiale de 113$ au départ live).

**Enchaînement observé sur chart** : mouvement de ~180 points en quelques heures sur XAUUSD, suivi d'un retournement brutal. Les 2 paniers (buy et sell) ont pris simultanément, sell -106.91 et buy -72.89 sur les 2 dernières positions avant kill switch.

**Causes structurelles identifiées** (non toutes corrigées) :
1. ❌ **Aucun SL par position** — toute la protection reposait uniquement sur le kill switch equity vérifié à chaque tick, trop lent face à un move violent.
2. ❌ **Kill switch à -50%** — beaucoup trop tolérant. L'écart observé entre seuil visé (~53$) et résultat (0.27$) prouve que même quand il tire, les positions sont déjà bien plus loin que prévu.
3. ❌ **`g_initialBalance` non persistant** — se réinitialise à chaque `OnInit()`, donc à chaque redéploiement de l'EA (fait ~10 fois en session). Référence du seuil kill switch potentiellement corrompue avant le crash.

### 🟡 MOYEN — Bugs d'environnement

- **MT5 Wine se fige quand Mac se verrouille** — Wine coupe le rendu GPU en session sécurisée, process reste parfois zombie. Fix : `pkill -9 -f "MetaTrader 5"` puis relancer depuis `/Applications/MetaTrader 5.app`. **VPS activé pour contourner ça**, mais à surveiller.
- **Compte démo MetaQuotes `110924184`** : mot de passe master perdu, impossible à changer (change-password demande current, pas de reset possible sur demo anonyme). Compte toujours fonctionnel côté desktop (session cachée). Pas gênant pour le projet, à ignorer.
- **Mot de passe investisseur** : jamais réussi à être configuré correctement, user bloqué sur "Invalid account" côté téléphone. Non résolu.

---

## 7. Questions ouvertes

1. **Vérifier la vraie cause du crash du 19 août** avant d'appliquer les fixes à l'aveugle : stop-out broker ? slippage ? bug de calcul du check equity ? Télécharger les logs Fusion Markets détaillés si possible, ou backtest du scénario sur données tick de ce jour-là.
2. **Est-ce que `InpTPPoints = 15` donne vraiment ~15 cents sur XAUUSD chez Fusion Markets ?** Vérifier avec `_Point` du symbole une fois en live/démo (devrait être 0.01 pour XAUUSD → 15 × 0.01 = 0.15$ de mouvement = très peu, à reconfirmer). Peut-être qu'il faut multiplier par `_Point` et `_Digits`.
3. **Faut-il abandonner le martingale** et pivoter sur une stratégie non-doublement (ex: grid à lot fixe + plus de niveaux, ou pure trend-following) ? Décision stratégique en suspens. User était jusqu'ici attaché au martingale "comme dans la pub d'origine".

---

## 8. Prochaine étape exacte

**Avant toute reconnexion de l'EA sur un compte live**, implémenter les **3 fixes de sécurité** proposés et acceptés en principe mais non codés avant la fin de session :

### Fix 1 — SL natif par position
Dans `OpenGridOrder()` (actuellement passe `sl=0` aux appels `trade.Buy/Sell`), calculer un SL en points et le passer au broker en même temps que le TP. Nouvel input `InpSLPoints` (proposer défaut 50-100 points pour qu'il déclenche sur move violent mais pas sur bruit normal).

### Fix 2 — Baisser le kill switch equity
Changer la valeur par défaut `InpEquityStopPercent` de `50.0` à **15.0 ou 20.0**. L'expérience du 19 août prouve que 50% laisse largement le temps au désastre.

### Fix 3 — Persister `g_initialBalance`
Au lieu de `g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE)` dans `OnInit()`, utiliser `GlobalVariableGet/Set()` MQL5 (variable globale terminal, persiste entre les redéploiements de l'EA). Clé proposée : `"GridExpHedge_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_initialBalance"`. Si pas encore set, créer avec balance actuelle ; sinon, lire la valeur persistée. Permet aussi un reset manuel via `GlobalVariableDel()`.

### Après les 3 fixes
1. Recompiler via Wine (voir commandes section 5).
2. **Tester en démo d'abord** au moins quelques jours — on doit voir les SL tirer sur de petits moves adverses sans tuer la stratégie globale, et confirmer que le kill switch à 20% se déclenche propre.
3. **Seulement ensuite** reconnecter sur un compte live (Fusion déjà configuré, VPS déjà actif).
4. Ouvrir une nouvelle discussion sur la viabilité stratégique du martingale à ce niveau de capital (question 3 des questions ouvertes).

### Pour le git
- Repo local actuellement sans remote. Avant d'utiliser `git push`, ajouter un remote :
  ```bash
  git remote add origin <URL>
  git branch -M main
  git push -u origin main
  ```

---

**Fin du handoff.** Bon courage pour la reprise.
