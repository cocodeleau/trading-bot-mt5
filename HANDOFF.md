# HANDOFF — GridExpHedge MT5 EA

Document de passation pour reprise sur une autre machine / nouvelle session Claude.
Dernière mise à jour : 2026-10-05.

---

## 1. Objectif du projet

Construire un Expert Advisor MetaTrader 5 (`GridExpHedge.mq5`) qui trade **XAUUSD en M5** selon une stratégie de **grid martingale bidirectionnel** (buy et sell indépendants coexistant), inspirée au départ d'une pub Instagram montrant un "bot IA" sur MT5 mobile.

L'EA tourne en **live sur un compte Fusion Markets** (compte `493661`, serveur `FusionMarkets-Live`, mode **Hedge**), avec un VPS MetaQuotes New York activé pour un fonctionnement 24/7 indépendant du Mac local.

**Avertissement important** : la stratégie est un grid martingale exponentiel, structurellement à haut risque. Le compte a déjà été cramé une fois le 19 août 2026 (voir section Problèmes connus). Les 3 fixes de sécurité ont été codés le 2026-10-05 (v1.10) mais **ne sont pas encore testés en démo** — ne pas reconnecter en live avant.

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
| SL natif par position | **2000 points** (`InpSLPoints`, × `_Point` → 20$ de mouvement sur XAUUSD 2 décimales), 0 = désactivé | Ajouté v1.10. Le handoff précédent proposait 50-100 points, mais 100 points = 1$ sur l'or, bien moins que l'espacement grid (ATR×1.5) : chaque position serait stoppée avant l'ouverture du niveau suivant. Warning dans le journal si SL ≤ espacement |
| Kill switch equity | **-20% du solde initial** (v1.10, était -50%) | -50% s'est révélé bien trop tolérant le 19 août |
| Référence solde initial | Persistée dans la variable globale terminal `GridExpHedge_<login>_initialBalance` | v1.10 : ne bouge plus à chaque redéploiement. `InpResetBaseline = true` pour la réinitialiser (ex : après dépôt), puis remettre à `false` |
| Anti-spam retry | Flag `g_buyBlocked`/`g_sellBlocked` : un ordre échoué (ex: marge insuffisante) stoppe les tentatives sur ce panier jusqu'à sa fermeture | Évite boucle de centaines d'ordres/sec (bug observé le 13 août) |

### Décisions environnement

