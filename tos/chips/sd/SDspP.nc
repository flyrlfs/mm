/**
 * SDsp - low level Secure Digital storage driver
 * Split phase, event driven.
 *
 * Copyright (c) 2014, 2016-2018: Eric B. Decker
 * Copyright (c) 2010, Eric B. Decker, Carl Davis
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 * See COPYING in the top level directory of this source tree.
 *
 * Contact: Eric B. Decker <cire831@gmail.com>
 *          Carl Davis
 */

/*
 * Uses a dedicated SPI bus and I/O port.
 *
 * Wiring to this driver should be done via an affiliated platform
 * configuration such as <platform>/hardware/sd/SD0C.nc.  See
 * tos/platforms/dev6a/hardware/sd/SD0C.nc.
 *
 * PLATFORM_SDSC_ONLY
 * PLATFORM_SDHC_ONLY
 * PLATFORM_ERASE_0
 * PLATFORM_ERASE_1
 */

#include "hardware.h"
#include "sd.h"
#include "sd_cmd.h"
#include <panic.h>
#include <platform_panic.h>

#ifdef FAIL
#warning "FAIL defined, undefining, it should be an enum"
#undef FAIL
#endif

#ifndef PANIC_SD
enum {
  __pcode_sd = unique(UQ_PANIC_SUBSYS)
};

#define PANIC_SD __pcode_sd
#endif

generic module SDspP() {
  provides {
    interface SDread[uint8_t cid];
    interface SDwrite[uint8_t cid];
    interface SDerase[uint8_t cid];
    interface SDsa;			/* standalone */
    interface SDraw;			/* raw */
    interface Init as SoftwareInit @exactlyonce();
  }
  uses {
    interface ResourceDefaultOwner;
    interface Timer<TMilli> as SDtimer;
    interface LocalTime<TMilli> as lt;
    interface SDHardware as HW;
    interface Platform;
    interface Panic;
  }
}

