/*
 * Copyright (c) 2008 Eric B. Decker
 * All rights reserved.
 *
 * @author Eric B. Decker (cire831@gmail.com)
 * @date 28 May 2008
 *
 * Handle an incoming SIRF binary byte stream assembling it into
 * protocol messages and then process the ones we are interested in.
 *
 * A single buffer is used which assumes that the processing occurs
 * fairly quickly.  In our case we copy the data over to the data
 * collector.
 *
 * There is room left at the front of the msg buffer to put the data
 * collector header.
 *
 * Since message collection happens at interrupt level (async) and
 * data collection is a syncronous actvity provisions must be made
 * for handing the message off to task level.  While this is occuring
 * it is possible for additional bytes to arrive at interrupt level.
 * We handle this but using an overflow buffer.  When the task finishes
 * with the current message then it will flush the overflow buffer
 * back through the state machine to handle the characters.  It is
 * assumed that only a smaller number of bytes will need to be handled
 * this way and will be at most smaller than one packet.
 */

#include "panic.h"
#include "sd_blocks.h"
#include "sirf.h"

/*
 * GPS Message Collector level states.  Where in the message is the state machine
 */
typedef enum {
  COLLECT_START = 1,
  COLLECT_START_2,
  COLLECT_LEN,
  COLLECT_LEN_2,
  COLLECT_PAYLOAD,
  COLLECT_CHK,
  COLLECT_CHK_2,
  COLLECT_END,
  COLLECT_END_2,
} collect_state_t;


module GPSMsgP {
  provides {
    interface Init;
    interface StdControl as GPSMsgControl;
    interface GPSMsg;
  }
  uses {
    interface Collect;
    interface Panic;
    interface LocalTime<TMilli>;
    interface SplitControl as GPSControl;
    interface Surface;
  }
}

