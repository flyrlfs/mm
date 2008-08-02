/*
 * Copyright (c) 2008 Eric B. Decker
 * Copyright (c) 2008 Stanford University.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the Stanford University nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL STANFORD
 * UNIVERSITY OR ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */
 
/**
 * @author Eric B. Decker (cire831@gmail.com)
 * @date May 27, 2008
 *
 * wiring by Kevin, code by Eric
 * @author Kevin Klues (klueska@cs.stanford.edu)
 */

configuration GPSC {
  provides {
    interface StdControl as GPSControl;
    interface Boot as GPSBoot;
  }
  uses interface Boot;
}

implementation {
  components MainC, GPSP;
  MainC.SoftwareInit -> GPSP;
  GPSControl = GPSP;
  GPSBoot = GPSP;
  Boot = GPSP.Boot;

  components GPSMsgC;
  GPSP.GPSByte -> GPSMsgC;
  GPSP.GPSMsgControl -> GPSMsgC;

  components HplMM3AdcC;
  GPSP.HW -> HplMM3AdcC;

  components LocalTimeMilliC;
  GPSP.LocalTime -> LocalTimeMilliC;

  components new TimerMilliC() as GPSTimer;
  GPSP.GPSTimer -> GPSTimer;

  components new Msp430Uart1C() as UartC;
  GPSP.UartStream -> UartC;  
//GPSP.UartByte -> UartC;
  GPSP.UARTResource -> UartC;
  GPSP.Msp430UartConfigure <- UartC.Msp430UartConfigure;

  components HplMsp430Usart1C;
  GPSP.Usart -> HplMsp430Usart1C;

  components PanicC;
  GPSP.Panic -> PanicC;
}
