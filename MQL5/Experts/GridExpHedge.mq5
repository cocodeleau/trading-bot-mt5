//+------------------------------------------------------------------+
//|                                                GridExpHedge.mq5 |
//|  Exponential hedge grid EA — Bollinger Bands trigger,           |
//|  ATR-based spacing, 2x lot multiplier, hard level cap,          |
//|  per-position native TP + SL, global equity kill switch with    |
//|  initial-balance baseline persisted across EA restarts.         |
//|  DEMO ACCOUNT ONLY until fully validated.                       |
//+------------------------------------------------------------------+
#property copyright "Demo/testing EA — not financial advice"
#property version   "1.20"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs: entry signal — requires band touch on ALL 3 timeframes at once (M5/M15/H1)
input int    InpBBPeriod          = 20;      // Bollinger period — M5
input double InpBBDeviation       = 2.0;     // Bollinger deviation — M5
input ENUM_TIMEFRAMES InpTF       = PERIOD_M5;
input int    InpBBPeriod_M15      = 20;      // Bollinger period — M15
input double InpBBDeviation_M15   = 2.0;     // Bollinger deviation — M15
input int    InpBBPeriod_H1       = 20;      // Bollinger period — H1
input double InpBBDeviation_H1    = 2.0;     // Bollinger deviation — H1

//--- Inputs: grid
input double InpBaseLot           = 0.02;    // Base lot at tier 1 (balance < InpCapitalStepUSD*2)
input double InpCapitalStepUSD    = 100.0;   // Capital tier size — base lot doubles every step
input double InpLotMultiplier     = 2.0;     // Lot multiplier per level within a basket
input int    InpMaxLevels         = 15;      // Hard cap on grid levels
input int    InpATRPeriod         = 14;      // ATR period for spacing
input double InpATRSpacingFactor  = 1.5;     // Spacing = ATR * factor

//--- Inputs: exits / safety
input double InpTPPoints          = 15.0;    // Per-position TP, raw price distance from entry (NOT multiplied by _Point)
input double InpSLPoints          = 2000.0;  // Per-position native SL in symbol points (x _Point; 2000 = $20 on 2-digit XAUUSD). 0 = off. Must stay > grid spacing
input double InpBasketTPPercent   = 10.0;    // Combined-basket rescue TP, % of initial balance
input double InpCommissionPerTrade= 4.50;    // Flat round-turn commission per position ($)
input double InpEquityStopPercent = 20.0;    // Kill switch, % drawdown from PEAK equity (high-water mark, persisted)
input double InpMaxLotsPer100     = 0.05;    // Exposure cap: max total open lots (buy+sell, this EA) per 100 of equity. 0 = off
input ulong  InpMagicBase         = 990100;  // Magic base (buy = base+1, sell = base+2)
input bool   InpResetBaseline     = false;   // true = overwrite persisted initial balance and peak equity with current values on init (set back to false after)