implementation {

  /*
   * collect_length is listed as norace.  The main state machine cycles and
   * references collect_length.  When a message is completed, on_overflow is set
   * which locks out the state machine and prevents collect_length from getting
   * changed out from underneath us.
   */

  collect_state_t collect_state;		// message collection state
  norace uint16_t collect_length;		// length of payload
  uint16_t        collect_cur_chksum;	// running chksum of payload

#define GPS_OVR_SIZE 16

  uint8_t  collect_msg[GPS_BUF_SIZE];
  uint8_t  collect_overflow[GPS_OVR_SIZE];
  uint8_t  collect_nxt;		        // where we are in the buffer
  uint8_t  collect_left;			// working copy
  bool     on_overflow;

  /*
   * Error counters
   */
  uint16_t collect_overflow_full;
  uint8_t  collect_overflow_max;
  uint16_t collect_too_big;
  uint16_t collect_chksum_fail;
  uint16_t collect_proto_fail;


  task void gps_msg_control_task() {
    call GPSControl.start();
  }

  event void GPSControl.startDone(error_t err) {
    nop();
  }

  event void GPSControl.stopDone(error_t err) {
    nop();
  }


  event void Surface.surfaced() {
    nop();
  }

  event void Surface.submerged() {
    nop();
  }


  task void gps_msg_task() {
    dt_gps_raw_nt *gdp;
    uint8_t i, max;

    gdp = (dt_gps_raw_nt *) collect_msg;
    gdp->len = DT_HDR_SIZE_GPS_RAW + SIRF_OVERHEAD + collect_length;
    gdp->dtype = DT_GPS_RAW;
    gdp->chip  = CHIP_GPS_SIRF3;
    gdp->stamp_mis = call LocalTime.get();
    call Collect.collect(collect_msg, gdp->len);
    atomic {
      /*
       * note: collect_nxt gets reset on first call to GPSMsg.byte_avail()
       * The only way to be here is if gps_msg_task has been posted which
       * means that on_overflow is true.  We simply need to look at collect_nxt
       * which will be > 0 if we have something that needs to be drained.
       */
      max = collect_nxt;
      on_overflow = FALSE;
      for (i = 0; i < max; i++)
	call GPSMsg.byteAvail(collect_overflow[i]); // BRK_GPS_OVR
      collect_overflow[0] = 0;
    }
    nop();
  }


  command error_t GPSMsgControl.start() {
    atomic {
      collect_state = COLLECT_START;
      on_overflow = FALSE;
      collect_overflow[0] = 0;
      return SUCCESS;
    }
  }


  command error_t GPSMsgControl.stop() {
    nop();
    return SUCCESS;
  }


  command error_t Init.init() {
    collect_overflow_full = 0;
    collect_overflow_max  = 0;
    collect_too_big = 0;
    collect_chksum_fail = 0;
    collect_proto_fail = 0;
    memset(collect_msg, 0, sizeof(collect_msg));
    call GPSMsgControl.start();
    return SUCCESS;
  }


  command void GPSMsg.reset() {
    call GPSMsgControl.start();
  }


  inline void collect_restart() {
    collect_state = COLLECT_START;
    signal GPSMsg.msgBoundary();
  }


  async command void GPSMsg.byteAvail(uint8_t byte) {
    uint16_t chksum;

    if (on_overflow) {		// BRK_GOT_CHR
      if (collect_nxt >= GPS_OVR_SIZE) {
	/*
	 * full, throw them all away.
	 */
	collect_nxt = 0;
	collect_overflow[0] = 0;
	collect_overflow_full++;
	return;
      }
      collect_overflow[collect_nxt++] = byte;
      if (collect_nxt > collect_overflow_max)
	collect_overflow_max = collect_nxt;
      return;
    }

    switch(collect_state) {
      case COLLECT_START:
	if (byte != SIRF_BIN_START)
	  return;
	collect_nxt = GPS_START_OFFSET;
	collect_msg[collect_nxt++] = byte;
	collect_state = COLLECT_START_2;
	return;

      case COLLECT_START_2:
	if (byte == SIRF_BIN_START)		// got start again.  stay
	  return;
	if (byte != SIRF_BIN_START_2) {		// not what we want.  restart
	  collect_restart();
	  return;
	}
	collect_msg[collect_nxt++] = byte;
	collect_state = COLLECT_LEN;
	return;

      case COLLECT_LEN:
	collect_length = byte << 8;		// data fields are big endian
	collect_msg[collect_nxt++] = byte;
	collect_state = COLLECT_LEN_2;
	return;

      case COLLECT_LEN_2:
	collect_length |= byte;
	collect_left = byte;
	collect_msg[collect_nxt++] = byte;
	collect_state = COLLECT_PAYLOAD;
	collect_cur_chksum = 0;
	if (collect_length >= (GPS_BUF_SIZE - GPS_OVERHEAD)) {
	  collect_too_big++;
	  collect_restart();
	  return;
	}
	return;

      case COLLECT_PAYLOAD:
	collect_msg[collect_nxt++] = byte;
	collect_cur_chksum += byte;
	collect_left--;
	if (collect_left == 0)
	  collect_state = COLLECT_CHK;
	return;

      case COLLECT_CHK:
	collect_msg[collect_nxt++] = byte;
	collect_state = COLLECT_CHK_2;
	return;

      case COLLECT_CHK_2:
	collect_msg[collect_nxt++] = byte;
	chksum = collect_msg[collect_nxt - 2] << 8 | byte;
	if (chksum != collect_cur_chksum) {
	  collect_chksum_fail++;
	  collect_restart();
	  return;
	}
	collect_state = COLLECT_END;
	return;

      case COLLECT_END:
	collect_msg[collect_nxt++] = byte;
	if (byte != SIRF_BIN_END) {
	  collect_proto_fail++;
	  collect_restart();
	  return;
	}
	collect_state = COLLECT_END_2;
	return;

      case COLLECT_END_2:
	collect_msg[collect_nxt++] = byte;
	if (byte != SIRF_BIN_END_2) {
	  collect_proto_fail++;
	  collect_restart();
	  return;
	}
	on_overflow = TRUE;
	collect_nxt = 0;
	collect_restart();
	post gps_msg_task();
	return;

      default:
	call Panic.panic(PANIC_GPS, 1, collect_state, 0, 0, 0);
	return;
    }
  }


  async command bool GPSMsg.atMsgBoundary() {
    atomic return (collect_state == COLLECT_START);
  }
}
