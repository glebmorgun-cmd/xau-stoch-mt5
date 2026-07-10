//+------------------------------------------------------------------+
//|                                 XAU_Stoch_VisualSignals.mq5       |
//| Visual prototype of the agreed XAUUSD Stochastic strategy.       |
//|                                                                  |
//| The indicator DOES NOT trade. It reconstructs the virtual        |
//| position state on closed bars and draws entry/exit arrows.        |
//|                                                                  |
//| Initial strategy rules:                                          |
//|  - Stochastic 5/3/3, Simple, Low/High.                            |
//|  - Session 10:00-22:00 Moscow time.                               |
//|  - Buy after %K exits oversold upward through 20 and %K > %D.     |
//|  - Sell after %K exits overbought downward through 80 and %K < %D.|
//|  - A long closes when %K reaches 80; a short closes at %K = 20.   |
//|  - No reversal on the exit bar.                                   |
//|  - Indicator stop: two adverse closed bars at 10/90.              |
//|  - Emergency price stop: 5.00 XAUUSD price units.                 |
//|  - Maximum spread: 0.20 XAUUSD price units.                       |
//|  - At least five minutes between entries.                         |
//|                                                                  |
//| Arrow legend:                                                     |
//|  Green up    = BUY entry                                         |
//|  Red down    = SELL entry                                        |
//|  Orange down = close BUY                                         |
//|  Blue up     = close SELL                                        |
//+------------------------------------------------------------------+
#property copyright "Visual strategy prototype"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

#property indicator_label1  "BUY entry"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  2

#property indicator_label2  "SELL entry"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrTomato
#property indicator_width2  2

#property indicator_label3  "Close BUY"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrange
#property indicator_width3  2

#property indicator_label4  "Close SELL"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrDeepSkyBlue
#property indicator_width4  2

input group "Stochastic"
input int                InpKPeriod                = 5;
input int                InpDPeriod                = 3;
input int                InpSlowing                = 3;
input ENUM_MA_METHOD     InpMAMethod               = MODE_SMA;
input ENUM_STO_PRICE     InpPriceField             = STO_LOWHIGH;
input double             InpOversoldLevel          = 20.0;
input double             InpOverboughtLevel        = 80.0;

input group "Moscow session"
input int                InpSessionStartHour       = 10;
input int                InpSessionStartMinute     = 0;
input int                InpSessionEndHour         = 22;
input int                InpSessionEndMinute       = 0;
// Add this many hours to the broker's chart time to obtain Moscow time.
// Keep 0 when the broker server/chart time is already Moscow time.
input int                InpServerToMoscowHours    = 0;
input bool               InpCloseAtSessionEnd      = true;

input group "Entry filters"
// Price difference Ask-Bid expressed in XAUUSD price units, not points.
// Set 0 to disable the historical spread filter.
input double             InpMaxSpreadPrice         = 0.20;
input int                InpMinMinutesBetweenEntries = 5;

input group "Protection"
input bool               InpUseIndicatorStop       = true;
input double             InpLongStopLevel          = 10.0;
input double             InpShortStopLevel         = 90.0;
input int                InpStopConfirmationBars   = 2;
// Visual backtest stop in XAUUSD price units. Set 0 to disable.
input double             InpEmergencyStopPrice     = 5.0;

input group "Display and calculation"
input double             InpArrowOffsetPrice       = 0.30;
input int                InpMaxBars                = 50000;

double BuyEntryBuffer[];
double SellEntryBuffer[];
double CloseBuyBuffer[];
double CloseSellBuffer[];

int    StochasticHandle = INVALID_HANDLE;
double MainLine[];
double SignalLine[];

enum ENUM_VIRTUAL_POSITION
  {
   VIRTUAL_FLAT  = 0,
   VIRTUAL_LONG  = 1,
   VIRTUAL_SHORT = -1
  };

//+------------------------------------------------------------------+
//| Convert server/chart time to the time used by the session filter. |
//+------------------------------------------------------------------+
datetime ToMoscowTime(const datetime server_time)
  {
   return(server_time + InpServerToMoscowHours * 3600);
  }

//+------------------------------------------------------------------+
//| Return true when a bar belongs to the configured Moscow session.  |
//+------------------------------------------------------------------+
bool IsInsideSession(const datetime server_time)
  {
   MqlDateTime parts;
   TimeToStruct(ToMoscowTime(server_time),parts);

   const int current_minute = parts.hour * 60 + parts.min;
   const int start_minute   = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int end_minute     = InpSessionEndHour * 60 + InpSessionEndMinute;

   if(start_minute == end_minute)
      return(true); // 24-hour session

   if(start_minute < end_minute)
      return(current_minute >= start_minute && current_minute < end_minute);

   // Also supports a session crossing midnight.
   return(current_minute >= start_minute || current_minute < end_minute);
  }

