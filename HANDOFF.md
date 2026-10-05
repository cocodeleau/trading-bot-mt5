# HANDOFF — GridExpHedge MT5 EA

Document de passation pour reprise sur une autre machine / nouvelle session Claude.
Dernière mise à jour : 2026-10-05.

---

## 1. Objectif du projet

Construire un Expert Advisor MetaTrader 5 (`GridExpHedge.mq5`) qui trade **XAUUSD en M5** selon une stratégie de **grid martingale bidirectionnel** (buy et sell indépendants coexistant), inspirée au départ d'une pub Instagram montrant un "bot IA" sur MT5 mobile.

L'EA tourne en **live sur un compte Fusion Markets** (compte `493661`, serveur `FusionMarkets-Live`, mode **Hedge**), avec un VPS MetaQuotes New York activé pour un fonctionnement 24/7 indépendant du Mac local.

**Avertissement important** : la stratégie est un grid martingale exponentiel, structurellement à haut risque. Le compte a déjà été cramé une fois le 19 août 2026 (voir section Problèmes connus).

**⛔ Statut au 2026-10-05 : stratégie martingale ABANDONNÉE.** 6 backtests (section 3bis) montrent qu'aucune version (v1.00 → v1.20) ne survit plus de ~8 jours sur 100-110$ — avec ou sans protections. Ne pas remettre GridExpHedge en live. Le VPS fait encore tourner la v1.00 sur le compte Fusion (≈0.27$) : à désactiver. Prochaine étape : nouvelle stratégie **non martingale** (section 8).

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
| Kill switch equity | **-20% du PIC d'equity** (v1.20 ; v1.10 = -20% du solde initial ; v1.00 = -50% du solde initial) | Les lots grossissent avec la balance (paliers), un seuil fixé sur le dépôt laissait repartir 86% des gains (backtest v1.00). Pic persisté dans `GridExpHedge_<login>_peakEquity` |
| Plafond d'exposition | **0.05 lot max ouvert (buy+sell) par 100$ d'equity** (`InpMaxLotsPer100`, v1.20, 0 = off) | Empêche l'empilement martingale (0.08+0.16+0.32…) qui a cramé le compte |
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
- ✅ **v1.10 (2026-10-05)** : 3 fixes de sécurité codés (SL natif par position, kill switch 20%, solde initial persisté). Compile sans erreur ni warning avec MetaEditor Windows.
- ✅ **v1.20 (2026-10-05)** : kill switch sur pic d'equity + plafond d'exposition. Compile sans erreur. Jamais déployée sur le VPS.
- ✅ **6 backtests Strategy Tester** v1.00 / v1.10 / v1.20 (section 3bis) → conclusion : stratégie non viable.

## 3bis. Résultats des backtests (2026-10-05)

Conditions communes : MT5 Strategy Tester, XAUUSD M5, données Fusion Markets Live, mode « Every tick based on real ticks », levier 1:500, arrêt du test dès que le compte est « cramé » (garde-fou backtest-only `TesterStop()` dans des copies de test, pas dans le repo). Fusion n'a de **vrais ticks qu'à partir de 2024** (avant : ticks générés depuis M1).

| Test | Survie | Balance finale | Cause |
|---|---|---|---|
| v1.00, 110$, depuis 2021-10-01 | 3 jours | 53.53$ | Pic à 396.75$ puis lots tier-scalés (0.08+0.16+0.32) → −341$ sur un panier, kill switch −50% du dépôt |
| v1.10, 110$, 2021 | 1 heure | 87.70$ | 0.12 lot ouvert, −20% du dépôt sur un move de ~2$ |
| v1.20, 110$, 2021 | 1 jour | 120.62$ | −20% depuis le pic (~150$) |
| v1.20, 1000$ (paliers neutralisés), 2021 | 5 jours | 1089$ | Panier 4 niveaux (0.36 lot), move ~15$ → −20% depuis pic ~1360$ |
| v1.20, 100$, kill switch 90%, 2021 | 8 jours puis EA figé 5 ans | 38.96$ | 2 paniers SL à −120$ chacun ; ensuite equity < 40$ → plafond < lot min, plus aucun ordre |
| v1.20, 100$, kill switch 90%, **depuis 2024-01-02 (vrais ticks)** | **7 jours** | **11.47$** | 8 rescue TP à +10$ vs 4 SL à −40$ |

**Diagnostic** : profil gain/perte asymétrique — rescue TP ≈ +10$ contre SL ≈ −40 à −120$ → il faudrait gagner 80-92% des paniers pour être à l'équilibre ; observé 67-91%. Sans protection le martingale crame, avec protection il s'arrête ou saigne. Le TP natif (15$ de mouvement) ne s'est jamais déclenché.

**Bugs identifiés dans GridExpHedge (non corrigés, stratégie abandonnée)** :
1. `ComputeBaseLot()` double le lot tous les 100$ (`2^(palier-1)`) → à 1000$ l'EA voudrait 10.24 lots.
2. EA figé silencieusement quand equity < ~40$ (plafond < lot min 0.02).
3. Log « Exposure cap » : 222 955 lignes sur 5 ans (throttle 1/min insuffisant).
4. Rescue TP figé à 10% du dépôt initial, indépendant du volume ouvert.
5. TP natif `InpTPPoints` ajouté brut au prix (15$ de mouvement, pas 15 points).

