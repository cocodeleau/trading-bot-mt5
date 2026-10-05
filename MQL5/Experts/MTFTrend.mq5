//+------------------------------------------------------------------+
//|                                                     MTFTrend.mq5 |
//|  Multi-timeframe trend alignment (default M5 + M15 + H1, inputs),|
//|  no martingale.                                                   |
//|  Trend on each TF: SMA20 > SMA50 and close > SMA50 (bear: mirror)|
//|  Trade only when all three TFs agree, triggered on M5 by one of  |
//|  three Bollinger modes, filtered by M5 RSI.                      |
//|  Risk: lot sized so the SL loses InpRiskPercent of equity.       |
//|  Exit: TP at InpRR x risk, trailing stop at 1R distance once the |
//|  trade is InpTrailStartR in profit.                              |
//+------------------------------------------------------------------+
#property copyright "Demo/testing EA — not financial advice"
#property version   "1.10"
#property strict

#include <TradingBot/RiskManager.mqh>

enum ENUM_BB_TRIGGER
  {
   TRIGGER_MIDDLE   = 0,   // Pullback to middle band, close back on trend side
   TRIGGER_BREAKOUT = 1,   // Close beyond the outer band in trend direction
   TRIGGER_DEEP     = 2    // Deep pullback: wick touches the opposite outer band
  };

input ENUM_TIMEFRAMES InpTFEntry     = PERIOD_M5;   // Entry timeframe (trend + Bollinger/RSI/ATR trigger)
input ENUM_TIMEFRAMES InpTFMid       = PERIOD_M15;  // Middle timeframe (trend only)
input ENUM_TIMEFRAMES InpTFHigh      = PERIOD_H1;   // Higher timeframe (trend only)
input ENUM_BB_TRIGGER InpTrigger     = TRIGGER_MIDDLE;
input int    InpMAFast               = 20;     // Fast SMA (all timeframes)
input int    InpMASlow               = 50;     // Slow SMA (all timeframes)
input int    InpBBPeriod             = 20;     // Bollinger period (M5)
input double InpBBDeviation          = 2.0;    // Bollinger deviation (M5)
input int    InpRSIPeriod            = 14;     // RSI period (M5)
input double InpRSIMomentumLow       = 50.0;   // Buy needs RSI in [this, High] for MIDDLE/BREAKOUT (sell: mirrored)
input double InpRSIMomentumHigh      = 70.0;
input double InpRSIPullbackLow       = 30.0;   // Buy needs RSI in [this, 50] for DEEP (sell: mirrored)
input int    InpATRPeriod            = 14;     // ATR period (M5)
input double InpSLATRMult            = 1.5;    // SL distance = ATR x this
input double InpRR                   = 2.0;    // TP distance = SL distance x this
input double InpTrailStartR          = 1.0;    // Start trailing once profit >= this x risk
input double InpRiskPercent          = 5.0;    // Risk per trade, % of equity
input double InpMaxRiskPercent       = 5.0;    // Max risk accepted when forced to min lot
input double InpEquityStopPercent    = 20.0;   // Kill switch, % drawdown from peak equity
input bool   InpResetPeak            = false;  // true = reset persisted peak equity on init
input ulong  InpMagic                = 990401;

ENUM_TIMEFRAMES TFS[3];
int hFast[3], hSlow[3];
int hBB  = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;
int hATR = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   TFS[0] = InpTFEntry;
   TFS[1] = InpTFMid;
   TFS[2] = InpTFHigh;
   for(int i = 0; i < 3; i++)
     {
      hFast[i] = iMA(_Symbol, TFS[i], InpMAFast, 0, MODE_SMA, PRICE_CLOSE);
      hSlow[i] = iMA(_Symbol, TFS[i], InpMASlow, 0, MODE_SMA, PRICE_CLOSE);
      if(hFast[i] == INVALID_HANDLE || hSlow[i] == INVALID_HANDLE)
        {
         Print("Failed to create MA handles");
         return(INIT_FAILED);
        }
     }
   hBB  = iBands(_Symbol, InpTFEntry, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, InpTFEntry, InpRSIPeriod, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpTFEntry, InpATRPeriod);
   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
     }
   if(!RM_Init("MTFTrend", InpMagic, InpResetPeak)) return(INIT_FAILED);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int i = 0; i < 3; i++)
     {
      if(hFast[i] != INVALID_HANDLE) IndicatorRelease(hFast[i]);
      if(hSlow[i] != INVALID_HANDLE) IndicatorRelease(hSlow[i]);
     }
   if(hBB != INVALID_HANDLE)  IndicatorRelease(hBB);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
