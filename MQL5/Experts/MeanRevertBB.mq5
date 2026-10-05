//+------------------------------------------------------------------+
//|                                                 MeanRevertBB.mq5 |
//|  Strategy C — Bollinger mean reversion, no martingale, no grid. |
//|  Entry: last closed bar closed outside a band -> fade it.       |
//|  TP = middle band at entry time, SL = ATR x mult.               |
//|  One position at a time, lot sized for a fixed % of equity,     |
//|  peak-equity kill switch.                                       |
//+------------------------------------------------------------------+
#property copyright "Demo/testing EA — not financial advice"
#property version   "1.00"
#property strict

#include <TradingBot/RiskManager.mqh>

input ENUM_TIMEFRAMES InpTF          = PERIOD_H1;  // Signal timeframe
input int    InpBBPeriod             = 20;         // Bollinger period
input double InpBBDeviation          = 2.0;        // Bollinger deviation
input int    InpATRPeriod            = 14;         // ATR period
input double InpSLATRMult            = 1.5;        // SL distance = ATR x this
input double InpMinRR                = 0.5;        // Skip if (distance to middle band) < SL distance x this
input double InpRiskPercent          = 1.0;        // Risk per trade, % of equity
input double InpMaxRiskPercent       = 3.0;        // Max risk accepted when forced to min lot
input double InpEquityStopPercent    = 20.0;       // Kill switch, % drawdown from peak equity
input bool   InpResetPeak            = false;      // true = reset persisted peak equity on init
input ulong  InpMagic                = 990301;

int hBB  = INVALID_HANDLE;
int hATR = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   hBB  = iBands(_Symbol, InpTF, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);
   if(hBB == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
     }
   if(!RM_Init("MeanRevertBB", InpMagic, InpResetPeak)) return(INIT_FAILED);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hBB != INVALID_HANDLE)  IndicatorRelease(hBB);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(RM_CheckKillSwitch(InpEquityStopPercent)) return;
   if(!RM_IsNewBar(InpTF)) return;
   if(RM_HasPosition()) return;

   //--- iBands buffers: 0 = middle, 1 = upper, 2 = lower — last CLOSED bar
   double middle, upper, lower, atr;
   if(!RM_Buffer(hBB, 0, 1, middle)) return;
   if(!RM_Buffer(hBB, 1, 1, upper)) return;
   if(!RM_Buffer(hBB, 2, 1, lower)) return;
   if(!RM_Buffer(hATR, 0, 1, atr) || atr <= 0) return;

   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 == 0) return;

   double slDist = atr * InpSLATRMult;

   if(close1 < lower)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(middle - ask >= slDist * InpMinRR)
         RM_Open(true, slDist, middle, InpRiskPercent, InpMaxRiskPercent, "MeanRev-Buy");
     }
   else if(close1 > upper)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid - middle >= slDist * InpMinRR)
         RM_Open(false, slDist, middle, InpRiskPercent, InpMaxRiskPercent, "MeanRev-Sell");
     }
  }
//+------------------------------------------------------------------+
