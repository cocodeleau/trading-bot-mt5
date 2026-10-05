//+------------------------------------------------------------------+
//|                                                TrendPullback.mq5 |
//|  Strategy A — trend following, no martingale.                   |
//|  Trend filter: close vs EMA(200) on the higher timeframe.       |
//|  Entry: signal-timeframe bar wicks through EMA(50) and closes   |
//|  back on the trend side (pullback rejected).                    |
//|  One position at a time, SL = ATR x mult, TP = SL x RR,         |
//|  lot sized for a fixed % of equity, peak-equity kill switch.    |
//+------------------------------------------------------------------+
#property copyright "Demo/testing EA — not financial advice"
#property version   "1.00"
#property strict

#include <TradingBot/RiskManager.mqh>

input ENUM_TIMEFRAMES InpTF          = PERIOD_H1;  // Signal timeframe
input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_H4;  // Trend timeframe
input int    InpTrendEMA             = 200;        // Trend EMA period (trend timeframe)
input int    InpPullbackEMA          = 50;         // Pullback EMA period (signal timeframe)
input int    InpATRPeriod            = 14;         // ATR period (signal timeframe)
input double InpSLATRMult            = 1.5;        // SL distance = ATR x this
input double InpRR                   = 2.0;        // TP distance = SL distance x this
input double InpRiskPercent          = 1.0;        // Risk per trade, % of equity
input double InpMaxRiskPercent       = 3.0;        // Max risk accepted when forced to min lot
input double InpEquityStopPercent    = 20.0;       // Kill switch, % drawdown from peak equity
input bool   InpResetPeak            = false;      // true = reset persisted peak equity on init
input ulong  InpMagic                = 990201;

int hTrendEMA = INVALID_HANDLE;
int hPullEMA  = INVALID_HANDLE;
int hATR      = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hPullEMA  = iMA(_Symbol, InpTF, InpPullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR      = iATR(_Symbol, InpTF, InpATRPeriod);
   if(hTrendEMA == INVALID_HANDLE || hPullEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
     }
   if(!RM_Init("TrendPullback", InpMagic, InpResetPeak)) return(INIT_FAILED);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hTrendEMA != INVALID_HANDLE) IndicatorRelease(hTrendEMA);
   if(hPullEMA != INVALID_HANDLE)  IndicatorRelease(hPullEMA);
   if(hATR != INVALID_HANDLE)      IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(RM_CheckKillSwitch(InpEquityStopPercent)) return;
   if(!RM_IsNewBar(InpTF)) return;
   if(RM_HasPosition()) return;

   //--- all values from the last CLOSED bar (shift 1) — no repainting
   double trendEMA, pullEMA, atr;
   if(!RM_Buffer(hTrendEMA, 0, 1, trendEMA)) return;
   if(!RM_Buffer(hPullEMA, 0, 1, pullEMA)) return;
   if(!RM_Buffer(hATR, 0, 1, atr) || atr <= 0) return;

   double trendClose = iClose(_Symbol, InpTrendTF, 1);
   double high1  = iHigh(_Symbol, InpTF, 1);
   double low1   = iLow(_Symbol, InpTF, 1);
   double close1 = iClose(_Symbol, InpTF, 1);
   if(trendClose == 0 || close1 == 0) return;

   double slDist = atr * InpSLATRMult;

   if(trendClose > trendEMA && low1 <= pullEMA && close1 > pullEMA)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      RM_Open(true, slDist, ask + slDist * InpRR, InpRiskPercent, InpMaxRiskPercent, "TrendPB-Buy");
     }
   else if(trendClose < trendEMA && high1 >= pullEMA && close1 < pullEMA)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      RM_Open(false, slDist, bid - slDist * InpRR, InpRiskPercent, InpMaxRiskPercent, "TrendPB-Sell");
     }
  }
//+------------------------------------------------------------------+