- **MT5 Desktop pour Mac** installé via le site metatrader5.com — version Wine officielle MetaQuotes (prefix : `~/Library/Application Support/net.metaquotes.wine.metatrader5`). ⚠️ Ne pas confondre avec l'app "MetaTrader 5" du Mac App Store (iPad-sur-Mac, pas d'EA possible, pas de MetaEditor dedans).
- **VPS MetaQuotes NY** activé pour tourner 24/7 (15$/mois, auto-renewal). Évite les coupures observées quand le Mac se verrouille (bug Wine qui tue le rendu MT5 en session verrouillée, cause de la perte du TP du 13 août).
- **Compilation CLI** : `MetaEditor64.exe /compile:...` lancé via `wine` dans le prefix Wine. Produit `GridExpHedge.ex5` directement dans `MQL5/Experts/`.
- **Mot de passe investisseur** (read-only) : évoqué pour un visu téléphone sans risque de manip, non confirmé configuré avec succès (user a eu souci "Invalid account", conversation s'est détournée avant résolution).
- **Remote git** : `https://github.com/cocodeleau/trading-bot-mt5` (privé), branche `main`.
- **Poste Windows** également utilisé (session du 2026-10-05) : MT5 installé dans `C:\Program Files\MetaTrader 5\`, compilation CLI possible (voir section 5).

---

## 3. Ce qui est fait (vérifié en session)

- ✅ EA `GridExpHedge.mq5` écrit (~360 lignes MQL5), compilé sans erreur avec le MetaEditor Wine → `GridExpHedge.ex5` présent dans le dossier Experts du terminal.
- ✅ Attaché sur graphique XAUUSD M5 du compte Fusion Markets live (vérifié via screenshots : "GridExpHedge initialized" dans Experts, position buy 0.01 @4383.38 ouverte en live).
- ✅ Migration VPS Fusion→MetaQuotes NY réussie (`running`), EA tourne côté VPS indépendamment du Mac.
- ✅ Compte demo testé 24-48h avant live (balance 100 → 232 EUR, ~19 trades, martingale a bien fermé niveaux 1+2 ensemble aux horodatages identiques).
- ✅ Bug anti-spam retry corrigé (constaté 13 Aug : 100aines d'ordres `buy 0.04 not enough money` en quelques secondes → flag `blocked` ajouté).
- ✅ Multi-timeframe confluence implémenté avec paramètres BB séparés par TF (`InpBBPeriod_M15/H1`, `InpBBDeviation_M15/H1`).
- ✅ Commit git du fichier source : `c60d3d4 Add GridExpHedge MT5 EA: multi-timeframe grid strategy`.
- ✅ **v1.10 (2026-10-05)** : 3 fixes de sécurité codés (SL natif par position, kill switch 20%, solde initial persisté). Compile sans erreur ni warning avec MetaEditor Windows. **Pas encore testé en démo ni backtesté, pas encore déployé sur le terminal / VPS.**

## 4. Ce qui est seulement supposé (NON vérifié)

- ❓ **Comportement du TP panier combiné sous drawdown réel** : jamais déclenché pendant un vrai mouvement adverse en live. Vu uniquement en démo sur paniers 2 niveaux max dans un marché calme.
- ❓ **Comportement du multiplicateur confluence** (×2, ×4) en pratique : logique codée et compilée mais non observée en live/démo car ajoutée juste avant que le compte crame.
- ❓ **Hypothèse de la cause réelle du crash du 19 août** : le kill switch a tiré (log confirmé) mais le solde final a été 0.27$ au lieu des ~53$ attendus. Hypothèses non vérifiées :
  - Slippage énorme à la fermeture pendant mouvement violent
  - Stop-out broker Fusion Markets déclenché AVANT le check equity de l'EA
  - `g_initialBalance` corrompu par les ~10 redéploiements de l'EA pendant la session (chaque `OnInit()` écrase la référence avec la balance du moment)
- ❓ **Comportement du TP natif en points** quand MT5 est en mode "Points" vs "Pips" sur XAUUSD (`_Point` ou `SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)` chez Fusion : non vérifié que 15 "points" dans mon code = 15 cents sur l'or et pas autre chose). Code actuel fait `fillPrice + InpTPPoints` brut, à vérifier que ça donne bien ~1.50$ de profit visé sur 0.01 lot.
- ❓ **Mot de passe investisseur / connexion téléphone** : jamais confirmé fonctionnel, user bloqué sur "Invalid account".
- ❓ **Valeur du SL (2000 points = 20$)** : choisie pour rester au-dessus de l'espacement grid, pas calibrée sur données réelles. À ajuster en démo selon le warning "SL distance <= grid spacing" et le nombre de niveaux atteints.
- ❓ **Variables globales et VPS** : les variables globales du terminal local ne sont a priori pas migrées vers le VPS. Au premier lancement sur le VPS, la référence sera la balance du moment. Non vérifié.

---

## 5. Fichiers concernés

| Chemin | Contenu | État |
|---|---|---|
| `MQL5/Experts/GridExpHedge.mq5` | Source EA complet (seul fichier du projet) | v1.10 commitée (3 fixes de sécurité) |
| `MQL5/Experts/GridExpHedge.ex5` | Binaire compilé (côté dossier terminal MT5 Wine, PAS dans le repo git) | Dernière compile 2026-08-19, non versionné car binaire |
| `HANDOFF.md` | Ce document | Mis à jour 2026-10-05 |

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
- Pour compiler sous **Windows** (PowerShell, depuis la racine du repo) — `/inc` pointe vers le dossier MQL5 du terminal (qui contient `Include\Trade\Trade.mqh`). Un code de sortie 1 = succès (nombre de fichiers compilés), lire le log :
  ```powershell
  $inc = (Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal\*\MQL5" -Directory | Select-Object -First 1).FullName
  & "C:\Program Files\MetaTrader 5\MetaEditor64.exe" /compile:"MQL5\Experts\GridExpHedge.mq5" /inc:"$inc" /log:build.log
  Get-Content build.log -Encoding Unicode
  ```
  Si le chemin du repo est très long (> ~150 caractères), copier le `.mq5` dans un dossier court avant de compiler.

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

**Causes structurelles identifiées** (corrigées dans le code v1.10, non validées en démo) :
1. ✅ (v1.10) **Aucun SL par position** — toute la protection reposait uniquement sur le kill switch equity vérifié à chaque tick, trop lent face à un move violent. → `InpSLPoints` ajouté.
2. ✅ (v1.10) **Kill switch à -50%** — beaucoup trop tolérant. L'écart observé entre seuil visé (~53$) et résultat (0.27$) prouve que même quand il tire, les positions sont déjà bien plus loin que prévu. → passé à 20%.
3. ✅ (v1.10) **`g_initialBalance` non persistant** — se réinitialisait à chaque `OnInit()`, donc à chaque redéploiement de l'EA (fait ~10 fois en session). → persisté en variable globale terminal. Effet de bord voulu : après un kill switch, relancer l'EA ne le réactive pas tant que l'equity reste sous le seuil.

### 🟡 MOYEN — Bugs d'environnement

- **MT5 Wine se fige quand Mac se verrouille** — Wine coupe le rendu GPU en session sécurisée, process reste parfois zombie. Fix : `pkill -9 -f "MetaTrader 5"` puis relancer depuis `/Applications/MetaTrader 5.app`. **VPS activé pour contourner ça**, mais à surveiller.
- **Compte démo MetaQuotes `110924184`** : mot de passe master perdu, impossible à changer (change-password demande current, pas de reset possible sur demo anonyme). Compte toujours fonctionnel côté desktop (session cachée). Pas gênant pour le projet, à ignorer.
- **Mot de passe investisseur** : jamais réussi à être configuré correctement, user bloqué sur "Invalid account" côté téléphone. Non résolu.

---

## 7. Questions ouvertes

1. **Vérifier la vraie cause du crash du 19 août** avant d'appliquer les fixes à l'aveugle : stop-out broker ? slippage ? bug de calcul du check equity ? Télécharger les logs Fusion Markets détaillés si possible, ou backtest du scénario sur données tick de ce jour-là.
2. **TP par position : `InpTPPoints = 15` est ajouté brut au prix** (`fillPrice + InpTPPoints`, sans `* _Point`). Sur XAUUSD ça donne un TP à **15$ de mouvement**, pas 15 cents. Non corrigé volontairement (changerait toute la stratégie). Le journal affiche désormais `sl=` et `tp=` à chaque ouverture : vérifier en démo, puis décider si on passe en vrais points (`* _Point`) avec une nouvelle valeur. Attention : le SL, lui, est déjà en vrais points.
3. **Faut-il abandonner le martingale** et pivoter sur une stratégie non-doublement (ex: grid à lot fixe + plus de niveaux, ou pure trend-following) ? Décision stratégique en suspens. User était jusqu'ici attaché au martingale "comme dans la pub d'origine".

---

## 8. Prochaine étape exacte

Les **3 fixes de sécurité** sont codés et compilés (v1.10, 2026-10-05) :
- **Fix 1** — SL natif par position : `InpSLPoints` (défaut 2000 points, voir section 2 pour le choix de la valeur), passé à `trade.Buy/Sell` dans `OpenGridOrder()`.
- **Fix 2** — kill switch `InpEquityStopPercent` : 50 → **20**.
- **Fix 3** — `g_initialBalance` persisté via `GlobalVariableGet/Set()`, clé `GridExpHedge_<login>_initialBalance`, reset via l'input `InpResetBaseline` (ou `GlobalVariableDel()` / F3 dans le terminal).

### Reste à faire, dans l'ordre
1. Copier le `.mq5` dans le dossier Experts du terminal et recompiler (commandes section 5, Mac ou Windows).
2. **Tester en démo d'abord** au moins quelques jours :
   - vérifier dans le journal les valeurs `sl=` / `tp=` de chaque ordre (et trancher la question 2 sur le TP) ;
   - vérifier l'absence du warning "SL distance <= grid spacing", ajuster `InpSLPoints` sinon ;
   - voir des SL tirer sur moves adverses sans tuer la stratégie, et le kill switch à 20% se déclencher proprement ;
   - redémarrer l'EA et vérifier "Initial balance baseline restored" dans le journal.
3. **Seulement ensuite** reconnecter sur un compte live (Fusion déjà configuré, VPS déjà actif). Penser à la baseline côté VPS (section 4).
4. Ouvrir une nouvelle discussion sur la viabilité stratégique du martingale à ce niveau de capital (question 3 des questions ouvertes).

---

**Fin du handoff.** Bon courage pour la reprise.