//--- Globals
CTrade   trade;
int      bbHandle      = INVALID_HANDLE;   // M5
int      bbHandleM15   = INVALID_HANDLE;
int      bbHandleH1    = INVALID_HANDLE;
int      atrHandle   = INVALID_HANDLE;
double   g_initialBalance = 0.0;
double   g_peakEquity     = 0.0;     // high-water mark for the kill switch, persisted like g_initialBalance
double   g_buyLastPrice   = 0.0;
double   g_sellLastPrice  = 0.0;
bool     g_buyBlocked     = false;   // true once an add-level attempt failed (e.g. margin) — stops retry spam until basket resets
bool     g_sellBlocked    = false;
double   g_buyBaseLot     = 0.0;     // level-1 lot for the current buy basket, locked in at basket open
double   g_sellBaseLot    = 0.0;
bool     g_disabled       = false;
ulong    g_magicBuy;
ulong    g_magicSell;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_magicBuy  = InpMagicBase + 1;
   g_magicSell = InpMagicBase + 2;

   bbHandle    = iBands(_Symbol, InpTF, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   bbHandleM15 = iBands(_Symbol, PERIOD_M15, InpBBPeriod_M15, 0, InpBBDeviation_M15, PRICE_CLOSE);
   bbHandleH1  = iBands(_Symbol, PERIOD_H1, InpBBPeriod_H1, 0, InpBBDeviation_H1, PRICE_CLOSE);
   atrHandle   = iATR(_Symbol, InpTF, InpATRPeriod);
   if(bbHandle == INVALID_HANDLE || bbHandleM15 == INVALID_HANDLE ||
      bbHandleH1 == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
     }

   //--- initial balance is persisted in a terminal global variable so that redeploying
   //--- the EA (OnInit) does not silently move the kill-switch / basket-TP reference
   string gvKey = BaselineKey();
   if(InpResetBaseline || !GlobalVariableCheck(gvKey))
     {
      g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      GlobalVariableSet(gvKey, g_initialBalance);
      GlobalVariablesFlush();
      Print("Initial balance baseline ", InpResetBaseline ? "RESET" : "created", ": ", g_initialBalance, " (", gvKey, ")");
     }
   else
     {
      g_initialBalance = GlobalVariableGet(gvKey);
      Print("Initial balance baseline restored: ", g_initialBalance, " (", gvKey, ")");
     }
   if(g_initialBalance <= 0)
     {
      Print("Invalid initial balance baseline (", g_initialBalance, ") — delete global variable ", gvKey, " or set InpResetBaseline=true");
      return(INIT_FAILED);
     }

   //--- peak equity: the kill switch measures drawdown from the best equity reached, not from
   //--- the initial deposit, because lot size grows with balance (capital tiers)
   string peakKey = PeakKey();
   if(InpResetBaseline || !GlobalVariableCheck(peakKey))
      g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   else
      g_peakEquity = MathMax(GlobalVariableGet(peakKey), AccountInfoDouble(ACCOUNT_EQUITY));
   GlobalVariableSet(peakKey, g_peakEquity);
   GlobalVariablesFlush();
   Print("Peak equity reference: ", g_peakEquity, " (", peakKey, ")");

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is not in hedging mode — simultaneous buy+sell grids will net instead of hedge.");

   trade.SetTypeFillingBySymbol(_Symbol);

   Print("GridExpHedge initialized. Initial balance snapshot: ", g_initialBalance);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
string BaselineKey()
  {
   return("GridExpHedge_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_initialBalance");
  }

//+------------------------------------------------------------------+
string PeakKey()
  {
   return("GridExpHedge_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_peakEquity");
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(bbHandle != INVALID_HANDLE)    IndicatorRelease(bbHandle);
   if(bbHandleM15 != INVALID_HANDLE) IndicatorRelease(bbHandleM15);
   if(bbHandleH1 != INVALID_HANDLE)  IndicatorRelease(bbHandleH1);
   if(atrHandle != INVALID_HANDLE)   IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathRound(lot / step) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
double ComputeBaseLot()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int    tier = (int)MathFloor(balance / InpCapitalStepUSD);
   if(tier < 1) tier = 1;
   return(NormalizeLot(InpBaseLot * MathPow(2.0, tier - 1)));
  }

//+------------------------------------------------------------------+
int CountLevel(ulong magic)
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
double TotalOpenLots()
  {
   double lots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic != g_magicBuy && magic != g_magicSell) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
   return(lots);
  }

//+------------------------------------------------------------------+
double BasketProfit(ulong magic)
  {
   double sum = 0.0;
   int    count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      count++;
     }
   //--- floating PROFIT does not include commission (only charged on the closing deal),
   //--- so net it out here to compare the basket rescue target against real after-cost profit
   sum -= count * InpCommissionPerTrade;
   return(sum);
  }

//+------------------------------------------------------------------+
void CloseBasket(ulong magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(!trade.PositionClose(ticket))
         Print("PositionClose FAILED for ticket ", ticket, ": ", trade.ResultRetcodeDescription(),
               " (retcode=", trade.ResultRetcode(), ") — will retry next tick");
     }
  }

//+------------------------------------------------------------------+
void CloseAllAndDisable()
  {
   CloseBasket(g_magicBuy);
   CloseBasket(g_magicSell);
   g_buyLastPrice  = 0.0;
   g_sellLastPrice = 0.0;
   g_buyBlocked    = false;
   g_sellBlocked   = false;
   g_disabled = true;
   Print("KILL SWITCH TRIGGERED — equity stop hit. All positions closed. EA disabled.");
   Comment("GridExpHedge DISABLED — equity stop hit at ", TimeToString(TimeCurrent()));
  }