implementation {

/*
 * when resetting.   How long to wait before trying to send the GO_OP
 * to the SD card again.  We let other things happen in the system.
 * Units are in millisecs (TMilli).
 *
 * Note: POLL_TIME of 1 gives us about 750us.
 */
#define GO_OP_POLL_TIME 10

  typedef enum {
    SDS_OFF = 0,
    SDS_OFF_TO_ON,
    SDS_RESET,
    SDS_IDLE,
    SDS_READ,
    SDS_READ_DMA,
    SDS_WRITE,
    SDS_WRITE_DMA,
    SDS_WRITE_BUSY,
    SDS_ERASE,
    SDS_ERASE_BUSY,
  } sd_state_t;

  uint32_t w_t, w_diff;
  uint32_t sa_t0, sa_diff;
  uint16_t sa_t3;

  /*
   * main SDsp control cells.   The code can handle at most one operation at a time,
   * duh, we've only got one piece of h/w.
   *
   * SD_Arb provides for arbritration as well as assignment of client ids (cid).
   * SDsp however does not assume access control via the arbiter.  One could wire
   * in directly.  Rather it uses a state variable to control coherent access.  If
   * the driver is IDLE then it allows a client to start something new up.  It is
   * assumed that the client has gained access using the arbiter.  The arbiter is what
   * queues clients when the SD is already busy.  When the current client finishes
   * and releases the device, the arbiter will signal the next client to begin.
   *
   * majik_a   protection tombstone, SD_MAJIK
   * sdhc      T if high capacity, F -> sdsc
   * sdsa_majik if SDSA_MAJIK, in stand alone
   * blocks    number of 512 byte blocks on the disk
   * blk_start holds the blk id we are working on
   * blk_end   if needed holds the last block working on (like for erase)
   * sd_state  current driver state, non-IDLE if we are busy doing something.
   *           IDLE if powered on but not busy
   * cur_cid   client id of who has requested the activity.
   * data_ptr  buffer pointer if needed.
   * erase_state when erased the default state of a sector
   * majik_b   protection tombstone, SD_MAJIK
   *
   * if sd_state is SDS_IDLE, blk_start, blk_end, cur_cid, and data_ptr are
   * meaningless.
   */

#define SD_MAJIK 0x5aa5
#define SDSA_MAJIK 0xAAAA5555
#define CID_NONE 0xff;

  /*
   * if blocks is 0, we haven't initialized disk params
   *
   * disk params (dp) gets initilized the first time we power up, typically
   * when the FileSystem does its thing.
   */
  norace struct {
    uint16_t   majik_a;
    sd_state_t sd_state;
    uint8_t    sdhc;                    /* dp, F: SDSC, T: SDHC */
    uint32_t   sdsa_majik;              /* none zero if in stand alone */
    uint32_t   blocks;                  /* dp, total blocks     */
    uint32_t   blk_start, blk_end;
    uint8_t    cur_cid;			/* current client */
    uint8_t    *data_ptr;
    uint16_t   erase_state;             /* dp, 0x00 or 0xff */
    uint16_t   majik_b;
  } sdc;


  /* instrumentation
   *
   * need to think about these timeout and how to do with time vs. counts
   */
         uint32_t     sd_go_op_count;
  norace uint32_t     sd_read_tok_count;	/* how many times we've looked for a read token */
         uint32_t     sd_erase_busy_count;
  norace uint32_t     sd_write_busy_count;

         uint32_t     op_t0_ms;                 /* start time of various operations */
  norace uint32_t     op_t0_us;

  norace uint32_t     sd_pwr_on_time_us;
         uint32_t     last_pwr_on_first_cmd_us;
         uint32_t     last_full_reset_time_us;

  norace uint32_t     last_reset_start_time_us;
  norace uint32_t     last_reset_start_time_ms;

  uint32_t     max_reset_time_ms, last_reset_delta_ms;
  uint32_t     max_reset_time_us, last_reset_delta_us;

  uint32_t     max_read_time_ms,  last_read_delta_ms;
  uint32_t     max_read_time_us,  last_read_delta_us;

  uint32_t     max_write_time_ms, last_write_delta_ms;
  uint32_t     max_write_time_us, last_write_delta_us;

  uint32_t     max_erase_time_ms, last_erase_delta_ms;
  uint32_t     max_erase_time_us, last_erase_delta_us;


#define sd_panic(where, arg) do { call Panic.panic(PANIC_SD, where, arg, 0, 0, 0); } while (0)
#define  sd_warn(where, arg) do { call  Panic.warn(PANIC_SD, where, arg, 0, 0, 0); } while (0)

  void sd_panic_idle(uint8_t where, parg_t arg) {
    call Panic.panic(PANIC_SD, where, arg, 0, 0, 0);
    sdc.sd_state = SDS_IDLE;
    sdc.cur_cid = CID_NONE;
  }


  /*
   * sd_raw_cmd
   *
   * Send a command to the SD and receive a response from the SD.
   * The response is always a single byte and is the R1 response
   * as documented in the SD manual.
   *
   * raw_cmd is always part of a cmd sequence.  The caller is responsible
   * for asserting CS.
   *
   * raw_cmd does not change the SD card state in any other way,
   * meaning it doesn't read any more bytes from the card for other
   * types of responses.
   *
   * Does not provide any kind of transactional control meaning
   * it doesn't send any extra clocks that are needed at the end
   * of a transaction, cmd/rsp, data transfer, etc.
   *
   * return: R1 response byte,  0 says everything is wonderful.
   */

  uint8_t sd_raw_cmd(uint8_t cmd, uint32_t arg) {
    uint16_t  i;
    uint8_t   rsp, crc;

    switch (cmd) {
      case CMD0: crc = 0x95; break;
      case CMD8: crc = 0x87; break;
      default:   crc = 0x55; break;
    }

    call HW.spi_check_clean();

    call HW.spi_put(cmd);
    call HW.spi_put((uint8_t) (arg >> 24));
    call HW.spi_put((uint8_t) (arg >> 16));
    call HW.spi_put((uint8_t) (arg >>  8));
    call HW.spi_put((uint8_t) (arg >>  0));
    call HW.spi_put(crc);

    /* Wait for a response.  */
    i=0;
    do {
      rsp = call HW.spi_get();
      if (rsp == 0x7f) {
        sd_warn(35, rsp);
        rsp = 0xff;
      }
      i++;
    } while ((rsp & 0x80) && (i < SD_CMD_TIMEOUT));

    /* Just bail if we never got a response */
    if (i >= SD_CMD_TIMEOUT) {
      sd_panic(35, rsp);
      return 0xf0;
    }
    return rsp;
  }


  /*
   * send_command:
   *
   * send a simple command to the SD.  A simple command has an R1 response
   * and we handle it as a cmd/rsp transaction with the extra clocks at
   * the end to let the SD finish.
   */
  uint8_t sd_send_command(uint8_t cmd, uint32_t arg) {
    uint8_t rsp;

    call HW.sd_set_cs();
    rsp = sd_raw_cmd(cmd, arg);
    call HW.spi_get();          /* sandisk needs this */
    call HW.sd_clr_cs();
    return rsp;
  }


  /*
   * Send ACMD
   *
   * assume the command in the cmd buffer is an ACMD and should
   * be proceeded by a CMD55.
   *
   * closes the cmd/rsp transaction when done.
   */
  uint8_t sd_send_acmd(uint8_t cmd, uint32_t arg) {
    uint8_t rsp;

    call HW.sd_set_cs();
    rsp = sd_raw_cmd(CMD55, 0);
    call HW.spi_get();          /* sandisk needs this */
    if (rsp & ~MSK_IDLE) {      /* 00 or 01 is fine, others not so much */
      call HW.sd_clr_cs();
      return rsp;
    }
    rsp = sd_raw_cmd(cmd, arg);
    call HW.spi_get();          /* sandisk needs this */
    call HW.sd_clr_cs();
    return rsp;
  }


  /*
   * sd_get_block
   *
   * Assume a block of data is coming from the SD card.  Look for the
   * start token then pull the number of bytes required from the SD.
   *
   * returns SUCCESS if all worked okay
   *         FAIL    on error.
   */

  error_t sd_get_block(uint8_t *buf, unsigned int count) {
    uint32_t t0;
    uint8_t  b;

    t0 = call Platform.usecsRaw();
    while (1) {
      b = call HW.spi_get();
      if (b != 0xff)
        break;
      if (call Platform.usecsRaw() - t0 > 10000)
        return FAIL;
    }
    if (b != SD_START_TOK)
      return FAIL;
    while (count) {
      *(buf++) = call HW.spi_get();
      count--;
    }
    return SUCCESS;
  }


  /*
   * sd_get_vreg
   *
   * get a variable length register from the SD
   *
   * returns: 0         all is well
   *          >0        return code from SD
   */

  uint8_t sd_get_vreg(uint8_t *buf, uint8_t cmd, unsigned int count) {
    uint8_t rsp;

    call HW.sd_set_cs();
    switch(cmd) {
      case SD_SEND_CSD:
      case SD_SEND_CID:
        break;
      case SD_SEND_SCR:
      case SD_SEND_SD_STATUS:
        rsp = sd_raw_cmd(CMD55, 0);
        call HW.spi_get();          /* sandisk needs this */
        if (rsp & ~MSK_IDLE) {      /* 00 or 01 is fine, others not so much */
          call HW.sd_clr_cs();
          return rsp;;
        }
        break;
      default:
        call HW.spi_get();
        call HW.sd_clr_cs();
        return 0xff;
    }
    rsp = sd_raw_cmd(cmd, 0);
    if (rsp) {                  /* oops, bail */
      call HW.spi_get();
      call HW.sd_clr_cs();
      return rsp;
    }
    if (sd_get_block(buf, count)) {
      call HW.spi_get();
      call HW.sd_clr_cs();
      return 0xff;
    }
    call HW.spi_get();
    call HW.sd_clr_cs();
    return 0;
  }


  /*
   * sd_cmd8
   *
   * sends a CMD8 to poke the SD.  This potentially
   * turns on SDHC support.  We also check to make sure
   * proper voltages are supported.
   *
   * returns: SUCCESS   as expected
   *          FAIL      something didn't work
   */
  error_t sd_cmd8() {
    uint8_t ocr[4], rsp;

    call HW.sd_set_cs();
    rsp = sd_raw_cmd(CMD8, 0x1aa);
    if (rsp & ~MSK_IDLE) {      /* better be 0 */
      call HW.spi_get();
      call HW.sd_clr_cs();
      return SUCCESS;
    }
    ocr[0] = call HW.spi_get();
    ocr[1] = call HW.spi_get();
    ocr[2] = call HW.spi_get();
    ocr[3] = call HW.spi_get();
    call HW.spi_get();
    call HW.sd_clr_cs();
    if ((ocr[2] == 0x01) && (ocr[3] == 0xAA))
      return SUCCESS;
    return FAIL;
  }


  /*
   * sd_get_ocr
   *
   * Get the Operations Conditions Register
   */
  uint32_t sd_get_ocr() {
    uint32_t ocr;
    uint8_t *op;
    uint8_t  rsp;

    call HW.sd_set_cs();
    rsp = sd_raw_cmd(SD_SEND_OCR, 0);
    if (rsp) {                  /* better be 0 */
      call HW.spi_get();
      call HW.sd_clr_cs();
      return 0;
    }
    op = (uint8_t *) &ocr;
    op[3] = call HW.spi_get();  /* be to le */
    op[2] = call HW.spi_get();
    op[1] = call HW.spi_get();
    op[0] = call HW.spi_get();
    call HW.spi_get();
    call HW.sd_clr_cs();
    return ocr;
  }


  /************************************************************************
   *
   * Init
   *
   ***********************************************************************/

  command error_t SoftwareInit.init() {
    sdc.majik_a = SD_MAJIK;
    sdc.cur_cid = CID_NONE;
    sdc.majik_b = SD_MAJIK;
    return SUCCESS;
  }


  /*
   * sd_get_disk_params
   *
   * get certain critical disk parameters and stash in the state block
   *
   * First, we want to find out how many sectors this disk has. This
   * information is in the CSD.  SDSC uses a CSD v1, SDHC uses CSD v2.
   *
   * CSD ver is in the 1st 2 bits of csd[0].   csc[0] >> 6
   *  0: csd v1, SDSC
   *  1: csd v2, SDHC/SDXC
   *
   * SDSC, CSD v1
   *    rbl (read_bl_len): =  csd[5] & 0xf
   *    csm (c_size_mult)  = (csd[9} & 0x3) << 1 | (csd[10] & 0x80) >> 7
   *    csize = ((csd[6] & 0x03) << 10) | (csd[7] << 2) | (csd[8] >> 6)
   *
   *    n = rbl + csm + 2
   *
   *    capacity = (csize + 1) * 2 ^ n
   *    blocks = capacity/512
   *
   *    blocks = (csize + 1) * 2 ^ (n - 9)
   *
   * SDHC, CSD v2
   *    rbl is fixed at 2 ^ 9 = 512
   *    csize = ((csd[7] & 0x3f) << 16) | (csd[8] << 8) | csd[9]
   *
   *    capacity = (csize + 1) * 512KiB
   *    blocks   = (csize + 1) * 1024
   *
   * The SCR register contains "data_status_after_erase" which indicates
   * the state of the memory array after an erase.  We care for finding
   * empty blocks.
   *
   * The last thing we get is the OCR to see if we are SDHC.  CCS bit.
   */

  void sd_get_disk_params() {
    uint8_t buf[SD_CSD_LEN], rsp;
    uint32_t csize, rbl, csm;
    uint32_t ocr;

    if ((rsp = sd_get_vreg(buf, SD_SEND_CSD, SD_CSD_LEN)))
      sd_panic(99, rsp);                /* no return */

    if ((buf[0] >> 6) == 1) {
      /* CSDv2 */
      csize = (buf[7] & 0x3f) << 16 | (buf[8] << 8) | buf[9];
      sdc.blocks = (csize + 1) * 1024;
    } else {
      /* CSDv1 */
      rbl =  buf[5] & 0xf;
      csm = ((buf[9] & 0x3) << 1) | ((buf[10] & 0x80) >> 7);
      csize = ((buf[6] & 0x03) << 10) | (buf[7] << 2) | (buf[8] >> 6);
      sdc.blocks = (csize + 1) << (rbl + csm + 2 - 9);
    }

    if ((rsp = sd_get_vreg(buf, SD_SEND_SCR, SD_SCR_LEN)))
      sd_panic(99, rsp);                /* no return */

    sdc.erase_state = ((buf[1] & 0x80) ? 0xff : 0x00);

    ocr = sd_get_ocr();
    if (ocr & (1 << 30))
      sdc.sdhc = TRUE;
  }


  /************************************************************************
   *
   * Reset the SD card:  start the reset sequence.
   *
   * SPI SD initialization sequence:
   * CMD0 (reset), CMD8, CMD55 (app cmd), ACMD41 (app_send_op_cond)
   *
   * See SDsa for details on power up timing.  Power up and down is
   * handled by the ResourceDefaultOwner (in this module).  Invokation
   * is handled by the Arbiter.  SDsa handles its own power up and down.
   * There needs to be enough delay prior to SDreset.reset (according to
   * Simplified v5 we need 1ms before clocking)
   *
   * Power is turned on by the arbiter calling ResourceDefaultOwner.requested.
   * The reset sequence is started by clocking out bytes to clock the SD,
   * FORCE_IDLE is sent.  This drops CS while the command is sent which puts
   * the SD into SPI mode.  We then use a Timer to poll.  Each poll sends a
   * GO_OP to request operational mode.
   *
   * Once the SD indicates non-IDLE, we call ResourceDefaultOwner.release
   * to tell the arbiter to start granting.
   */

  void sd_start_reset(void) {
    uint8_t   rsp;
    unsigned int count;

    if (sdc.sd_state != SDS_OFF_TO_ON) {
      sd_panic_idle(36, sdc.sd_state);
      return;
    }

    op_t0_us = call Platform.usecsRaw();
    op_t0_ms = call lt.get();

    sdc.sd_state = SDS_RESET;
    sdc.cur_cid = CID_NONE;	        /* reset is not parameterized. */

    /*
     * Clock out at least 74 bits of idles (0xFF is 8 bits).  That's 10 bytes
     */

    call HW.spi_check_clean();
    call HW.sd_clr_cs();                        /* force to known state, no CS */
    call HW.sd_start_dma(NULL, NULL, 10);	/* send 10 0xff to clock SD */
    call HW.sd_wait_dma(10);

    count = 10;                 /* at most try 10 times  */
    last_pwr_on_first_cmd_us = call Platform.usecsRaw() - sd_pwr_on_time_us;
    while(count) {
      /* Put the card in the idle state, non-zero return  -> error
       *
       * CMD0, FORCE_IDLE, is a software reset
       */
      rsp = sd_send_command(SD_FORCE_IDLE, 0);
      if (rsp == 0x01)          /* IDLE pops us out */
        break;
      count--;
      if (count == 9) {
        sd_warn(37, rsp);       /* see if we ever see this. */
      }
    }
    if (rsp != 0x01) {		/* Must be in IDLE */
      sd_panic_idle(37, rsp);
      return;
    }

    /* poke the SD to turn on SDHC if present */
    if (sd_cmd8()) {
      sd_panic(100, 0);
    }

    /*
     * force the timer to go, which sends the first go_op.
     * eventually it will cause a resetDone to get sent.
     *
     * This switches us to the context that we want so the
     * signal for resetDone always comes from the same place.
     */
    sd_go_op_count = 0;		// Reset our counter for pending tries
    call SDtimer.startOneShot(0);
    return;
  }


  event void SDtimer.fired() {
    uint8_t   rsp;

    switch (sdc.sd_state) {
      default:
      case SDS_ERASE_BUSY:		/* these are various timeout states */
      case SDS_WRITE_BUSY:		/* the timer went off which shouldn't happen */
      case SDS_WRITE_DMA:
      case SDS_READ_DMA:
	w_t = call lt.get();
	w_diff = w_t - op_t0_ms;
	rsp = call HW.spi_get();
        if (sdc.sd_state == SDS_WRITE_DMA || sdc.sd_state == SDS_READ_DMA)
          call HW.sd_capture_dma_state();
	call Panic.panic(PANIC_SD, 38, sdc.sd_state, w_diff, 0, 0);
        /* no rtn */
	return;

      case SDS_OFF_TO_ON:
        sd_start_reset();
        return;

      case SDS_RESET:
        /* set HCS to see what happens */
	rsp = sd_send_acmd(SD_GO_OP, 1 << 30);
	if (rsp & ~MSK_IDLE) {		/* any other bits set? */
	  sd_panic_idle(39, rsp);
	  return;
	}

	if (rsp & MSK_IDLE) {
	  /* idle bit still set, means card is still in reset */
	  if (++sd_go_op_count >= SD_GO_OP_MAX) {
	    sd_panic_idle(40, sd_go_op_count);		/* We maxed the tries, panic and fail */
	    return;
	  }
	  call SDtimer.startOneShot(GO_OP_POLL_TIME);
	  return;
	}

	/*
	 * no longer idle, initialization was OK.
	 *
	 * If we were running with a reduced clock then this is the place to
	 * crank it up to full speed.  We do everything at full speed so there
	 * isn't currently any need.
         */
	last_reset_delta_us = call Platform.usecsRaw() - op_t0_us;
	if (last_reset_delta_us > max_reset_time_us)
	  max_reset_time_us = last_reset_delta_us;

	last_reset_delta_ms = call lt.get() - op_t0_ms;
	if (last_reset_delta_ms > max_reset_time_ms)
	  max_reset_time_ms = last_reset_delta_ms;

	last_full_reset_time_us = call Platform.usecsRaw() - sd_pwr_on_time_us;

        /*
         * if we haven't filled in the disk parameters, we have a little more
         * work to do.  This is indicated by sdc.blocks being 0.
         */
        if (sdc.blocks == 0)
          sd_get_disk_params();

        nop();
	sdc.sd_state = SDS_IDLE;
	sdc.cur_cid = CID_NONE;
        last_reset_start_time_us = 0;
        last_reset_start_time_ms = 0;
	call ResourceDefaultOwner.release();
        return;
    }
  }


  task void sd_pwr_up_task() {
    sd_pwr_on_time_us = call Platform.usecsRaw();
    call HW.sd_on();
    call HW.sd_spi_enable();

    /*
     * we want at least 1ms, Using 2 gives us approx 1.6ms as observed
     */
    call SDtimer.startOneShot(2);
  }


  /*
   * ResourceDefaultOwner.granted: power down the SD.
   *
   * reconfigure connections to the SD as input to avoid powering the chip
   * and power off.
   *
   * The HW.sd_off routine will put the i/o pins into a reasonable state to
   * avoid powering the SD chip and will kill power.  Also make sure that
   * the SPI module is held in reset.
   */

  async event void ResourceDefaultOwner.granted() {
    sdc.sd_state = SDS_OFF;
    sd_pwr_on_time_us = 0;
    call HW.sd_spi_disable();
    call HW.sd_off();
  }


  async event void ResourceDefaultOwner.requested() {
    if (sdc.sd_state != SDS_OFF) {
      sd_panic(41, 0);
    }
    last_reset_start_time_us = call Platform.usecsRaw();
    last_reset_start_time_ms = call lt.get();
    sdc.sd_state = SDS_OFF_TO_ON;
    post sd_pwr_up_task();
  }


  async event void ResourceDefaultOwner.immediateRequested() {
    sd_panic(42, 0);
  }


  /*
   * sd_check_crc
   *
   * i: data	pointer to a 512 byte buffer
   *    crc     crc to check against.
   *
   * o: rtn	0 (SUCCESS) if crc is okay
   *		1 (FAIL) crc didn't check.
   *
   * SD_BLOCKSIZE is the size of the buffer and the sector (512)
   */

  int sd_check_crc(uint8_t *data, uint16_t crc) {
    return SUCCESS;
  }


  /*
   * sd_compute_crc
   *
   * i: data	ptr to 512 bytes of data
   * o: returns 16 bit CRC.
   */

  uint16_t sd_compute_crc(uint8_t *data) {
    return 0x5512;
  }


  uint16_t sd_read_status() {
    uint8_t  rsp, stat_byte;

    call HW.sd_set_cs();
    rsp = sd_raw_cmd(SD_SEND_STATUS, 0);
    stat_byte = call HW.spi_get();
    call HW.spi_get();          /* sandisk needs this */
    call HW.sd_clr_cs();
    return ((rsp << 8) | stat_byte);
  }


  /************************************************************************
   *
   * Read
   *
   ***********************************************************************/

  task void sd_read_task() {
    uint8_t tmp;

    /* Wait for the token */
    sd_read_tok_count++;
    tmp = call HW.spi_get();			/* read a byte from the SD */

    if ((tmp & MSK_TOK_DATAERROR) == 0 || sd_read_tok_count >= SD_READ_TOK_MAX) {
      /* Clock out a byte before returning, let SD finish */
      call HW.spi_get();

      /* The card returned an error, or timed out. */
      call Panic.panic(PANIC_SD, 43, tmp, sd_read_tok_count, 0, 0); /* no return */
      return;
    }

    /*
     * if we haven't seen the token yet then try again.  We just repost
     * ourselves to try again.  This lets others run.  We've observed
     * that in a tight loop it takes about 30-110 loops before we saw the token,
     * between 300 us and 1.8ms.  Not enough to kick a timer off (ms granularity) but
     * long enough that we don't want to sit on the cpu.  YMMV depending on what
     * manufacture of  uSD card we are using.
     */
    if (tmp == 0xFF) {
      post sd_read_task();
      return;
    }

    if (tmp != SD_START_TOK) {
      call Panic.panic(PANIC_SD, 44, tmp, sd_read_tok_count, 0, 0);
    }

    /*
     * read the block (512 bytes).  Any crc (2 bytes) will be handled after the
     * dma completes.
     *
     * we fire up the dma, turn on a timer to do a timeout, and
     * enable the dma interrupt to generate a h/w event when complete.
     */
    sdc.sd_state = SDS_READ_DMA;
    call HW.spi_check_clean();
    call HW.sd_dma_enable_int();
    call HW.sd_start_dma(NULL, sdc.data_ptr, SD_BLOCKSIZE);
    call SDtimer.startOneShot(SD_SECTOR_XFER_TIMEOUT);
    return;
  }


  void sd_read_dma_handler() {
    uint16_t crc;
    uint8_t  cid, old_byte;

    cid = sdc.cur_cid;			/* remember for signalling */
    if (call HW.sd_dma_active())
      sd_panic(98, sdc.sd_state);
    call HW.sd_stop_dma();

    /*
     * crc should be next two bytes in.
     */
    crc = (call HW.spi_get() << 8) | call HW.spi_get();

    /* Send some extra clocks so the card can finish */
    call HW.spi_get();                  /* sandisk */
    call HW.sd_clr_cs();

    if (sd_check_crc(sdc.data_ptr, crc)) {
      sd_panic_idle(45, crc);           /* no return */
      return;
    }

    /*
     * sometimes.  not sure of the conditions.  When using dma
     * the first byte will show up as 0xfe (something having
     * to do with the cmd response).  Check for this and if seen
     * flag it and re-read the buffer.  We don't keep trying so it
     * had better work.
     *
     * Haven't seen this in a while pretty sure it got cleaned up when
     * we got a better handle on the transaction sequence of the SD.
     */
    if (sdc.data_ptr[0] == 0xfe) {
      old_byte = sdc.data_ptr[0];
      call SDsa.read(sdc.blk_start, sdc.data_ptr);
      if (sdc.data_ptr[0] != 0xfe)
        sd_warn(46, old_byte);
    }

    last_read_delta_us = call Platform.usecsRaw() - op_t0_us;
    if (last_read_delta_us > max_read_time_us)
      max_read_time_us = last_read_delta_us;

    last_read_delta_ms = call lt.get() - op_t0_ms;
    if (last_read_delta_ms > max_read_time_ms)
      max_read_time_ms = last_read_delta_ms;

    sdc.sd_state = SDS_IDLE;
    sdc.cur_cid = CID_NONE;
    signal SDread.readDone[cid](sdc.blk_start, sdc.data_ptr, SUCCESS);
  }


  /*
   * SDread.read: read a 512 byte block from the SD
   *
   * input:  blk_id        block to read.
   *         data          pointer to data buffer, assumed 514 bytes
   * output: rtn           0 call successful, err otherwise
   *
   * if the return is SUCCESS, it is guaranteed that a readDone event
   * will be signalled.
   */

  command error_t SDread.read[uint8_t cid](uint32_t blk_id, uint8_t *data) {
    uint8_t   rsp;

    if (sdc.sd_state != SDS_IDLE) {
      sd_panic_idle(47, sdc.sd_state);
      return EBUSY;
    }

    op_t0_us = call Platform.usecsRaw();
    op_t0_ms = call lt.get();

    sdc.sd_state = SDS_READ;
    sdc.cur_cid = cid;
    sdc.blk_start = blk_id;
    sdc.data_ptr = data;

    if (!sdc.sdhc)
      blk_id = blk_id << SD_BLOCKSIZE_NBITS;
    if ((rsp = sd_send_command(SD_READ_BLOCK, blk_id))) {
      sd_panic_idle(48, rsp);
      return FAIL;
    }

    /*
     * The SD card can take some time before it says continue.
     * We've seen upto 300-400 us before it says continue.
     * kick to a task to let other folks run.
     */
    call HW.sd_set_cs();		/* reassert to continue xfer */
    sd_read_tok_count = 0;
    post sd_read_task();
    return SUCCESS;
  }


  /************************************************************************
   *
   * Write
   *
   */

  task void sd_write_task() {
    uint16_t i;
    uint8_t  tmp;
    uint8_t  cid;

    /* card is busy writing the block.  ask if still busy. */

    tmp = call HW.spi_get();
    sd_write_busy_count++;
    if (tmp != 0xff) {			/* protected by timeout timer */
      post sd_write_task();
      return;
    }
    call SDtimer.stop();		/* write busy done, kill timeout timer */
    call HW.spi_get();                  /* extra clocking */
    call HW.sd_clr_cs();

    i = sd_read_status();
    if (i)
      sd_panic(49, i);

    last_write_delta_us = call Platform.usecsRaw() - op_t0_us;
    if (last_write_delta_us > max_write_time_us)
      max_write_time_us = last_write_delta_us;

    last_write_delta_ms = call lt.get() - op_t0_ms;
    if (last_write_delta_ms > max_write_time_ms)
      max_write_time_ms = last_write_delta_ms;

    if (last_write_delta_ms > SD_WRITE_WARN_THRESHOLD) {
      call Panic.warn(PANIC_SD, 50, sdc.blk_start, last_write_delta_ms, 0, 0);
      /* no return */
    }
    cid = sdc.cur_cid;
    sdc.sd_state = SDS_IDLE;
    sdc.cur_cid = CID_NONE;
    signal SDwrite.writeDone[cid](sdc.blk_start, sdc.data_ptr, SUCCESS);
  }


  void sd_write_dma_handler() {
    uint8_t  tmp;
    uint16_t i, crc;

    if (call HW.sd_dma_active())
      sd_panic(99, sdc.sd_state);
    call HW.sd_stop_dma();

    /* crc is the next two bytes out, big endian */
    crc = sd_compute_crc(sdc.data_ptr);
    call HW.spi_put((crc >> 8) & 0xff);
    call HW.spi_put(crc & 0xff);

    /*
     * After the data block is accepted the SD sends a data response token
     * that tells whether it accepted the block.  0x05 says all is good.
     */
    tmp = call HW.spi_get();
    if ((tmp & 0x1F) != 0x05) {
      i = sd_read_status();
      call Panic.panic(PANIC_SD, 51, tmp, i, 0, 0);     /* no return */
      return;
    }

    /*
     * the SD goes busy until the block is written.  (busy is data out low).
     * we poll using a task.
     *
     * We also start up a timeout timer to protect against hangs.
     */
    sd_write_busy_count = 0;
    sdc.sd_state = SDS_WRITE_BUSY;
    call SDtimer.startOneShot(SD_WRITE_BUSY_TIMEOUT);
    post sd_write_task();
  }


  command error_t SDwrite.write[uint8_t cid](uint32_t blk_id, uint8_t *data) {
    uint8_t   rsp;

    if (sdc.sd_state != SDS_IDLE) {
      sd_panic_idle(52, sdc.sd_state);
      return EBUSY;
    }

    op_t0_us = call Platform.usecsRaw();
    op_t0_ms = call lt.get();

    sdc.sd_state = SDS_WRITE;
    sdc.cur_cid = cid;
    sdc.blk_start = blk_id;
    sdc.data_ptr = data;

    if (!sdc.sdhc)
      blk_id = blk_id << SD_BLOCKSIZE_NBITS;
    if ((rsp = sd_send_command(SD_WRITE_BLOCK, blk_id))) {
      sd_panic_idle(53, rsp);
      return FAIL;
    }

    call HW.sd_set_cs();		/* reassert to continue xfer */

    /*
     * The SD needs a write token, send it first then fire
     * up the dma.
     */
    call HW.spi_put(SD_START_TOK);

    /*
     * send the sector data, crc bytes (2) will be sent after the
     * data is sent.
     *
     * start the dma, enable a time out to monitor the h/w
     * and enable the dma h/w interrupt to generate the h/w event.
     */
    sdc.sd_state = SDS_WRITE_DMA;
    call HW.spi_check_clean();
    call HW.sd_dma_enable_int();
    call HW.sd_start_dma(data, NULL, SD_BLOCKSIZE);
    call SDtimer.startOneShot(SD_SECTOR_XFER_TIMEOUT);
    return SUCCESS;
  }



  /************************************************************************
   *
   * SDerase.erase
   *
   */

  task void sd_erase_task() {
    uint8_t  tmp;
    uint8_t  cid;

    /*
     * card is busy erasing the block.  ask if still busy.
     */
    tmp = call HW.spi_get();
    sd_erase_busy_count++;
    if (tmp != 0xff) {			/* protected by timeout timer */
      post sd_erase_task();
      return;
    }
    call SDtimer.stop();		/* busy done, kill timeout */
    call HW.spi_get();                  /* extra clocks */
    call HW.sd_clr_cs();		/* deassert CS */

    last_erase_delta_us = call Platform.usecsRaw() - op_t0_us;
    if (last_erase_delta_us > max_erase_time_us)
      max_erase_time_us = last_erase_delta_us;

    last_erase_delta_ms = call lt.get() - op_t0_ms;
    if (last_erase_delta_ms > max_erase_time_ms)
      max_erase_time_ms = last_erase_delta_ms;

    cid = sdc.cur_cid;
    sdc.sd_state = SDS_IDLE;
    sdc.cur_cid = CID_NONE;
    signal SDerase.eraseDone[cid](sdc.blk_start, sdc.blk_end, SUCCESS);
  }


  command error_t SDerase.erase[uint8_t cid](uint32_t blk_s, uint32_t blk_e) {
    uint8_t   rsp;

    if (sdc.sd_state != SDS_IDLE) {
      sd_panic_idle(54, sdc.sd_state);
      return EBUSY;
    }

    op_t0_us = call Platform.usecsRaw();
    op_t0_ms = call lt.get();

    sdc.sd_state = SDS_ERASE;
    sdc.cur_cid = cid;
    sdc.blk_start = blk_s;
    sdc.blk_end = blk_e;

    /*
     * send the start and then the end
     */
    if (!sdc.sdhc) {
      blk_s = blk_s << SD_BLOCKSIZE_NBITS;
      blk_e = blk_e << SD_BLOCKSIZE_NBITS;
    }
    if ((rsp = sd_send_command(SD_SET_ERASE_START, blk_s))) {
      sd_panic_idle(55, rsp);
      return FAIL;
    }

    if ((rsp = sd_send_command(SD_SET_ERASE_END, blk_e))) {
      sd_panic_idle(56, rsp);
      return FAIL;
    }

    if ((rsp = sd_send_command(SD_ERASE, 0))) {
      sd_panic_idle(57, rsp);
      return FAIL;
    }

    call HW.sd_set_cs();		/* reassert to continue xfer */

    sd_erase_busy_count = 0;
    sdc.sd_state = SDS_ERASE_BUSY;
    call SDtimer.startOneShot(SD_ERASE_BUSY_TIMEOUT);
    post sd_erase_task();
    return SUCCESS;
  }


  /*************************************************************************
   *
   * SDsa: standalone SD implementation, no split phase, no clients
   *
   * We run the SD in SPI mode.  This is accomplished by setting CSN (chip
   * select, low true) to 0 and sending the FORCE_IDLE command.
   *
   * Steps:
   *
   *    1) turn on the SD.
   *    2) Configure Spi h/w.
   *    3) need to wait the initilization delay, supply voltage builds
   *	   to bus master voltage.  doc says maximum of 1ms, 74 clocks
   *	   and supply ramp up time.  But unclear how long is the actual
   *	   minimum.
   *	4) send FORCE_IDLE.
   *    5) send CMD8 to tell the SD we are HC capable.
   *	6) Repeatedly send GO_OP (ACMD41) to take the SD out of idle (what
   *	   they call reset).
   *
   *************************************************************************/

  error_t sdsa_abort(error_t rtn) {
    call SDsa.off();
    return rtn;
  }


  /*
   * return TRUE if in standalone.
   *
   * Standalone code can panic.  provide a mechanism so panic can tell if
   * in standalone and special handling is needed.
   *
   * we have a majik number in the sdc (control block).  If this majik is
   * the SDSA_MAJIK then we are in standalone.
   */
  async command bool SDsa.inSA() {
    if (sdc.sdsa_majik == SDSA_MAJIK)
      return TRUE;
    return FALSE;
  }


  async command error_t SDsa.reset() {
    uint8_t      rsp;
    unsigned int sa_op_cnt;
    uint32_t     t0;

    sdc.sdsa_majik = SDSA_MAJIK;
    call HW.sd_on();
    call HW.sd_spi_enable();

    /*
     * we first need to wait for 1ms, then send > 74 clocks
     * 1100 is a kludge to get us at least 1ms.
     */
    t0 = call Platform.usecsRaw();
    while ((call Platform.usecsRaw() - t0) < 1100) ;
    call HW.spi_check_clean();
    call HW.sd_start_dma(NULL, NULL, 10);
    call HW.sd_wait_dma(10);

    sa_op_cnt = 10;
    while (sa_op_cnt) {
      rsp = sd_send_command(SD_FORCE_IDLE, 0);
      if (rsp == 0x01)          /* IDLE pops us out */
        break;
      sa_op_cnt--;
      if (sa_op_cnt == 9) {
        sd_warn(58, rsp);
      }
    }
    if (rsp != 0x01)            /* must be idle */
      return sdsa_abort(FAIL);

    /* poke the SD to turn on SDHC if present */
    if (sd_cmd8())
      return sdsa_abort(FAIL);

    /*
     * SD_GO_OP_MAX is set for normal operation which is polled every 4 or
     * so ms.  SA hits it in a tight loop, so we increase the max allowed
     * to be 8 times normal.  We have observed it takes 7 or so iterations
     * before going operational.
     */
    sa_op_cnt = 0;
    do {
      sa_op_cnt++;
      rsp = sd_send_acmd(SD_GO_OP, 1 << 30); /* tell HCS */
    } while ((rsp & MSK_IDLE) && (sa_op_cnt < (SD_GO_OP_MAX * 8)));

    if (rsp & MSK_IDLE)
      sd_panic(59, sa_op_cnt);
    if (sdc.blocks == 0)
      sd_get_disk_params();
    return SUCCESS;
  }


  async command void SDsa.off() {
    call HW.sd_spi_disable();
    call HW.sd_off();
    sdc.sdsa_majik = 0;
  }


  async command void SDsa.read(uint32_t blk_id, uint8_t *buf) {
    uint8_t  rsp, tmp;
    uint16_t crc;

    (void) rsp;                         /* for looking a shit */

    /* send read data command */
    call HW.sd_set_cs();
    if (!sdc.sdhc)
      blk_id = blk_id << SD_BLOCKSIZE_NBITS;
    rsp = sd_raw_cmd(SD_READ_BLOCK, blk_id);

    sd_read_tok_count = 0;

    /* read till we get a start token or timeout */
    do {
      sd_read_tok_count++;
      tmp = call HW.spi_get();			/* looking for start token */

      if (((tmp & MSK_TOK_DATAERROR) == 0) ||
          (sd_read_tok_count >= SD_READ_TOK_MAX)) {
	call HW.spi_get();               /* let SD finish, clock one more */
        call Panic.panic(PANIC_SD, 60, tmp, sd_read_tok_count, 0, blk_id);
        return;
      }

      if (tmp != 0xFF)
	break;

    } while ((sd_read_tok_count < SD_READ_TOK_MAX) || (tmp == 0xFF));

    if (tmp != SD_START_TOK) {
      call Panic.panic(PANIC_SD, 61, tmp, sd_read_tok_count, 0, blk_id);
      return;
    }

    /*
     * read the block (512 bytes) and include the crc (2 bytes)
     * we fire up the dma, turn on a timer to do a timeout, and
     * enable the dma interrupt to generate a h/w event when complete.
     */
    call HW.spi_check_clean();
    call HW.sd_start_dma(NULL, buf, SD_BLOCKSIZE);
    call HW.sd_wait_dma(SD_BLOCKSIZE);

    /* next two bytes are the CRC, big endian */
    crc = (call HW.spi_get() << 8) | call HW.spi_get();

    call HW.spi_get();          /* more clocks to clear out SD */
    call HW.sd_clr_cs();        /* deassert the SD card */

    if (sd_check_crc(buf, crc)) {
      sd_panic(62, crc);
      return;
    }
  }


  async command void SDsa.write(uint32_t blk_id, uint8_t *buf) {
    uint8_t   rsp, tmp;
    uint16_t  t, last_time, time_wraps;
    uint16_t  crc;

    crc = sd_compute_crc(buf);
    if (!sdc.sdhc)
      blk_id = blk_id << SD_BLOCKSIZE_NBITS;
    if ((rsp = sd_send_command(SD_WRITE_BLOCK, blk_id)))
      sd_panic(63, rsp);                /* no return */

    call HW.sd_set_cs();
    call HW.spi_put(SD_START_TOK);
    call HW.spi_check_clean();
    call HW.sd_start_dma(buf, NULL, SD_BLOCKSIZE);
    call HW.sd_wait_dma(SD_BLOCKSIZE);

    /* next two bytes is the CRC */
    call HW.spi_put((crc >> 8) & 0xff);
    call HW.spi_put(crc & 0xff);

    /*
     * After the data block is accepted the SD sends a data response token
     * that tells whether it accepted the block.  0x05 says all is good.
     */
    tmp = call HW.spi_get();
    if ((tmp & 0x1F) != 0x05) {
      t = sd_read_status();
      call Panic.panic(PANIC_SD, 64, tmp, t, 0, blk_id);
      return;
    }

    /*
     * The SD can take a variable amount of time to do the actual write.
     * This depends upon the status of the block being written.   The SD
     * handles bad blocks automatically and the block in question can take
     * a while to write when it has started to go bad.  We have observed
     * anywhere from a nominal 3ms to > 120ms when the block is thinking
     * about going bad.
     *
     * We get usec raw time from Platform.usecsRaw().  We will timeout the
     * write if we wrap 6 times.  This gives us at least 5 full wraps which
     * is at least 5 * 64536 usecs (300+ ms).
     */
    last_time = call Platform.usecsRaw();
    time_wraps = 0;
    sd_write_busy_count = 0;

    /*
     * while busy writing, card is indicating busy, Data line low.  Wait until
     * we see one full byte of 1's to indicate not busy.
     */
    do {				/* count how many iterations and time */
      sd_write_busy_count++;
      tmp =  call HW.spi_get();
      if (tmp == 0xFF)
	break;

      if ((t = call Platform.usecsRaw()) < last_time) {
	if (++time_wraps > 6)
	  call Panic.panic(PANIC_SD, 65, time_wraps, t, blk_id, 0);
      }
      last_time = t;
    } while (1);

    call HW.spi_get();                  /* extra clocks */
    call HW.sd_clr_cs();		/* deassert. */
    t = sd_read_status();
    if (t)
      call Panic.panic(PANIC_SD, 66, tmp, t, blk_id, 0);
  }


  /*************************************************************************
   *
   * SDraw: raw interface to SD card from test programs.
   *
   *************************************************************************/

  command void SDraw.start_op() {
    call HW.sd_set_cs();
  }


  command void SDraw.end_op() {
    call HW.spi_get();
    call HW.sd_clr_cs();
  }


  command uint8_t SDraw.get() {
    return call HW.spi_get();
  }


  command void SDraw.put(uint8_t byte) {
    call HW.spi_put(byte);
  }


  /*
   * send the command, return response (R1) for the
   * command loaded into the command block.
   *
   * This is a complete op.
   */
  command uint8_t SDraw.send_cmd(uint8_t cmd, uint32_t arg) {
    return sd_send_command(cmd, arg);
  }


  /*
   * send the ACMD.
   *
   * CMD55 is sent first per protocol.  Then CMD/ARG are sent.
   *
   * This is NOT a complete op.  start_op and end_op have
   * to used to begin and end the SD op.
   */
  command uint8_t SDraw.raw_acmd(uint8_t cmd, uint32_t arg) {
    uint8_t rsp;

    rsp = sd_raw_cmd(CMD55, 0);
    call HW.spi_get();          /* sandisk needs this */
    if (rsp & MSK_IDLE)         /* 00 or 01 is fine, others not so much */
      return rsp;
    return sd_raw_cmd(cmd, arg);
  }


  /*
   * send the CMD and ARG
   *
   * This is NOT a complete op.  start_op and end_op have
   * to used to begin and end the SD op.
   */
  command uint8_t SDraw.raw_cmd(uint8_t cmd, uint32_t arg) {
    return sd_raw_cmd(cmd, arg);
  }


  command void SDraw.send_recv(uint8_t *tx, uint8_t *rx, uint16_t len) {
    call HW.spi_check_clean();
    call HW.sd_start_dma(tx, rx, len);
    call HW.sd_wait_dma(len);
  }


  /*************************************************************************
   *
   * SDraw.blocks: return number of blocks/sectors on this SD
   *
   * if sdc.blocks is 0, we haven't been initialized.
   */
  async command uint32_t SDraw.blocks() {
    return sdc.blocks;
  }


  /*
   * SDraw.erase_state: return indicator of erased state
   *
   * 0xff:      card is erased to 0xff
   * 0x00:      card is erased to 0x00
   *
   * sdc.blocks will be non-zero if we've gotten the disks parms
   */
  async command uint8_t SDraw.erase_state() {
    return sdc.erase_state;
  }


  /*
   * chk_buffer
   * checks an sd buffer for the val passed in.
   *
   * assumes quad-byte aligned.
   *
   * if tail is not quad even, then we have to adjust the
   * last reference.    19-18-17-16, len 3, we want 0x00FFFFFF
   *
   * return: TRUE    if buffer is set to val
   *         FALSE   otherwise
   */
  bool chk_buffer(uint8_t *sd_buf, uint8_t val) {
    uint32_t *p, len, chk, mask;

    len = SD_BLOCKSIZE;
    chk = val << 24 | val << 16 | val << 8 | val;
    p = (void *) sd_buf;
    while (len > 3) {
      if ((*p++) != chk) return FALSE;
      len -= 4;
      if (len < 4)
        break;
    }
    if (!len) return TRUE;
    mask = (0xffffffff >> ((4 - len) * 8));
    chk  &= mask;
    if ((*p & mask) == chk)
      return TRUE;
    return FALSE;
  }


  /*
   * SDraw.chk_zero
   * check for a zero buffer.
   *
   * assumes quad-byte aligned.
   *
   * async because this gets called from Panic.  interrupt safe.
   */
  async command bool SDraw.chk_zero(uint8_t *sd_buf) {
    return chk_buffer(sd_buf, 0);
  }


  /*
   * SDraw.chk_erased
   * checks an sd buffer for the erased condition.
   *
   * We are looking for SD sectors that are erased.  We read the sector
   * into a buffer and use chk_erased to see if it is the erased value.
   * see sdc.erase_state.
   *
   * assumes quad-byte aligned.
   */
  async command bool SDraw.chk_erased(uint8_t *sd_buf) {
    return chk_buffer(sd_buf, sdc.erase_state);
  }


  /*
   * SDraw.zero_fill - fill a SD buffer with zeros
   *
   * input: sd_buf   a buffer assumed to be one sector long
   *        offset   where in the buffer to start zero filling
   *
   * async because called from Panic.  interrupt safe.
   */
  async command bool SDraw.zero_fill(uint8_t *sd_buf, uint32_t offset) {
    uint8_t *p;

    if (offset >= SD_BLOCKSIZE) {
      return FALSE;
    }
    p = (uint8_t *) sd_buf + offset;
    while(p < (uint8_t *)(sd_buf + SD_BLOCKSIZE)) {
      *p++ = 0;
    } return TRUE;
  }


  /*
   * SDraw.ocr, return the OCR (Operations Conditions Register)
   *
   * The OCR is 32 bits long (4 bytes).
   *
   * This only works if the card has been powered up and currently is
   * IDLE (not busy).
   */
  command uint32_t  SDraw.ocr() {
    if (sdc.sdsa_majik == SDSA_MAJIK || sdc.sd_state == SDS_IDLE)
      return sd_get_ocr();
    return 0;
  }


  /*
   * SDraw.cid, return the CID (Card Identification Register)
   *
   * The CID is 128 bits long (16 bytes).  The buf pointer is
   * assumed to be long enough to hold the entire register.
   *
   * This only works if the card has been powered up and currently is
   * IDLE (not busy) or in StandAlone.
   */
  command error_t   SDraw.cid(uint8_t *buf) {
    uint8_t rsp;

    if (sdc.sdsa_majik == SDSA_MAJIK || sdc.sd_state == SDS_IDLE)
      return sd_get_vreg(buf, SD_SEND_CID, SD_CID_LEN);
    return FAIL;
  }


  /*
   * SDraw.csd   return the Card Specific Data
   *
   * The CSD is 128 bits long (16 bytes + 2 CRC).  The buf pointer is
   * assumed to be long enough to hold the entire register.
   *
   * This only works if the card has been powered up and currently is
   * IDLE (not busy).  Our state, not the cards IDLE which means reset.
   * StandAlone also works.
   */
  command error_t   SDraw.csd(uint8_t *buf) {
    error_t err;

    if (sdc.sdsa_majik == SDSA_MAJIK || sdc.sd_state == SDS_IDLE)
      return sd_get_vreg(buf, SD_SEND_CSD, SD_CSD_LEN);
    return FAIL;
  }


  /*
   * SDraw.scr, return the SCR (SD Configuration Register)
   *
   * The SCR is 64 bits long (8 bytes, SD_SCR_LEN, includes 2 bytes of CRC).
   * "buf" is assumed to be long enough to hold the entire register.
   *
   * This only works if the card has been powered up and currently is
   * IDLE (not busy) or in StandAlone.
   */
  command error_t   SDraw.scr(uint8_t *buf) {
    if (sdc.sdsa_majik == SDSA_MAJIK || sdc.sd_state == SDS_IDLE)
      return sd_get_vreg(buf, SD_SEND_SCR, SD_SCR_LEN);
    return FAIL;
  }


  /*************************************************************************
   *
   * DMA interaction
   *
   *************************************************************************/

  task void dma_task() {
    call SDtimer.stop();
    switch (sdc.sd_state) {
      case SDS_READ_DMA:
	sd_read_dma_handler();
	break;

      case SDS_WRITE_DMA:
	sd_write_dma_handler();
	break;

      default:
	sd_panic(67, sdc.sd_state);
	break;
    }
  }


  async event void HW.sd_dma_interrupt() {
    call HW.sd_dma_disable_int();
    post dma_task();
  }


  default event void   SDread.readDone[uint8_t cid](uint32_t blk_id, uint8_t *buf, error_t error) {
    sd_panic(68, cid);
  }


  default event void SDwrite.writeDone[uint8_t cid](uint32_t blk, uint8_t *buf, error_t error) {
    sd_panic(69, cid);
  }


  default event void SDerase.eraseDone[uint8_t cid](uint32_t blk_start, uint32_t blk_end, error_t error) {
    sd_panic(70, cid);
  }

  async event void Panic.hook() { }
}
