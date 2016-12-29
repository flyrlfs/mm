/*
 * Copyright @ 2010, 2016 Eric B. Decker, Carl Davis
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 *
 * - Neither the name of the copyright holders nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * @author Eric B. Decker
 * @author Carl Davis
 *
 * Configuration/wiring for SDsp (SD, split phase, event driven)
 *
 * read, write, and erase are for clients.
 *
 * Wire ResourceDefaultOwner so the DefaultOwner handles power up/down.
 * When no clients are using the resource, the default owner gets it and
 * powers down the SD.
 *
 * SD_Arb provides an arbitrated interface for clients.  This is wired into
 * Msp430UsciShareB0P and is used as a dedicated SPI device.  We wire the
 * SDsp default owner code into Msp430UsciShareB0P so it can pwr the SD
 * up and down as it is used by clients.
 */

#warning wiring to SDspC in tos/chips.  You really want a platform dependent

configuration SDspC {
  provides {
    interface SDread[uint8_t cid];
    interface SDwrite[uint8_t cid];
    interface SDerase[uint8_t cid];
    interface SDsa;
    interface SDraw;
  }
  uses interface ResourceDefaultOwner;
}

implementation {
  components SDspP;
  SDread   = SDspP;
  SDwrite  = SDspP;
  SDerase  = SDspP;
  SDsa     = SDspP;
  SDraw    = SDspP;

  ResourceDefaultOwner = SDspP;

  components MainC;
  MainC.SoftwareInit -> SDspP;

  components PanicC;
  SDspP.Panic -> PanicC;

  components new TimerMilliC() as SDTimer;
  SDspP.SDtimer -> SDTimer;

/* H/W definitions should be done in a Platform dir */
//  components HplSDC as HW;
//  SDspP.HW -> HW;

  components LocalTimeMilliC as L;
  SDspP.lt -> L;

  components PlatformC;
  SDspP.Platform    -> PlatformC;
}