## 3ter. Stratégies non martingale — backtests (2026-10-05)

Deux nouveaux EA partageant `MQL5/Include/TradingBot/RiskManager.mqh` (lot calculé pour risquer `InpRiskPercent` % de l'equity, lot min accepté tant que son risque ≤ `InpMaxRiskPercent`, sinon trade ignoré ; kill switch sur pic d'equity persisté qui appelle `TesterStop()` en backtest ; 1 position max ; décisions à la clôture de bougie) :
- **`TrendPullback.mq5`** (option A) : tendance = clôture H4 vs EMA200 H4 ; entrée quand la bougie H1 clôturée touche l'EMA50 H1 et clôture du côté tendance ; SL = 1.5×ATR(14) H1 ; TP = 2×SL.
- **`MeanRevertBB.mq5`** (option C) : clôture H1 hors Bollinger(20,2) → position inverse ; TP = bande médiane ; SL = 1.5×ATR ; ignoré si TP < 0.5×SL.

Conditions : réglages par défaut, risque 1% (max 3%), levier 1:500, ticks réels, kill switch 90% (= test jusqu'au « vrai » crash).

| EA | Symbole / dépôt | Période | Profit net | PF | DD max | Trades | % gagnants |
|---|---|---|---|---|---|---|---|
| TrendPullback | XAUUSD 1000$ | 2024→2026 | +112$ | 1.03 | 44% | 411 | 35% |
| TrendPullback | XAUUSD 1000$ | 2021→2026 | +87$ | 1.02 | 55% | 795 | 35% |
| TrendPullback | EURUSD 100$ | 2024→2026 | −30$ | 0.91 | 58% | 346 | 34% |
| TrendPullback | EURUSD 100$ | 2021→2026 | −68$ | 0.79 | 71% | 311 | 31% |
| MeanRevertBB | XAUUSD 1000$ | 2024→2026 | −537$ | 0.86 | 63% | 588 | 37% |
| MeanRevertBB | XAUUSD 1000$ | 2021→2026 | −531$ | 0.94 | 62% | 1421 | 38% |
| MeanRevertBB | EURUSD 100$ | 2024→2026 | −67$ | 0.91 | 79% | 701 | 38% |
| MeanRevertBB | EURUSD 100$ | 2021→2026 | −67$ | 0.94 | 73% | 1007 | 39% |

**Lecture** : aucune ne crame le compte (progrès vs martingale), mais aucune n'a d'avantage net. MeanRevertBB : écartée. TrendPullback/XAUUSD : quasi à l'équilibre (35% gagnants pour 33% nécessaires à RR 2), seul candidat à optimiser.
**Limite capital** : sur ces dépôts le lot min (0.01) risque déjà 1.5-3% par trade → risque effectif 2-3% (d'où les DD 44-79%) et des centaines de jours sans trade quand l'equity baisse. Risquer réellement 1% sur l'or avec SL 1.5×ATR H1 demande ~2000-3000$.

### Walk-forward TrendPullback / XAUUSD (2026-10-05)

Optimisation MT5 complète (1575 passes) : `InpTrendEMA` 100-300 pas 50, `InpPullbackEMA` 20-100 pas 10, `InpSLATRMult` 1.0-3.0 pas 0.5, `InpRR` 1.0-4.0 pas 0.5. Optimisation sur **2021-10-01 → 2023-12-31**, forward (non retouché) sur **2024-01-01 → 2026-10-01**. Dépôt 10 000$ (pour que le risque 1% soit réel), modèle « 1 minute OHLC », critère « Complex Criterion ». Config : `wf_tp_xau.ini` dans le dossier de données du terminal ; résultats `reports\WF_TP_XAU.xml` et `.forward.xml`.

| | Période d'optimisation | Forward |
|---|---|---|
| Top 15 (classés sur l'optimisation) — PF | 1.22 à 1.57 | **0.90 à 1.17** |
| Top 15 — DD max | 5.5 à 11.5% | 9.9 à 17.3% |
| 256 meilleures passes — PF médian | — | **1.02** (p25 0.97, p75 1.09) |
| 256 meilleures passes — profit médian (sur 10 000$, 2.75 ans) | — | +279$ (~1%/an) |
| Passes rentables | 1236 / 1575 | 166 / 256 |

Le classement sur la période d'optimisation ne prédit pas le forward (top 10 : profit forward médian 173$ ; rangs 50-256 : 310$). **Conclusion : pas d'avantage validé.** L'avantage apparent 2021-2023 est du surajustement ; en forward la stratégie est à l'équilibre, avant slippage réel. Choisir a posteriori le meilleur jeu en forward (150/70/3.0/2.5, PF 1.17) serait du cherry-picking.

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
| `MQL5/Experts/GridExpHedge.mq5` | EA grid martingale | v1.20 commitée — stratégie abandonnée, gardée pour référence |
| `MQL5/Experts/TrendPullback.mq5` | Option A, suivi de tendance | v1.00, backtestée + walk-forward (section 3ter) : avantage non validé |
| `MQL5/Experts/MeanRevertBB.mq5` | Option C, retour à la moyenne | v1.00, backtestée, écartée |
| `MQL5/Include/TradingBot/RiskManager.mqh` | Gestion du risque commune | À copier dans `MQL5\Include\TradingBot\` du terminal avant compilation |
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
- Pour **backtester sous Windows en CLI** : MT5 doit être **fermé** (une seule instance par dossier de données) et connecté au compte Fusion (historique). Créer un `.ini` dans le dossier de données du terminal (`%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\`) :
  ```ini
  [Tester]
  Expert=GridExpHedge.ex5
  Symbol=XAUUSD
  Period=M5
  Model=4
  FromDate=2024.01.02
  ToDate=2026.10.01
  Deposit=100
  Currency=USD
  Leverage=1:500
  Report=reports\GridExpHedge_test
  ReplaceReport=1
  ShutdownTerminal=1
  [TesterInputs]
  InpEquityStopPercent=90
  ```
  ⚠️ `Leverage` doit être au format `1:500` (sinon MT5 prend 1:100 sans prévenir). Lancer `& "C:\Program Files\MetaTrader 5\terminal64.exe" /config:"<chemin du .ini>"`. Rapport HTML dans `reports\`, log détaillé dans `%APPDATA%\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-3000\logs\`.

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

**Causes structurelles identifiées** (corrigées dans le code v1.10/v1.20 — mais les backtests de la section 3bis montrent que la cause de fond est la stratégie elle-même) :
1. ✅ (v1.10) **Aucun SL par position** — toute la protection reposait uniquement sur le kill switch equity vérifié à chaque tick, trop lent face à un move violent. → `InpSLPoints` ajouté.
2. ✅ (v1.10) **Kill switch à -50%** — beaucoup trop tolérant. L'écart observé entre seuil visé (~53$) et résultat (0.27$) prouve que même quand il tire, les positions sont déjà bien plus loin que prévu. → passé à 20%.
3. ✅ (v1.10) **`g_initialBalance` non persistant** — se réinitialisait à chaque `OnInit()`, donc à chaque redéploiement de l'EA (fait ~10 fois en session). → persisté en variable globale terminal. Effet de bord voulu : après un kill switch, relancer l'EA ne le réactive pas tant que l'equity reste sous le seuil.

### 🟡 MOYEN — Bugs d'environnement

- **MT5 Wine se fige quand Mac se verrouille** — Wine coupe le rendu GPU en session sécurisée, process reste parfois zombie. Fix : `pkill -9 -f "MetaTrader 5"` puis relancer depuis `/Applications/MetaTrader 5.app`. **VPS activé pour contourner ça**, mais à surveiller.
- **Compte démo MetaQuotes `110924184`** : mot de passe master perdu, impossible à changer (change-password demande current, pas de reset possible sur demo anonyme). Compte toujours fonctionnel côté desktop (session cachée). Pas gênant pour le projet, à ignorer.
- **Mot de passe investisseur** : jamais réussi à être configuré correctement, user bloqué sur "Invalid account" côté téléphone. Non résolu.

---

## 7. Questions ouvertes

1. ~~Vraie cause du crash du 19 août~~ → réglée par les backtests : structure martingale + lots indexés sur la balance (section 3bis).
2. ~~TP natif en points~~ → confirmé : 15$ de mouvement, jamais touché en backtest. Sans objet (stratégie abandonnée).
3. ✅ **Abandon du martingale décidé le 2026-10-05.** Options A (TrendPullback) et C (MeanRevertBB) codées et backtestées (section 3ter) ; C écartée, A en optimisation walk-forward.
4. **Capital** : 100$ est très juste pour XAUUSD (lot min 0.01 = 1$ par 1$ de mouvement). Toute nouvelle stratégie doit risquer un % fixe de l'equity par trade et rester viable avec 0.01 lot.

---

## 8. Prochaine étape exacte

GridExpHedge (v1.20) est conservé dans le repo pour référence uniquement.

1. **Désactiver GridExpHedge sur le VPS MetaQuotes** (il y tourne encore en v1.00). À faire par le user depuis MT5.
2. ✅ Stratégies non martingale codées et backtestées (section 3ter).
3. ✅ Walk-forward TrendPullback/XAUUSD fait → **avantage non validé** (PF forward médian 1.02). Pas de démo en l'état.
4. Décision en attente du user : arrêter le trading algo réel / garder le projet comme apprentissage, ou tester une approche réellement différente — toujours avec le même protocole (optimisation 2021-2023, forward 2024-2026 non retouché, puis ticks réels). Ne pas multiplier les variantes optimisées sur les mêmes données (risque de surajustement).
5. Si un jour une stratégie est validée : capital ≥ ~2000-3000$ pour un vrai risque de 1% sur l'or, puis **démo** plusieurs semaines, **puis seulement** live.

---

**Fin du handoff.** Bon courage pour la reprise.
