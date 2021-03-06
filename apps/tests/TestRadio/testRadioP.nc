/*
 * Copyright (c) 2015 Eric B. Decker
 * All rights reserved.
 */


#include <Tasklet.h>

#ifndef PACKED
#define PACKED __attribute__((__packed__))
#endif

uint32_t gt0, gt1;
uint16_t tt0, tt1;

uint16_t global_node_id = 42;

module testRadioP {
  provides {
    interface Init;
  } uses {
    interface Boot;

    interface Timer<TMilli> as rcTimer;
    interface Timer<TMilli> as txTimer;
    interface LocalTime<TMilli>;

    interface Leds;
    interface Panic;
    interface Random;

    interface RadioState;
    interface RadioPacket;
    interface RadioSend;
    interface RadioReceive;
  }
}

implementation {

  uint16_t        test_iterations, test_tx_errors, test_rx_errors, test_tx_busy;
  uint16_t        transmit_iterations, receive_iterations;
  uint16_t        iteration_modulo;
  uint32_t        wait_time, tx_time;
  uint8_t         active_mode;

  typedef enum {
    DISABLED = 0,
    RUN  = 1,
    PEND = 2,
    PING = 3,
    PONG = 4,
    REP  = 5,
  } test_mode_t;

  /*
   * radio state info
   */
  typedef enum {
    OFF = 0,
    STARTING,
    ACTIVE,
    STOPPING,
    STANDBY,
  } radio_state_t;

  norace radio_state_t radio_state;

  typedef struct test_msg {
    uint8_t       len;
    uint8_t       seq;
    uint8_t       pa;
    uint8_t       rssi;
    uint16_t      addr;
    test_mode_t   mode;
    uint8_t       data[0];
  } PACKED test_msg_t;

  #define MSG_BUF_SIZE 256
  volatile uint8_t  txMsgBuffer[MSG_BUF_SIZE];
//    =   {"\x72\x1\x1\x1\x1\x1\x1\x1 123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345!789012345!128"};
//  012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789
//            1         2         3         4         5         6         7         8         9         0         1         2

  message_t       * pTosTxMsg = (message_t *) txMsgBuffer;
  test_msg_t      * pTxMsg = (test_msg_t *) txMsgBuffer;
  volatile uint8_t  pgMsgBuffer[256];
  message_t       * pTosPgMsg = (message_t *) pgMsgBuffer;
  test_msg_t      * pPgMsg = (test_msg_t *) pgMsgBuffer;

  typedef struct {
    uint16_t        iterations;
    uint16_t        starts;
    uint16_t        errors;
    error_t         last_error;
    uint16_t        delay;
    uint16_t        off_delay;
    uint16_t        stby_delay;
    uint16_t        off_modulo;
    uint16_t        stby_modulo;
    uint16_t        addr;
  } rc_t;

  norace rc_t     rc = {0,0,0,0,1000,2000,2000,60,11};
  // rc.delay   = 1000;        // set timeout between radio checks
  // rc.stby_delay = 2000;     // set timeout to wait in off mode
  // rc.off_delay = 2000;      // set timeout to wait in standby mode
  // rc.off_modulo  = 60;      // power cycle radio after every nth check
  // rc.stby_modulo = 11;      // standby power radio after every nth check
  // rc.addr    = TOS_NODE_ID;

  typedef struct {
    uint32_t        iterations;
    uint16_t        delay;
    error_t         last_error;
    uint16_t        errors;
    uint16_t        pingerrors;
    uint16_t        busy;
    uint8_t         size;
    test_mode_t     mode;
    bool            waiting_to_send;
    bool            paused;
  } tx_t;

  norace tx_t       tx = {0,1000,0,0,0,0,128,RUN,0,0};
  // tx.mode    = RUN;         // enable transmission
  // tx.delay   = 1000;         // set timeout between transmssions
  // tx.size    = 128

  typedef struct {
    uint32_t        iterations;
    uint16_t        errors;
    error_t         last_error;
    uint16_t        pongerrors;
    test_mode_t     mode;
  } rx_t;

  norace rx_t     rx = {0,0,0,0,RUN};
  // rx.mode    = RUN;         // enable reception

  typedef struct {
    uint32_t        iterations;
    uint16_t        errors;
    uint16_t        last_error;
    test_mode_t     mode;
    bool            waiting_to_send;
  } pg_t;

  norace pg_t     pg;

  /*
   * packet test transmission is controlled by timer interrupt.
   *
   */
  void tx_start() {
    if (call txTimer.isRunning()) {
      call txTimer.stop();
    }
    if (tx.mode) {
      if (tx.mode == PONG)
	tx.mode = PING;
      tx.waiting_to_send = FALSE;
      pg.mode = PING;
      pg.waiting_to_send = FALSE;
      call txTimer.startPeriodic(tx.delay);
    }
    tx.paused = FALSE;
    tx.waiting_to_send = FALSE;
  }

  void tx_stop() {
    call txTimer.stop();
    tx.paused = TRUE;
  }

  task void tx_task() {
    error_t     error;
    nop();
    nop();
    if ((tx.mode == DISABLED) || tx.paused) {
      return;
    }
    if ((tx.mode == RUN) || (tx.mode == PING)) {
      pTxMsg->addr = rc.addr;
      pTxMsg->mode = tx.mode;
      pTxMsg->seq = (uint8_t) ++tx.iterations;
      pTxMsg->len = tx.size;
      error = call RadioSend.send(pTosTxMsg);
    } else if (pg.mode == PONG) {
      error = call RadioSend.send(pTosPgMsg);
    } else {
      return;
    }
    switch (error) {
    case SUCCESS:
      if (tx.mode == RUN) {                     // wait for timer to repeat sending run msg
	tx.mode = PEND;
      } else if (tx.mode == PING) {             // wait for timer to repeat sending ping msg
	tx.mode = PONG;
      } else if (pg.mode == PONG) {             // wait to receive another ping msg
	pg.mode = PING;
      }
      call Leds.led0Toggle();
      return;
    case EALREADY:
    case EBUSY:
      nop();
      if (tx.mode == PEND) {
	tx.mode = RUN;
      } else if (tx.mode == PONG) {
	tx.mode = PING;
      }
      tx.waiting_to_send = TRUE;                // request earliest opportunity to re-send
      tx.busy++;
      break;
    default:
      call Panic.panic(-1, 4, radio_state, error, tx.errors, tx.iterations);
      tx.last_error = error;
      tx.errors++;
      break;
    }
    if (tx.mode == PING) {
      tx.mode = PONG;
    } else if (tx.mode == PONG) {
      tx.errors++;
      tx.mode = PING;
    }
    call txTimer.startOneShot(tx.delay);
  }

  event void txTimer.fired() {
    nop();
    nop();
    if ((tx.mode == DISABLED) || tx.paused) {
      return;
    }
    if (tx.mode == PEND) {
      tx.mode = RUN;
    } else if (tx.mode == PONG) {
      tx.mode = PING;
    }
    post tx_task();
  }

  void tx_check_waiting() {
    if (tx.waiting_to_send) {
      tx.waiting_to_send = FALSE;
      post tx_task();
    }
  }

  tasklet_async event void RadioSend.ready() {
    nop();
    if (!(tx.mode == DISABLED))
      tx_check_waiting();
  }

  tasklet_async event void RadioSend.sendDone(error_t error) {
    nop();
    if (tx.mode == DISABLED) {
      return;
    }
    if (error) {
      tx.last_error = error;
      tx.errors++;
    }
    tx_check_waiting();
  }

  /*
   * packet test reception is handled by event callback
   *
   */
  void rx_start() {
    nop();
    // initialize state variables
  }

  void rx_stop() {
    nop();
  }

  tasklet_async event message_t* RadioReceive.receive(message_t *msg) {
    test_msg_t          * pm;
    nop();
    nop();
    if (rx.mode == RUN) {
      pm = (test_msg_t *) msg;
      if ((pm->addr == rc.addr) || (pm->addr == global_node_id)) {
	if ((pm->mode == PONG) && (tx.mode == PONG)) {  // response to our ping
	  if (pm->seq != tx.iterations)
	    tx.pingerrors++;
	  tx.mode = PING;
	} else {
	  if (pm->addr != global_node_id) {   // ignore messages with default addr
	    rx.errors++;             // shouldn't get other msg types with my addr
	  }
	}
      } else {
	// ping msg from other addr, copy msg send pong back
	if ((pm->mode == PING) && (pg.mode == PING)) {
	  memcpy((void *) pPgMsg, (void *) pm, pm->len + 1);
	  pPgMsg->mode = PONG;
	  pg.mode = PONG;
	  pg.iterations++;
	  post tx_task();
	}
      }
      rx.iterations++;
      call Leds.led1Toggle();
      tx_check_waiting();
    }
    return msg;
  }

  tasklet_async event bool RadioReceive.header(message_t *msg) {
    nop();
    return TRUE;
  }

  /*
   * radio control state is cycled periodically through power cycle
   *
   */

  void task rc_task() {
    nop();
    nop();
    switch(radio_state) {
    case STARTING:
      call Leds.led0On();
      call Leds.led1On();
      call Leds.led2On();
      radio_state = ACTIVE;
      rx_start();
      tx_start();
      call rcTimer.startOneShot(rc.delay);
      break;
    case STOPPING:
      call Leds.led0Off();
      call Leds.led1Off();
      call Leds.led2Off();
      radio_state = OFF;
      call rcTimer.startOneShot(rc.off_delay);
      break;
    case STANDBY:
      call rcTimer.startOneShot(rc.stby_delay);
      break;
    default:
      nop();
      call Panic.panic(-1, 1, radio_state, 0, 0, 0);
      radio_state = OFF;
      call rcTimer.startOneShot(rc.delay);
      break;
    }
  }

  async event void RadioState.done() {
    nop();
    nop();
    post rc_task();
  }

  event void rcTimer.fired() {
    error_t      error;
    nop();
    nop();
    switch(radio_state) {
    case OFF:
    case STANDBY:
      nop();
      error = call RadioState.turnOn();
      if (error == 0) {
	radio_state = STARTING;
	rc.starts++;
	call Leds.led0Off();
	call Leds.led1Off();
	call Leds.led2Off();
	break;
      } else {
	rc.last_error = error;
	rc.errors++;
	call rcTimer.startOneShot(rc.delay);
      }
      break;
    case ACTIVE:
      nop();
      if ((++rc.iterations % rc.off_modulo) == 0) {
	error = call RadioState.turnOff();
	if (error == 0) {
	  radio_state = STOPPING;
	  call Leds.led0On();
	  call Leds.led1On();
	  call Leds.led2On();
	  tx_stop();
	  rx_stop();
	  break;
	} else {
	  rc.last_error = error;
	  rc.errors++;
	  call rcTimer.startOneShot(rc.delay);
	}
      } else if ((rc.iterations % rc.stby_modulo) == 0) {
	error = call RadioState.standby();
	if (error == 0) {
	  radio_state = STANDBY;
	  call Leds.led0Off();
	  call Leds.led1On();
	  call Leds.led2On();
	  tx_stop();
	  rx_stop();
	} else {
	  rc.last_error = error;
	  rc.errors++;
	  call rcTimer.startOneShot(rc.delay);
	}
      } else {
	call rcTimer.startOneShot(rc.delay);
      }
      break;
    default:
      nop();
      call Panic.panic(-1, 3, radio_state, 0, 0, 0);
      radio_state = OFF;
      call rcTimer.startOneShot(rc.delay);
      break;
    }
  }


  /*
   * operating system hooks
   */
  command error_t Init.init() {
    return SUCCESS;
  }

  event void Boot.booted() {
    uint32_t   x;

    nop();
    nop();
    rc.addr    = TOS_NODE_ID;
    for (x = 0; x < MSG_BUF_SIZE; x++) {
      txMsgBuffer[x] = x;
    }
    nop();
    call rcTimer.startOneShot(0);
  }


  async event void Panic.hook() { }
}
