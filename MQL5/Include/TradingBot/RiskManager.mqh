//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  Shared risk layer for the non-martingale EAs:                  |
//|  fixed-% risk lot sizing, peak-equity kill switch (persisted),  |
//|  one-position-per-magic helpers, new-bar detection.             |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade   rmTrade;
double   g_rmPeakEquity    = 0.0;
bool     g_rmDisabled      = false;
string   g_rmPeakKey       = "";
ulong    g_rmMagic         = 0;
datetime g_rmLastLotLog    = 0;
datetime g_rmLastBarTime   = 0;

//+------------------------------------------------------------------+
//| Peak equity is persisted per EA / account / symbol so that a     |
//| redeploy does not reset the kill-switch reference.               |
//+------------------------------------------------------------------+
bool RM_Init(const string eaName, const ulong magic, const bool resetPeak)
  {
   g_rmMagic   = magic;
   g_rmPeakKey = eaName + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol + "_peakEquity";

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(resetPeak || !GlobalVariableCheck(g_rmPeakKey))
      g_rmPeakEquity = equity;
   else
      g_rmPeakEquity = MathMax(GlobalVariableGet(g_rmPeakKey), equity);
   GlobalVariableSet(g_rmPeakKey, g_rmPeakEquity);
   GlobalVariablesFlush();

   rmTrade.SetExpertMagicNumber(magic);
   rmTrade.SetTypeFillingBySymbol(_Symbol);

   Print(eaName, " initialized. Peak equity reference: ", g_rmPeakEquity, " (", g_rmPeakKey, ")");
   return(g_rmPeakEquity > 0);
  }

//+------------------------------------------------------------------+
bool RM_HasPosition()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_rmMagic) continue;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void RM_CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_rmMagic) continue;
      if(!rmTrade.PositionClose(ticket))
         Print("PositionClose FAILED for ticket ", ticket, ": ", rmTrade.ResultRetcodeDescription(), " — will retry next tick");
     }
  }

//+------------------------------------------------------------------+
//| Returns true when the EA must not trade (kill switch fired).     |
//| In the Strategy Tester the run is ended, since the EA stays      |
//| disabled for the rest of the period anyway.                      |
//+------------------------------------------------------------------+
bool RM_CheckKillSwitch(const double stopPercent)
  {
   if(g_rmDisabled)
     {
      if(RM_HasPosition()) RM_CloseAll();
      return(true);
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_rmPeakEquity)
     {
      g_rmPeakEquity = equity;
      GlobalVariableSet(g_rmPeakKey, g_rmPeakEquity);
     }

   if(equity <= g_rmPeakEquity * (1.0 - stopPercent / 100.0))
     {
      RM_CloseAll();
      g_rmDisabled = true;
      Print("KILL SWITCH TRIGGERED — equity ", equity, " <= ", 100.0 - stopPercent, "% of peak ", g_rmPeakEquity, ". EA disabled.");
      Comment("EA DISABLED — kill switch hit at ", TimeToString(TimeCurrent()));
      if(MQLInfoInteger(MQL_TESTER)) TesterStop();
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Lot such that hitting SL loses riskPct of equity.                |
//| If even the minimum lot risks more than riskPct, the minimum lot |
//| is used only while its risk stays <= maxRiskPct; otherwise the   |
//| trade is skipped (returns 0) and a message is logged once a day. |
//+------------------------------------------------------------------+
double RM_LotForRisk(const ENUM_ORDER_TYPE type, const double entry, const double sl,
                     const double riskPct, const double maxRiskPct)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPerLot;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, lossPerLot)) return(0.0);
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0 || equity <= 0) return(0.0);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    digits = (int)MathMax(0, MathCeil(-MathLog10(step)));

   double lot = MathFloor((equity * riskPct / 100.0) / lossPerLot / step) * step;
   lot = MathMin(lot, maxLot);

   if(lot < minLot)
     {
      double minLotRiskPct = lossPerLot * minLot / equity * 100.0;
      if(minLotRiskPct <= maxRiskPct)
         lot = minLot;
      else
        {
         if(TimeCurrent() - g_rmLastLotLog >= 86400)
           {
            Print("Trade skipped: min lot ", minLot, " would risk ", DoubleToString(minLotRiskPct, 1),
                  "% of equity (max ", maxRiskPct, "%). Equity too small for this SL distance.");
            g_rmLastLotLog = TimeCurrent();
           }
         return(0.0);
        }
     }
   return(NormalizeDouble(lot, digits));
  }

//+------------------------------------------------------------------+
bool RM_IsNewBar(const ENUM_TIMEFRAMES tf)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t == 0 || t == g_rmLastBarTime) return(false);
   g_rmLastBarTime = t;
   return(true);
  }

//+------------------------------------------------------------------+
bool RM_Buffer(const int handle, const int buffer, const int shift, double &value)
  {
   double buf[1];
   if(CopyBuffer(handle, buffer, shift, 1, buf) != 1) return(false);
   value = buf[0];
   return(true);
  }

//+------------------------------------------------------------------+
bool RM_Open(const bool isBuy, const double slDist, const double tpPrice, const double riskPct,
             const double maxRiskPct, const string comment)
  {
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = NormalizeDouble(isBuy ? entry - slDist : entry + slDist, _Digits);
   double tp    = NormalizeDouble(tpPrice, _Digits);

   double lot = RM_LotForRisk(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entry, sl, riskPct, maxRiskPct);
   if(lot <= 0) return(false);

   bool ok = isBuy ? rmTrade.Buy(lot, _Symbol, 0, sl, tp, comment)
                   : rmTrade.Sell(lot, _Symbol, 0, sl, tp, comment);
   if(!ok)
     {
      Print("Order failed (", comment, "): ", rmTrade.ResultRetcodeDescription());
      return(false);
     }
   Print(comment, " opened, lot=", lot, ", price=", entry, ", sl=", sl, ", tp=", tp);
   return(true);
  }
//+------------------------------------------------------------------+