//+------------------------------------------------------------------+
bool GetBands(int handle, double &upper, double &lower)
  {
   double up[1], dn[1];
   if(CopyBuffer(handle, 1, 0, 1, up) != 1) return(false);
   if(CopyBuffer(handle, 2, 0, 1, dn) != 1) return(false);
   upper = up[0];
   lower = dn[0];
   return(true);
  }

//+------------------------------------------------------------------+
bool GetATR(double &atrValue)
  {
   double buf[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) != 1) return(false);
   atrValue = buf[0];
   return(true);
  }

//+------------------------------------------------------------------+
bool OpenGridOrder(bool isBuy, int level)
  {
   double baseLot = isBuy ? g_buyBaseLot : g_sellBaseLot;
   double lot = NormalizeLot(baseLot * MathPow(InpLotMultiplier, level - 1));
   ulong  magic = isBuy ? g_magicBuy : g_magicSell;

   //--- exposure cap: refuse any order that would push total open volume past the equity-scaled limit
   if(InpMaxLotsPer100 > 0)
     {
      double capLots = AccountInfoDouble(ACCOUNT_EQUITY) / 100.0 * InpMaxLotsPer100;
      double openLots = TotalOpenLots();
      if(openLots + lot > capLots + 1e-8)
        {
         static datetime s_lastCapLog = 0;
         if(TimeCurrent() - s_lastCapLog > 60)
           {
            Print("Exposure cap: ", isBuy ? "BUY" : "SELL", " level ", level, " lot=", lot, " refused (open=", openLots,
                  ", cap=", DoubleToString(capLots, 2), ")");
            s_lastCapLog = TimeCurrent();
           }
         return(false);
        }
     }

   trade.SetExpertMagicNumber(magic);

   string comment = StringFormat("GridExp-%s-L%d", isBuy ? "Buy" : "Sell", level);
   bool ok;
   double fillPrice, tp, sl;
   double slDist = InpSLPoints * _Point;
   if(isBuy)
     {
      fillPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      tp = NormalizeDouble(fillPrice + InpTPPoints, _Digits);
      sl = (InpSLPoints > 0) ? NormalizeDouble(fillPrice - slDist, _Digits) : 0.0;
      ok = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
     }
   else
     {
      fillPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp = NormalizeDouble(fillPrice - InpTPPoints, _Digits);
      sl = (InpSLPoints > 0) ? NormalizeDouble(fillPrice + slDist, _Digits) : 0.0;
      ok = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
     }

   if(!ok)
     {
      Print("Order failed (", isBuy ? "BUY" : "SELL", " level ", level, "): ", trade.ResultRetcodeDescription(),
            " — blocking further add-attempts on this basket until it resets");
      return(false);
     }

   if(isBuy) g_buyLastPrice = fillPrice;
   else      g_sellLastPrice = fillPrice;

   Print(comment, " opened, lot=", lot, ", price=", fillPrice, ", sl=", sl, ", tp=", tp);
   return(true);
  }