//| +1 bullish, -1 bearish, 0 neutral — last closed bar of TFS[i]     |
//+------------------------------------------------------------------+
int TrendOf(const int i)
  {
   double fast, slow;
   if(!RM_Buffer(hFast[i], 0, 1, fast)) return(0);
   if(!RM_Buffer(hSlow[i], 0, 1, slow)) return(0);
   double close1 = iClose(_Symbol, TFS[i], 1);
   if(close1 == 0) return(0);
   if(fast > slow && close1 > slow) return(1);
   if(fast < slow && close1 < slow) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Trailing stop: once profit >= InpTrailStartR x R, keep the SL at  |
//| 1R behind price (so it is at break-even when trailing starts).    |
//| R is recovered from the untouched TP: R = |TP - open| / InpRR.    |
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_rmMagic) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(tp == 0 || InpRR <= 0) continue;
      double r = MathAbs(tp - open) / InpRR;
      if(r <= 0) continue;

      double price  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit = isBuy ? price - open : open - price;
      if(profit < InpTrailStartR * r) continue;

      double newSL = NormalizeDouble(isBuy ? price - r : price + r, _Digits);
      //--- only move in the favourable direction, and by at least 10% of R to avoid spamming modifications
      bool better = isBuy ? (newSL > sl + 0.1 * r) : (sl == 0 || newSL < sl - 0.1 * r);
      if(!better) continue;
      if(!rmTrade.PositionModify(ticket, newSL, tp))
         Print("Trailing modify failed: ", rmTrade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(RM_CheckKillSwitch(InpEquityStopPercent)) return;
   if(RM_HasPosition())
     {
      ManageTrailing();
      return;
     }
   if(!RM_IsNewBar(InpTFEntry)) return;

   //--- all three timeframes must agree
   int t5 = TrendOf(0);
   if(t5 == 0 || TrendOf(1) != t5 || TrendOf(2) != t5) return;
   bool isBuy = (t5 > 0);

   double middle, upper, lower, rsi, atr;
   if(!RM_Buffer(hBB, 0, 1, middle)) return;
   if(!RM_Buffer(hBB, 1, 1, upper)) return;
   if(!RM_Buffer(hBB, 2, 1, lower)) return;
   if(!RM_Buffer(hRSI, 0, 1, rsi)) return;
   if(!RM_Buffer(hATR, 0, 1, atr) || atr <= 0) return;
   double high1  = iHigh(_Symbol, InpTFEntry, 1);
   double low1   = iLow(_Symbol, InpTFEntry, 1);
   double close1 = iClose(_Symbol, InpTFEntry, 1);

   //--- RSI filter: momentum band for MIDDLE/BREAKOUT, pullback band for DEEP (sell side mirrored around 50)
   double rsiDir = isBuy ? rsi : 100.0 - rsi;
   bool rsiOk = (InpTrigger == TRIGGER_DEEP) ? (rsiDir >= InpRSIPullbackLow && rsiDir <= 50.0)
                                             : (rsiDir >= InpRSIMomentumLow && rsiDir <= InpRSIMomentumHigh);
   if(!rsiOk) return;

   bool trig = false;
   switch(InpTrigger)
     {
      case TRIGGER_MIDDLE:
         trig = isBuy ? (low1 <= middle && close1 > middle) : (high1 >= middle && close1 < middle);
         break;
      case TRIGGER_BREAKOUT:
         trig = isBuy ? (close1 > upper) : (close1 < lower);
         break;
      case TRIGGER_DEEP:
         trig = isBuy ? (low1 <= lower) : (high1 >= upper);
         break;
     }
   if(!trig) return;

   double slDist = atr * InpSLATRMult;
   double entry  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp     = isBuy ? entry + slDist * InpRR : entry - slDist * InpRR;
   RM_Open(isBuy, slDist, tp, InpRiskPercent, InpMaxRiskPercent,
           StringFormat("MTF-%s-T%d", isBuy ? "Buy" : "Sell", (int)InpTrigger));
  }
//+------------------------------------------------------------------+
