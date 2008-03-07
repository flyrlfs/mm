/*
 * Copyright (c) 2008, Eric B. Decker
 * All rights reserved.
 */

#include "sensors.h"

configuration BattC {
  provides interface StdControl;
}

implementation {
  components MainC, BattP;
  MainC.SoftwareInit -> BattP;
  StdControl = BattP;

  components RegimeC, new TimerMilliC() as PeriodTimer;
  BattP.RegimeCtrl -> RegimeC.Regime;
  BattP.PeriodTimer -> PeriodTimer;

  components AdcC;
  BattP.Adc -> AdcC.Adc[SNS_ID_BATT];
  AdcC.SensorPowerControl[SNS_ID_BATT] -> BattP;

  components AdcP;
  BattP.AdcConfigure <- AdcP.Config[SNS_ID_BATT];

  components CollectC;
  BattP.Collect -> CollectC;

  components HplMM3AdcC;
  BattP.HW -> HplMM3AdcC;

  components LedsC;
  BattP.Leds -> LedsC;
}