//+------------------------------------------------------------------+
void CheckEntrySignals()
  {
   double upper, lower, atr;
   if(!GetBands(bbHandle, upper, lower)) return;
   if(!GetATR(atr)) return;

   double upperM15, lowerM15, upperH1, lowerH1;
   if(!GetBands(bbHandleM15, upperM15, lowerM15)) return;
   if(!GetBands(bbHandleH1, upperH1, lowerH1)) return;

   double close0    = iClose(_Symbol, InpTF, 0);
   double closeM15   = iClose(_Symbol, PERIOD_M15, 0);
   double closeH1    = iClose(_Symbol, PERIOD_H1, 0);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- multi-timeframe confluence: M5 alone is enough to trigger, but the more
   //--- timeframes agree, the bigger the confluence multiplier on the lot size.
   //--- M5 only = x1, M5+M15 = x2, M5+M15+H1 = x4 (highest tier reached wins, no stacking)
   int buyConfluenceMult = 0;
   if(close0 <= lower)
     {
      if(closeM15 <= lowerM15 && closeH1 <= lowerH1)      buyConfluenceMult = 4;
      else if(closeM15 <= lowerM15)                       buyConfluenceMult = 2;
      else                                                 buyConfluenceMult = 1;
     }

   int sellConfluenceMult = 0;
   if(close0 >= upper)
     {
      if(closeM15 >= upperM15 && closeH1 >= upperH1)      sellConfluenceMult = 4;
      else if(closeM15 >= upperM15)                       sellConfluenceMult = 2;
      else                                                 sellConfluenceMult = 1;
     }

   int buyLevel  = CountLevel(g_magicBuy);
   int sellLevel = CountLevel(g_magicSell);

   //--- basket empty (all positions closed via their own native TP) => clear stale state
   if(buyLevel == 0)  { g_buyBlocked  = false; g_buyLastPrice  = 0.0; g_buyBaseLot  = 0.0; }
   if(sellLevel == 0) { g_sellBlocked = false; g_sellLastPrice = 0.0; g_sellBaseLot = 0.0; }

   //--- new buy basket — base lot = capital-tier lot × confluence multiplier
   if(buyLevel == 0 && buyConfluenceMult > 0 && !g_buyBlocked)
     {
      g_buyBaseLot = NormalizeLot(ComputeBaseLot() * buyConfluenceMult);
      if(!OpenGridOrder(true, 1)) g_buyBlocked = true;
     }

   //--- new sell basket — base lot = capital-tier lot × confluence multiplier
   if(sellLevel == 0 && sellConfluenceMult > 0 && !g_sellBlocked)
     {
      g_sellBaseLot = NormalizeLot(ComputeBaseLot() * sellConfluenceMult);
      if(!OpenGridOrder(false, 1)) g_sellBlocked = true;
     }

   double spacing = atr * InpATRSpacingFactor;
   if(spacing <= 0) return;

   //--- per-position SL tighter than grid spacing would stop level N out before level N+1 can open
   static datetime s_lastSpacingWarn = 0;
   if(InpSLPoints > 0 && InpSLPoints * _Point <= spacing && TimeCurrent() - s_lastSpacingWarn > 3600)
     {
      Print("WARNING: SL distance (", InpSLPoints * _Point, ") <= grid spacing (", spacing,
            ") — positions will hit SL before the next grid level can open");
      s_lastSpacingWarn = TimeCurrent();
     }

   //--- add buy level (price fell further against basket)
   buyLevel = CountLevel(g_magicBuy);
   if(buyLevel > 0 && buyLevel < InpMaxLevels && g_buyLastPrice > 0 && !g_buyBlocked)
     {
      if(bid <= g_buyLastPrice - spacing)
        {
         if(!OpenGridOrder(true, buyLevel + 1)) g_buyBlocked = true;
        }
     }

   //--- add sell level (price rose further against basket)
   sellLevel = CountLevel(g_magicSell);
   if(sellLevel > 0 && sellLevel < InpMaxLevels && g_sellLastPrice > 0 && !g_sellBlocked)
     {
      if(ask >= g_sellLastPrice + spacing)
        {
         if(!OpenGridOrder(false, sellLevel + 1)) g_sellBlocked = true;
        }
     }
  }

//+------------------------------------------------------------------+
void CheckBasketExits()
  {
   //--- combined-basket rescue: closes whatever is left of ONE direction's basket
   //--- (magic-filtered, buy and sell never mixed) once its total net profit hits target,
   //--- even if individual positions haven't reached their own native TP yet
   double target = g_initialBalance * (InpBasketTPPercent / 100.0);

   if(CountLevel(g_magicBuy) > 0 && BasketProfit(g_magicBuy) >= target)
     {
      Print("Buy basket rescue TP hit: ", BasketProfit(g_magicBuy), " >= ", target);
      CloseBasket(g_magicBuy);
     }

   if(CountLevel(g_magicSell) > 0 && BasketProfit(g_magicSell) >= target)
     {
      Print("Sell basket rescue TP hit: ", BasketProfit(g_magicSell), " >= ", target);
      CloseBasket(g_magicSell);
     }
  }

//+------------------------------------------------------------------+
bool CheckKillSwitch()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
     {
      g_peakEquity = equity;
      GlobalVariableSet(PeakKey(), g_peakEquity);
     }
   double floor   = g_peakEquity * (1.0 - InpEquityStopPercent / 100.0);
   if(equity <= floor)
     {
      CloseAllAndDisable();
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_disabled) return;
   if(CheckKillSwitch()) return;

   CheckBasketExits();
   CheckEntrySignals();
  }
//+------------------------------------------------------------------+