//+------------------------------------------------------------------+
//| Historical spread filter.                                        |
//+------------------------------------------------------------------+
bool IsSpreadAllowed(const int spread_points)
  {
   if(InpMaxSpreadPrice <= 0.0 || spread_points <= 0)
      return(true);

   return(spread_points * _Point <= InpMaxSpreadPrice + _Point * 0.1);
  }

//+------------------------------------------------------------------+
//| Arrow distance from a candle.                                     |
//+------------------------------------------------------------------+
double ArrowOffset(const double bar_high,const double bar_low)
  {
   return(MathMax(InpArrowOffsetPrice,(bar_high - bar_low) * 0.25));
  }

//+------------------------------------------------------------------+
//| Indicator initialization.                                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpKPeriod < 1 || InpDPeriod < 1 || InpSlowing < 1 ||
      InpOversoldLevel <= 0.0 || InpOverboughtLevel >= 100.0 ||
      InpOversoldLevel >= InpOverboughtLevel ||
      InpStopConfirmationBars < 1 || InpMaxBars < 100)
     {
      Print("Invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   SetIndexBuffer(0,BuyEntryBuffer,INDICATOR_DATA);
   SetIndexBuffer(1,SellEntryBuffer,INDICATOR_DATA);
   SetIndexBuffer(2,CloseBuyBuffer,INDICATOR_DATA);
   SetIndexBuffer(3,CloseSellBuffer,INDICATOR_DATA);

   ArraySetAsSeries(BuyEntryBuffer,true);
   ArraySetAsSeries(SellEntryBuffer,true);
   ArraySetAsSeries(CloseBuyBuffer,true);
   ArraySetAsSeries(CloseSellBuffer,true);
   ArraySetAsSeries(MainLine,true);
   ArraySetAsSeries(SignalLine,true);

   // Wingdings arrow codes used by MetaTrader.
   PlotIndexSetInteger(0,PLOT_ARROW,233); // up arrow
   PlotIndexSetInteger(1,PLOT_ARROW,234); // down arrow
   PlotIndexSetInteger(2,PLOT_ARROW,242); // down exit arrow
   PlotIndexSetInteger(3,PLOT_ARROW,241); // up exit arrow

   for(int plot=0; plot<4; plot++)
      PlotIndexSetDouble(plot,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      "XAU Stoch Visual 5/3/3 (confirmed exits)");

   StochasticHandle=iStochastic(_Symbol,_Period,
                                InpKPeriod,InpDPeriod,InpSlowing,
                                InpMAMethod,InpPriceField);
   if(StochasticHandle == INVALID_HANDLE)
     {
      Print("Unable to create iStochastic handle. Error: ",GetLastError());
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Release resources.                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(StochasticHandle != INVALID_HANDLE)
      IndicatorRelease(StochasticHandle);
  }

//+------------------------------------------------------------------+
//| Calculate arrows on CLOSED bars only.                             |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < InpKPeriod + InpDPeriod + InpSlowing + 10)
      return(0);

   ArraySetAsSeries(time,true);
   ArraySetAsSeries(open,true);
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);
   ArraySetAsSeries(spread,true);

   if(BarsCalculated(StochasticHandle) < rates_total)
      return(prev_calculated);

   if(CopyBuffer(StochasticHandle,0,0,rates_total,MainLine) != rates_total ||
      CopyBuffer(StochasticHandle,1,0,rates_total,SignalLine) != rates_total)
     {
      Print("Unable to copy Stochastic buffers. Error: ",GetLastError());
      return(prev_calculated);
     }

   ArrayInitialize(BuyEntryBuffer,EMPTY_VALUE);
   ArrayInitialize(SellEntryBuffer,EMPTY_VALUE);
   ArrayInitialize(CloseBuyBuffer,EMPTY_VALUE);
   ArrayInitialize(CloseSellBuffer,EMPTY_VALUE);

   const int oldest_bar=MathMin(rates_total-2,InpMaxBars-1);

   ENUM_VIRTUAL_POSITION position=VIRTUAL_FLAT;
   double   entry_price=0.0;
   datetime last_entry_time=0;
   int      long_stop_count=0;
   int      short_stop_count=0;

   // Series arrays: a larger index is older. Iterate oldest -> newest.
   // Index 0 is deliberately excluded because it is the live candle.
   for(int i=oldest_bar; i>=1; i--)
     {
      const bool in_session=IsInsideSession(time[i]);
      const double offset=ArrowOffset(high[i],low[i]);
      const double bar_spread_price=(spread[i] > 0 ? spread[i]*_Point : 0.0);

      // Close a carried position at the first bar outside the session.
      if(!in_session)
        {
         if(InpCloseAtSessionEnd && position == VIRTUAL_LONG)
           {
            CloseBuyBuffer[i]=high[i]+offset;
            position=VIRTUAL_FLAT;
           }
         else if(InpCloseAtSessionEnd && position == VIRTUAL_SHORT)
           {
            CloseSellBuffer[i]=low[i]-offset;
            position=VIRTUAL_FLAT;
           }

         long_stop_count=0;
         short_stop_count=0;
         continue;
        }

      bool exited_this_bar=false;

      if(position == VIRTUAL_LONG)
        {
         // A broker-side emergency SL is modelled using the bar Low.
         if(InpEmergencyStopPrice > 0.0 &&
            low[i] <= entry_price - InpEmergencyStopPrice)
           {
            CloseBuyBuffer[i]=high[i]+offset;
            position=VIRTUAL_FLAT;
            exited_this_bar=true;
           }
         else
           {
            const bool adverse=(MainLine[i] <= InpLongStopLevel &&
                                MainLine[i] < SignalLine[i]);
            long_stop_count=(adverse ? long_stop_count+1 : 0);

            if(InpUseIndicatorStop &&
               long_stop_count >= InpStopConfirmationBars)
              {
               CloseBuyBuffer[i]=high[i]+offset;
               position=VIRTUAL_FLAT;
               exited_this_bar=true;
              }
            else if(MainLine[i] >= InpOverboughtLevel)
              {
               // Target reached: close, but never reverse on this bar.
               CloseBuyBuffer[i]=high[i]+offset;
               position=VIRTUAL_FLAT;
               exited_this_bar=true;
              }
           }
        }
      else if(position == VIRTUAL_SHORT)
        {
         // A broker-side emergency SL is modelled using the bar High.
         if(InpEmergencyStopPrice > 0.0 &&
            high[i]+bar_spread_price >= entry_price + InpEmergencyStopPrice)
           {
            CloseSellBuffer[i]=low[i]-offset;
            position=VIRTUAL_FLAT;
            exited_this_bar=true;
           }
         else
           {
            const bool adverse=(MainLine[i] >= InpShortStopLevel &&
                                MainLine[i] > SignalLine[i]);
            short_stop_count=(adverse ? short_stop_count+1 : 0);

            if(InpUseIndicatorStop &&
               short_stop_count >= InpStopConfirmationBars)
              {
               CloseSellBuffer[i]=low[i]-offset;
               position=VIRTUAL_FLAT;
               exited_this_bar=true;
              }
            else if(MainLine[i] <= InpOversoldLevel)
              {
               // Target reached: close, but never reverse on this bar.
               CloseSellBuffer[i]=low[i]-offset;
               position=VIRTUAL_FLAT;
               exited_this_bar=true;
              }
           }
        }

      if(exited_this_bar)
        {
         entry_price=0.0;
         long_stop_count=0;
         short_stop_count=0;
         continue;
        }

      if(position != VIRTUAL_FLAT)
         continue;

      if(!IsSpreadAllowed(spread[i]))
         continue;

      if(last_entry_time > 0 &&
         time[i]-last_entry_time < InpMinMinutesBetweenEntries*60)
         continue;

      // The older closed bar is i+1. The current closed bar is i.
      const bool buy_signal=(MainLine[i+1] <= InpOversoldLevel &&
                             MainLine[i]   >  InpOversoldLevel &&
                             MainLine[i]   >  SignalLine[i]);

      const bool sell_signal=(MainLine[i+1] >= InpOverboughtLevel &&
                              MainLine[i]   <  InpOverboughtLevel &&
                              MainLine[i]   <  SignalLine[i]);

      if(buy_signal)
        {
         BuyEntryBuffer[i]=low[i]-offset;
         position=VIRTUAL_LONG;
         entry_price=close[i]+bar_spread_price; // approximate historical Ask
         last_entry_time=time[i];
         long_stop_count=0;
         short_stop_count=0;
        }
      else if(sell_signal)
        {
         SellEntryBuffer[i]=high[i]+offset;
         position=VIRTUAL_SHORT;
         entry_price=close[i]; // chart price is normally Bid
         last_entry_time=time[i];
         long_stop_count=0;
         short_stop_count=0;
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
