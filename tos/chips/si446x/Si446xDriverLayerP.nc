/*
 * Copyright (c) 2015, Eric B. Decker
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
 * Author: Eric B. Decker <cire831@gmail.com>
 */

/*
 * Basic interface:
 *
 * physical pins:NIRQ, CTS (gpio1), CSN (aka NSEL), SDN (shutdown)
 * spi pins: SCLK, MISO (SO), MOSI (SI).
 *
 * HplSi446xC provides the H/W Presentation which includes which SPI
 * to use and access routines for the above physical pins.
 *
 * Power States:
 *
 * h/w state    registers       transition      power
 *              preserved       to TX/RX        consumption
 *
 * Shutdown     n               15ms            30nA
 * Standby      y               440us           40nA
 * Sleep        y               440us           740nA
 * SPI Active   y               340us           1.35mA
 * Ready        y               100us           1.8mA
 * TX Tune      y               58us  -> TX     7.8mA
 * RX Tune      y               60us  -> RX     7.6mA
 * TX State     y               100uS -> RX     18mA @ +10dBm
 * RX State     y               100uS -> TX     10.9 or 13.7 mA
 *
 * This is a low power implementation.  We trade off a factor of 4 time
 * cost for 2 orders of magnitude power savings.  We want to spend
 * most of our time in Standby at 40 nA which costs 440uS to go into
 * a TX or RX state.
 *
 * When the radio chip is powered on, the following steps are taken:
 *
 * 1) Take chip out of shutdown, SDN = 0.
 *    (SDN 1 must be held for 10uS for proper shutdown, not a problem)
 *
 *    POR takes 6ms.  CTS (gp1 will go 1 at end of POR)
 *
 * 2) send POWER_UP command.
 *    POWER_UP takes something like 15ms.  We've measured it around 15.8ms
 *    and the timeout is set to 16.5ms.
 * 3) program h/w state.
 * 4) Chip goes to Standby state.
 *
 * This puts the driver into STANDBY s/w state (match h/w standby state).
 *
 * When we talk to the chip via SPI, the chip automatically transitions
 * to SPI Active state.  After talking to the chip, we must take care
 * to transition the chip back to Standby to take advantage of the low
 * current consumption.
 *
 * 
 * Basic Packet operations:
 *
 * The radio chip can actively be doing only one thing at a time, either
 * transmitting or receiving.  It is not Hear-Self.
 *
 * TX:
 *
 * 1) Transmit.   Single packet transmit only.  No pipeline support
 *    (another packet is not sent until the first has been signalled
 *    complete).   Only one packet may be in the TxFifo at a time.  If
 *    another TX attempt is made while a transmit is still active, it is
 *    rejected with EBUSY.
 *
 * 2) Typically, tx packets are ack'd and reception of the ack (rx cycle)
 *    must complete before the next packet gets transmitted.  This is
 *    because the ACK is part of the Channel assignment.   ACK's don't
 *    do CCA but assume the channel is available.  The timing budget for
 *    the transmitted packet is supposed to include the time it takes for
 *    the ACK as well.  This sequencing is handled by the upper layers (not
 *    the driver).
 *
 * 3) Transmission begins by copying the MAC header down to the FIFO.
 *
 * 4) A START_TX is done.  (How is CCA done?)
 *
 * 5) It is possible that the transmission is deferred because the channel
 *    is busy.   This is detected by checking what state the chip is in via
 *    the Status byte or the TX_A signal.
 *
 * 6) Deferred TX packets may be tried again by the upper layer.  A deferred
 *    packet is indicated by an EBUSY return.
 *
 * 7) Timestamping.  If the transmission has started, the rising edge of SFD
 *    will indicate the start of the TX packet, TX status indicates that the
 *    timestamp corresponds to the TX packet.
 *
 *    (Still need to flesh out timestamping)
 *
 *
 * RX:
 *
 * 1) Normal chip state when on is RX and the chipset is waiting for an
 *    incoming frame.
 *
 * 2) The first indication that a receive is happening is a rising edge on
 *    SFD which indicates completion of SFD and start of FrameLength.  CCA
 *    will go low when the Preamble has started to be transmitted.  A
 *    timestamp is taken and RX status indicates the receive.
 *
 * 3) The rising RX_sfd transitions the state machine into RX_ACTIVE state.
 *
 * 4) The falling edge of SFD transitions to RX_ON.
 
 * 5) completion of the packet is indicated by a RX_FRM_DONE exception.  This
 *    causes the packet to be copied out of the RXFIFO and when complete a
 *    RadioReceive.receive signal is generated.
 *
 * Note: There can be multiple RX packets in the fifo and the RX_FRM_DONE
 * exception is a single indicator.  If it is cleared, it won't be asserted
 * again until a new frame is received.
 *
 *
 * Author: Eric B. Decker <cire831@gmail.com>
 */

#define SI446X_ATOMIC_SPI
#define SI446X_NO_ARB
#define SI446X_HW_CTS

#ifdef SI446X_ATOMIC_SPI
#define SI446X_ATOMIC     atomic
#else
#define SI446X_ATOMIC
#endif

#ifndef PANIC_RADIO

enum {
  __panic_radio = unique(UQ_PANIC_SUBSYS)
};

#define PANIC_RADIO __panic_radio
#endif

#include <Si446xDriverLayer.h>
#include <Tasklet.h>
#include <RadioAssert.h>
#include <TimeSyncMessageLayer.h>
#include <RadioConfig.h>
#include <si446x.h>

/* The following header file is generated by the SiLabs program (Wireless
   Development Suite, WDS3).
 */
#include <radio_config_si4463w.h>

/* max time we look for CTS to come back from command (us). The max we've
   observed is 95uS.  Power_Up however takes 15ms so we don't use this
   timeout with that command.
*/
#define SI446X_CTS_TIMEOUT 200

         norace bool    do_dump;        /* defaults to FALSE */
volatile norace uint8_t xirq, p1;

norace uint32_t mt0, mt1;
norace uint16_t ut0, ut1;


typedef struct {
  uint16_t              u_ts;;          /* microsec timestamp */
  uint32_t              m_ts;           /* milli timestamp */

  uint8_t               CTS_pin;
  uint8_t               IRQ_pin;
  uint8_t               SDN_pin;
  uint8_t               CSN_pin;
  uint8_t               ta0ccr3;
  uint8_t               ta0cctl3;

  si446x_part_info_t    part_info;
  si446x_func_info_t    func_info;
  si446x_gpio_cfg_t     gpio_cfg;

  uint8_t               rxfifocnt;      /* fifoinfo */
  uint8_t               txfifofree;

  si446x_ph_status_t    ph_status;
  si446x_modem_status_t modem_status;
  si446x_chip_status_t  chip_status;
  si446x_int_status_t   int_status;

  uint8_t               device_state;   /* request_device_state */
  uint8_t               channel;

  uint8_t               frr_a;
  uint8_t               frr_b;
  uint8_t               frr_c;
  uint8_t               frr_d;

  uint8_t               packet_info_len[2];

  /* properties */
  uint8_t               gr00_global[SI446X_GROUP00_SIZE];
  uint8_t               gr01_int[SI446X_GROUP01_SIZE];
  uint8_t               gr02_frr[SI446X_GROUP02_SIZE];
  uint8_t               gr10_preamble[SI446X_GROUP10_SIZE];
  uint8_t               gr11_sync[SI446X_GROUP11_SIZE];
  uint8_t               gr12_pkt[SI446X_GROUP12_SIZE];
  uint8_t               gr20_modem[SI446X_GROUP20_SIZE];
  uint8_t               gr21_modem[SI446X_GROUP21_SIZE];
  uint8_t               gr22_pa[SI446X_GROUP22_SIZE];
  uint8_t               gr23_synth[SI446X_GROUP23_SIZE];
  uint8_t               gr30_match[SI446X_GROUP30_SIZE];
  uint8_t               gr40_freq_ctl[SI446X_GROUP40_SIZE];
  uint8_t               gr50_hop[SI446X_GROUP50_SIZE];
  uint8_t               grF0_pti[SI446X_GROUPF0_SIZE];
} radio_dump_t;

typedef struct {
  uint8_t  group;
  uint8_t  length;
  uint8_t *where;
} dump_prop_desc_t;


norace radio_dump_t rd;
norace uint8_t      fifo[129];

norace si446x_chip_status_t chip0, chip1;

const dump_prop_desc_t dump_prop[] = {
  { 0x00, SI446X_GROUP00_SIZE, (void *) &rd.gr00_global },
  { 0x01, SI446X_GROUP01_SIZE, (void *) &rd.gr01_int },
  { 0x02, SI446X_GROUP02_SIZE, (void *) &rd.gr02_frr },
  { 0x10, SI446X_GROUP10_SIZE, (void *) &rd.gr10_preamble },
  { 0x11, SI446X_GROUP11_SIZE, (void *) &rd.gr11_sync },
  { 0x12, SI446X_GROUP12_SIZE, (void *) &rd.gr12_pkt },
  { 0x20, SI446X_GROUP20_SIZE, (void *) &rd.gr20_modem },
  { 0x21, SI446X_GROUP21_SIZE, (void *) &rd.gr21_modem },
  { 0x22, SI446X_GROUP22_SIZE, (void *) &rd.gr22_pa },
  { 0x23, SI446X_GROUP23_SIZE, (void *) &rd.gr23_synth },
  { 0x30, SI446X_GROUP30_SIZE, (void *) &rd.gr30_match },
  { 0x40, SI446X_GROUP40_SIZE, (void *) &rd.gr40_freq_ctl },
  { 0x50, SI446X_GROUP50_SIZE, (void *) &rd.gr50_hop },
  { 0xF0, SI446X_GROUPF0_SIZE, (void *) &rd.grF0_pti },
  { 0, 0, NULL },
};


/*
 * Configuration Parameters
 *
 * Two major classes.  The first is static and is generated
 * by the EZ Radio Pro program based on various input parameters.
 * We pull various RF_* values from that file.
 *
 * The second class are those parameters that are either h/w dependent
 * or are protocol/packet format dependent or are driver dependent.  These ar
 * called "local" properties.
 *
 * We need to platform encapsulate in some reasonable way any h/w
 * dependent issues.  Ie. how the gpio pins are assigned and used.
 * Later.
 */

typedef struct {
  uint8_t        size;
  const uint8_t *data;
} si446x_radio_config_t;


/* Static */
const uint8_t rf_global_xo_tune_2[]         = { RF_GLOBAL_XO_TUNE_2 };
const uint8_t rf_global_config_1[]          = { RF_GLOBAL_CONFIG_1 };
const uint8_t rf_preamble_tx_length_9[]     = { RF_PREAMBLE_TX_LENGTH_9 };
const uint8_t rf_sync_config_5[]            = { RF_SYNC_CONFIG_5 };
const uint8_t rf_modem_mod_type_12[]        = { RF_MODEM_MOD_TYPE_12 };
const uint8_t rf_modem_freq_dev_0_1[]       = { RF_MODEM_FREQ_DEV_0_1 };
const uint8_t rf_modem_tx_ramp_delay_8[]    = { RF_MODEM_TX_RAMP_DELAY_8 };
const uint8_t rf_modem_bcr_osr_1_9[]        = { RF_MODEM_BCR_OSR_1_9 };
const uint8_t rf_modem_afc_gear_7[]         = { RF_MODEM_AFC_GEAR_7 };
const uint8_t rf_modem_agc_control_1[]      = { RF_MODEM_AGC_CONTROL_1 };
const uint8_t rf_modem_agc_window_size_9[]  = { RF_MODEM_AGC_WINDOW_SIZE_9 };
const uint8_t rf_modem_ook_cnt1_9[]         = { RF_MODEM_OOK_CNT1_9 };
const uint8_t rf_modem_rssi_control_1[]     = { RF_MODEM_RSSI_CONTROL_1 };
const uint8_t rf_modem_rssi_comp_1[]        = { RF_MODEM_RSSI_COMP_1 };
const uint8_t rf_modem_clkgen_band_1[]      = { RF_MODEM_CLKGEN_BAND_1 };
const uint8_t rf_modem_chflt_rx1_chflt_coe13_7_0_12[] =
                { RF_MODEM_CHFLT_RX1_CHFLT_COE13_7_0_12 };
const uint8_t rf_modem_chflt_rx1_chflt_coe1_7_0_12[] =
                { RF_MODEM_CHFLT_RX1_CHFLT_COE1_7_0_12 };
const uint8_t rf_modem_chflt_rx2_chflt_coe7_7_0_12[] =
                { RF_MODEM_CHFLT_RX2_CHFLT_COE7_7_0_12 };
const uint8_t rf_pa_mode_4[]                = { RF_PA_MODE_4 };
const uint8_t rf_synth_pfdcp_cpff_7[]       = { RF_SYNTH_PFDCP_CPFF_7 };
const uint8_t rf_match_value_1_12[]         = { RF_MATCH_VALUE_1_12 };
const uint8_t rf_freq_control_inte_8[]      = { RF_FREQ_CONTROL_INTE_8 };

/* configuration generated by the WDS3 program */
const si446x_radio_config_t si446x_wds_config[] = {
  { sizeof(rf_global_xo_tune_2),    rf_global_xo_tune_2 },
  { sizeof(rf_global_config_1),     rf_global_config_1 },
  { sizeof(rf_preamble_tx_length_9),rf_preamble_tx_length_9 },
  { sizeof(rf_sync_config_5),       rf_sync_config_5 },
  { sizeof(rf_modem_mod_type_12),   rf_modem_mod_type_12 },
  { sizeof(rf_modem_freq_dev_0_1),  rf_modem_freq_dev_0_1 },
  { sizeof(rf_modem_tx_ramp_delay_8),rf_modem_tx_ramp_delay_8 },
  { sizeof(rf_modem_bcr_osr_1_9),   rf_modem_bcr_osr_1_9 },
  { sizeof(rf_modem_afc_gear_7),    rf_modem_afc_gear_7 },
  { sizeof(rf_modem_agc_control_1), rf_modem_agc_control_1 },
  { sizeof(rf_modem_agc_window_size_9),
                                    rf_modem_agc_window_size_9 },
  { sizeof(rf_modem_ook_cnt1_9),    rf_modem_ook_cnt1_9 },
  { sizeof(rf_modem_rssi_control_1),rf_modem_rssi_control_1 },
  { sizeof(rf_modem_rssi_comp_1),   rf_modem_rssi_comp_1 },
  { sizeof(rf_modem_clkgen_band_1), rf_modem_clkgen_band_1 },
  { sizeof(rf_modem_chflt_rx1_chflt_coe13_7_0_12),
                                    rf_modem_chflt_rx1_chflt_coe13_7_0_12 },
  { sizeof(rf_modem_chflt_rx1_chflt_coe1_7_0_12),
                                    rf_modem_chflt_rx1_chflt_coe1_7_0_12 },
  { sizeof(rf_modem_chflt_rx2_chflt_coe7_7_0_12),
                                    rf_modem_chflt_rx2_chflt_coe7_7_0_12 },
  { sizeof(rf_pa_mode_4),           rf_pa_mode_4 },
  { sizeof(rf_synth_pfdcp_cpff_7),  rf_synth_pfdcp_cpff_7 },
  { sizeof(rf_match_value_1_12),    rf_match_value_1_12 },
  { sizeof(rf_freq_control_inte_8), rf_freq_control_inte_8 },
  { 0,                              NULL }
};


const uint8_t test1[] = { 0x11, 0x00, 0x0c, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
const uint8_t test2[] = { 0x11, 0x01, 0x04, 0x00, 7, 0xbd, 0x08, 0x17 };


const uint8_t rf_gpio_pin_cfg[]     = { 0x13, 0x08, 0x08, 0x08, 0x08,
                                              0x08, 0x00, 0x00 };
const uint8_t rf_int_ctl_enable_1[] = { 0x11, 0x01, 0x01, 0x00, 0x00 };
const uint8_t rf_frr_ctl_a_mode_4[] = { 0x11, 0x02, 0x04, 0x00, 0x00,
                                              0x00, 0x00, 0x00 };
const uint8_t rf_pkt_crc_config_7[] = { 0x11, 0x12, 0x07, 0x00, 0x84, 0x01,
                                              0x08, 0xFF, 0xFF, 0x00, 0x02 };
const uint8_t rf_pkt_len_12[] = { 0x11, 0x12, 0x0C, 0x08, 0x2A, 0x01,
                                        0x00, 0x30, 0x30, 0x00, 0x01,
                                        0x04, 0x82, 0x00, 0x3F, 0x00 };
const uint8_t rf_pkt_field_2_crc_config_12[] =
  { 0x11, 0x12, 0x0C, 0x14, 0x2A, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
const uint8_t rf_pkt_field_5_crc_config_12[] =
  { 0x11, 0x12, 0x0C, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
const uint8_t rf_pkt_rx_field_3_crc_config_9[] =
  { 0x11, 0x12, 0x09, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00 };

/* local config, driver/hw dependent */
const si446x_radio_config_t si446x_local_config[] = {
  { sizeof(rf_gpio_pin_cfg),                rf_gpio_pin_cfg },
  { sizeof(rf_int_ctl_enable_1),            rf_int_ctl_enable_1 },
  { sizeof(rf_frr_ctl_a_mode_4),            rf_frr_ctl_a_mode_4 },
  { sizeof(rf_pkt_crc_config_7),            rf_pkt_crc_config_7 },
  { sizeof(rf_pkt_len_12),                  rf_pkt_len_12 },
  { sizeof(rf_pkt_field_2_crc_config_12),   rf_pkt_field_2_crc_config_12 },
  { sizeof(rf_pkt_field_5_crc_config_12),   rf_pkt_field_5_crc_config_12 },
  { sizeof(rf_pkt_rx_field_3_crc_config_9), rf_pkt_rx_field_3_crc_config_9 },
  { 0, NULL}
};


/* last CTS values, last command sent, xcts h/w, xcts_s spi */
volatile norace uint8_t xcts, xcts0, xcts_s;

typedef struct {
  si446x_ph_status_t    ph_status;
  si446x_modem_status_t modem_status;
  si446x_chip_status_t  chip_status;
  si446x_int_status_t   int_status;
} si446x_chip_int_t;

volatile norace si446x_chip_int_t chip_debug;
volatile norace si446x_chip_int_t int_state;

norace uint8_t      rsp[16];


/*
 * SFD timestamps
 */

typedef enum {
  SFD_UP   = 0x0001,
  SFD_DWN  = 0x0002,
  SFD_RX   = 0x0010,
  SFD_TX   = 0x0020,
  SFD_OVW  = 0x0100,
  SFD_BUSY = 0x8000,

  MAX_SFD_STAMPS = 8,
} sfd_status_t;


typedef struct {
  uint32_t local;                       /* rising edge   */
  uint16_t time_up;                     /* rising edge   */
  uint16_t time_down;                   /* falling edge  */
  uint32_t time_finish;                 /* frm_done time */
  uint16_t sfd_status;                  /* sfd_status_t, but hex */
} sfd_stamp_t;


/*
 * Note: The TX SFD entry could be a seperate entry since there can only
 * be one outstanding at a time.   But to avoid strange out of order effects,
 * ie. processing a transmitted packet that was transmitted after a RX packet
 * came in first.   Shouldn't ever happen since the chip is single duplex.
 *
 * But if we have a single SFDQueue that represents the actual time order that
 * packets have happened, then it isn't even an issue.
 *
 * sfd_lost is TRUE if the current set of sfd_stamps has seen an OVR
 * (overwritten), or if we have lost a time stamp for some other reason.
 * We assume they are all crap.
 */

norace bool sfd_lost;
norace uint8_t sfd_fill,   sfd_drain, sfd_entries;
               sfd_stamp_t sfd_stamps[MAX_SFD_STAMPS];
sfd_stamp_t * const sfd_ptrs[MAX_SFD_STAMPS] = {
  &sfd_stamps[0], &sfd_stamps[1], &sfd_stamps[2], &sfd_stamps[3],
  &sfd_stamps[4], &sfd_stamps[5], &sfd_stamps[6], &sfd_stamps[7]
};


/*
 * Instrumentation, error counters, etc.
 */

norace uint16_t si446x_inst_rx_overflows;
norace uint16_t si446x_inst_rx_toolarge;
norace uint16_t si446x_inst_rx_toosmall;
norace uint16_t si446x_inst_pkt_toolarge;
norace uint16_t si446x_inst_bad_crc;
norace uint16_t si446x_inst_sfd_overwrites;
norace uint16_t si446x_inst_nukes;
norace uint16_t si446x_inst_other;
norace uint16_t si446x_tx_startup_time_max;


typedef struct {
  uint8_t        reg_start;
  uint8_t        len;
  const uint8_t *vals;
} reg_init_t;


/*
 * Radio Commands
 */

const uint8_t si446x_nop[]           = { SI446X_CMD_NOP };          /* 00 */
const uint8_t si446x_part_info[]     = { SI446X_CMD_PART_INFO };    /* 01 */
const uint8_t si446x_power_up[]      = { RF_POWER_UP };             /* 02 */
const uint8_t si446x_func_info[]     = { SI446X_CMD_FUNC_INFO };    /* 10 */
const uint8_t si446x_gpio_cfg_nc[]   = { SI446X_CMD_GPIO_PIN_CFG,   /* 13 */
  SI446X_GPIO_NO_CHANGE, SI446X_GPIO_NO_CHANGE,
  SI446X_GPIO_NO_CHANGE, SI446X_GPIO_NO_CHANGE,
  SI446X_GPIO_NO_CHANGE,                /* nirq, no change */
  SI446X_GPIO_NO_CHANGE,                /* sdo, no change */
  0                                     /* gen_config */
};
const uint8_t si446x_fifo_info_nc[]  = { SI446X_CMD_FIFO_INFO, 0 }; /* 15 */
const uint8_t si446x_packet_info_nc[]= { SI446X_CMD_PACKET_INFO };  /* 16 */
const uint8_t si446x_int_status_nc[] = { SI446X_CMD_GET_INT_STATUS, /* 20 */
  SI446X_INT_NO_CLEAR, SI446X_INT_NO_CLEAR, SI446X_INT_NO_CLEAR };
const uint8_t si446x_int_clr[] = { SI446X_CMD_GET_INT_STATUS };     /* 20 */
const uint8_t si446x_ph_status_nc[] = {                             /* 21 */
  SI446X_CMD_GET_PH_STATUS, SI446X_INT_NO_CLEAR };
const uint8_t si446x_ph_clr[] = { SI446X_CMD_GET_PH_STATUS};        /* 21 */
const uint8_t si446x_modem_status_nc[] = {                          /* 22 */
  SI446X_CMD_GET_MODEM_STATUS, SI446X_INT_NO_CLEAR };
const uint8_t si446x_modem_clr[] = { SI446X_CMD_GET_MODEM_STATUS }; /* 22 */
const uint8_t si446x_chip_status_nc[] = {                           /* 23 */
  SI446X_CMD_GET_CHIP_STATUS, SI446X_INT_NO_CLEAR };
const uint8_t si446x_chip_clr[] = { SI446X_CMD_GET_CHIP_STATUS };   /* 23 */
const uint8_t si446x_device_state[] = { SI446X_CMD_REQUEST_DEVICE_STATE }; /* 33 */

tasklet_norace message_t  * txMsg;            /* msg driver owns */
message_t                   rxMsgBuffer;
tasklet_norace message_t  * rxMsg = &rxMsgBuffer;

/* needs to be volatile, can be modified at interrupt level */
norace volatile enum {                /* no race is fine. */
  TXUS_IDLE,                          /* nothing happening */
  TXUS_STARTUP,                       /* starting to write h/w */
  TXUS_PENDING,                       /* waiting to finish */
  TXUS_ABORT                          /* oops */
} tx_user_state;


module Si446xDriverLayerP {
  provides {
    interface Init as SoftwareInit @exactlyonce();

    interface RadioState;
    interface RadioSend;
    interface RadioReceive;
    interface RadioCCA;
    interface RadioPacket;

    interface PacketField<uint8_t> as PacketTransmitPower;
    interface PacketField<uint8_t> as PacketRSSI;
    interface PacketField<uint8_t> as PacketTimeSyncOffset;
    interface PacketField<uint8_t> as PacketLinkQuality;
//  interface PacketField<uint8_t> as AckReceived;
    interface PacketAcknowledgements;
  }
  uses {
    interface LocalTime<TRadio>;
    interface Si446xDriverConfig as Config;

    interface Resource       as SpiResource;
    interface FastSpiByte;
    interface SpiByte;
    interface SpiPacket;
    interface SpiBlock;

    interface Si446xInterface as HW;

    interface PacketFlag     as TransmitPowerFlag;
    interface PacketFlag     as RSSIFlag;
    interface PacketFlag     as TimeSyncFlag;
    interface PacketFlag     as AckReceivedFlag;

    interface PacketTimeStamp<TRadio, uint32_t>;

    interface Tasklet;
    interface RadioAlarm;

#ifdef RADIO_DEBUG_MESSAGES
    interface DiagMsg;
#endif
    interface Platform;
    interface Panic;
    interface Trace;
  }
}

implementation {

#define HI_UINT16(val) (((val) >> 8) & 0xFF)
#define LO_UINT16(val) ((val) & 0xFF)

#define HIGH_PRIORITY 1
#define LOW_PRIORITY 0

#define __PANIC_RADIO(where, w, x, y, z) do {               \
	call Panic.panic(PANIC_RADIO, where, w, x, y, z);   \
  } while (0)


  /*----------------- STATE -----------------*/

  /*
   * order matters:
   *
   * RX:  RX_ON    to RX_ACTIVE
   * TX:  TX_START to TX_ACTIVE
   */
  typedef enum {
    STATE_SDN = 0,                      /* shutdown */
    STATE_POR_WAIT,                     /* waiting for POR to complete */
    STATE_PWR_UP_WAIT,                  /* waiting on POWER_UP cmd */
    STATE_LOAD,                         /* loading configuration */

    STATE_SDN_2_LOAD,
    STATE_STANDBY_2_LOAD,
    STATE_STANDBY,
    STATE_SPI,                          /* spi active */
    STATE_READY,
    STATE_RX_ON,                        /* ready to receive */
    STATE_RX_ACTIVE,                    /* actively receiving */
    STATE_TX_START,                     /* starting transmission */
    STATE_TX_ACTIVE,                    /* actively transmitting */
  } si446x_driver_state_t;


  /*
   * on boot, initilized to STATE_SDN (0)
   *
   * Also, on boot, platform initialization is responsible for setting
   * the pins on the si446x so it is effectively turned off.  (SDN = 1)
   *
   * Platform initialization occurs shortly after boot.  On the MSP430
   * platforms, reset forces all of the digital I/O in to input mode
   * which will effectively power down the CC2520.  Platform code then
   * initializes pin state so the chip is held in the OFF state until
   * commanded otherwise.
   *
   * Platform code is responsible for setting the various pins needed by
   * the chip to proper states.  ie.  NIRQ, CTS, inputs.  CSN (deasserted)
   * SDN (asserted).  SPI pins set up for SPI mode.
   */

  norace si446x_driver_state_t dvr_state;

  /*
   * tx_user_state is used for handshaking with the interrupt level
   * when doing a transmit.  The TX startup code will set this
   * datum to tell the interrupt level that TX start up code has been
   * doing something.   If a catastrophic error occurs, it will be
   * switched to TXUS_ABORT, which tells the TX code to fail.
   *
   * when tx_user_state is STARTUP or PENDING, txMsg holds a pointer the the
   * msg buffer that the upper layers want to transmit.   The driver owns
   * this buffer while it is working on it.
   */
//  norace enum {                         /* no race is fine. */
//    TXUS_IDLE,                          /* nothing happening */
//    TXUS_STARTUP,                       /* starting to write h/w */
//    TXUS_PENDING,                       /* waiting to finish */
//    TXUS_ABORT                          /* oops */
//  } tx_user_state;


  /*
   * if transmitting a timesync message, the original absolute timestamp
   * is kept in timesync_absolute.  0 is stored if not doing a timesync
   * message.
   */

  norace uint32_t timesync_absolute;

  enum {
    FCS_SIZE     = 2,
    TXA_MAX_WAIT = 50,                  /* in uS */
  };


  typedef enum {
    CMD_NONE        = 0,     // no command pending.
    CMD_TURNOFF     = 1,     // goto lowest power state.
    CMD_STANDBY     = 2,     // goto low power state
    CMD_TURNON      = 3,     // goto RX_ON state
    CMD_TRANSMIT    = 4,     // transmit a message
    CMD_RECEIVE     = 5,     // receive a message
    CMD_CCA         = 6,     // perform a clear chanel assesment
    CMD_CHANNEL     = 7,     // change the channel
    CMD_SIGNAL_DONE = 8,     // signal the end of the state transition
  } si446x_cmd_t;

  tasklet_norace si446x_cmd_t dvr_cmd;        /* gets initialized to 0, CMD_NONE  */
  tasklet_norace bool         radioIrq;       /* gets initialized to 0 */

  tasklet_norace uint8_t      txPower;        /* current power setting   */
  tasklet_norace uint8_t      channel;        /* current channel setting */

//  tasklet_norace message_t  * txMsg;          /* msg driver owns */

//  message_t                   rxMsgBuffer;
//  tasklet_norace message_t  * rxMsg = &rxMsgBuffer;

  /*
   * When powering up/down and changing state we use the rfxlink
   * utilities and the TRadio alarm for timing.   We flag this
   * using stateAlarm_active.  This allows for bailing out from
   * the main state control tasklet while we are waiting for
   * the RadioAlarm to fire.
   */
  norace bool stateAlarm_active   = FALSE;

//  si446x_status_t getStatus();


  si446x_packet_header_t *getPhyHeader(message_t *msg) {
    return ((void *) msg) + call Config.headerOffset(msg);
  }


  si446x_metadata_t *getMeta(message_t *msg) {
    return ((void *) msg) + sizeof(message_t) - call RadioPacket.metadataLength(msg);
  }


  void bad_state() {
    __PANIC_RADIO(1, dvr_state, dvr_cmd, 0, 0);
  }


  void next_state(si446x_driver_state_t s) {
    call Trace.trace(T_RS, dvr_state, s);
    dvr_state = s;
  }


  /*
   * si446x_get_cts
   *
   * encapsulate obtaining the current CTS value.
   *
   * CTS can be on a h/w pin or can be obtained via the SPI
   * bus.  This routine hides how it is obtained.
   */

  bool si446x_get_cts() {
    uint8_t cts_s;

//#ifdef SI446x_HW_CTS
#ifdef notdef
    cts_s = call HW.si446x_cts();
    return cts_s
#else
    xcts = call HW.si446x_cts();
    call HW.si446x_set_cs();
    call FastSpiByte.splitWrite(SI446X_CMD_READ_CMD_BUFF);
    xcts0 = call FastSpiByte.splitReadWrite(0);
    cts_s = call FastSpiByte.splitRead();
    xcts_s = cts_s;
    call HW.si446x_clr_cs();
    nop();
    return cts_s;
#endif
  }


  /*
   * send_cmd_no_cts
   *
   * send command but don't wait for CTS at end.
   *
   * should always be CTS at the beginning else panic.
   */

  void si446x_send_cmd_no_cts(const uint8_t *c, uint8_t *response, uint16_t length) {
    if (!si446x_get_cts()) {
        __PANIC_RADIO(2, 0, 0, 0, 0);
    }      
    call HW.si446x_set_cs();
    call SpiBlock.transfer((void *) c, response, length);
    call HW.si446x_clr_cs();
    return;
  }


  /*
   * Send command with CTS follow up.
   *
   * Send command pull returned bytes into response buff.
   * then waits for CTS to go up with a time out.
   *
   * If the time out trips, we panic.
   *
   * returns number of uS it took before CTS came up.  (for observing
   * chip behaviour).   
   */

  uint16_t si446x_send_cmd(const uint8_t *c, uint8_t *response, uint16_t length) {
    uint16_t t0, t1;

    si446x_send_cmd_no_cts(c, response, length);
    t0 = call Platform.usecsRaw();
    t1 = t0;
    while (!si446x_get_cts()) {
      t1 = call Platform.usecsRaw();
      if ((t1-t0) > SI446X_CTS_TIMEOUT) {
        __PANIC_RADIO(3, t1, t0, t1-t0, 0);
      }
    }
    return t1-t0;
  }


  /*
   * Get a Reply stream.  Uses READ_CMD_BUFF
   *
   * Always assumes the reply stream starts with CTS.
   *
   * r          where to put the reply
   * l          length of reply
   *
   * l doesn't include the cts byte.
   *
   * On entry makes sure that CTS is up so we can reliably
   * read the return/reply stream.
   */
  void si446x_get_reply(uint8_t *r, uint16_t l) {
    uint8_t rcts;

    if (!si446x_get_cts()) {
        __PANIC_RADIO(4, 0, 0, 0, 0);
    }      
    call HW.si446x_set_cs();
    call FastSpiByte.splitWrite(SI446X_CMD_READ_CMD_BUFF);
    call FastSpiByte.splitReadWrite(0);
    rcts = call FastSpiByte.splitRead();
    if (rcts != 0xff) {
        __PANIC_RADIO(5, 0, 0, 0, 0);
    }
    call SpiBlock.transfer(NULL, r, l);
    call HW.si446x_clr_cs();
  }


  /*
   * Read FRR
   *
   * read 1 Fast Response Register
   *
   * register comes back on the same SPI transaction as the command
   *
   * CTS does not need to be true.
   */
  uint8_t si446x_read_frr(uint8_t which) {
    uint8_t result;

    call HW.si446x_set_cs();
    call FastSpiByte.splitWrite(which);
    result = call FastSpiByte.splitReadWrite(0);
    result = call FastSpiByte.splitRead();
    call HW.si446x_clr_cs();
    return result;
  }

   
  /*
   * get current interrupt state -> *isp
   *
   * This is debug code for observing interrupt state.
   */
  void si446x_get_int_state(volatile si446x_chip_int_t *isp) {
    si446x_send_cmd(si446x_ph_status_nc, rsp, sizeof(si446x_ph_status_nc));
    si446x_get_reply((void *) &isp->ph_status, SI446X_PH_STATUS_SIZE);
    si446x_send_cmd(si446x_modem_status_nc, rsp, sizeof(si446x_modem_status_nc));
    si446x_get_reply((void *) &isp->modem_status, SI446X_MODEM_STATUS_SIZE);
    si446x_send_cmd(si446x_chip_status_nc, rsp, sizeof(si446x_chip_status_nc));
    si446x_get_reply((void *) &isp->chip_status, SI446X_CHIP_STATUS_SIZE);
    si446x_send_cmd(si446x_int_status_nc, rsp, sizeof(si446x_int_status_nc));
    si446x_get_reply((void *) &isp->int_status, SI446X_INT_STATUS_SIZE);
  }


  /*
   * get/clr interrupt state
   * clr interrupts and return previous state in *isp
   *
   * we grab and clear each of the individual blocks then grab int_status
   * without doing any additional clears.  Otherwise there is a window where
   * we can lose interrupts.
   *
   * This is debug code for observing interrupt state.
   */
  void si446x_getclr_int_state(volatile si446x_chip_int_t *isp) {
    si446x_send_cmd(si446x_ph_clr, rsp, sizeof(si446x_ph_clr));
    si446x_get_reply((void *) &isp->ph_status, SI446X_PH_STATUS_SIZE);
    si446x_send_cmd(si446x_modem_clr, rsp, sizeof(si446x_modem_clr));
    si446x_get_reply((void *) &isp->modem_status, SI446X_MODEM_STATUS_SIZE);
    si446x_send_cmd(si446x_chip_clr, rsp, sizeof(si446x_chip_clr));
    si446x_get_reply((void *) &isp->chip_status, SI446X_CHIP_STATUS_SIZE);
    si446x_send_cmd(si446x_int_status_nc, rsp, sizeof(si446x_int_status_nc));
    si446x_get_reply((void *) &isp->int_status, SI446X_INT_STATUS_SIZE);
  }


  /*
   * resets the Sfd queue back to an empty state.
   *
   * must be called when the h/w is shutdown.  Or
   * interrupts disabled.
   */
  void flushSfdQueue() {
    uint16_t i;

    call Trace.trace(T_R_SFD_FLUSH, 0xffff, 0xff00 | READ_SR);
    for (i = 0; i < MAX_SFD_STAMPS; i++)
      sfd_ptrs[i]->sfd_status = 0;
    sfd_fill    = 0;
    sfd_drain   = 0;
    sfd_entries = 0;
    sfd_lost = FALSE;
  }


  /*
   * advance the SfdQueue from the drain point after verifying we
   * are looking at the expected entry.
   *
   * returns TRUE if recovery should be invoked.
   *
   * drainOneSfd shouldn't ever get called if sfd_lost is set.
   */
  bool drainOneSfd(sfd_stamp_t *sfd_p, uint8_t sfd_lookfor) {
    if (sfd_lost)                       /* paranoid */
      return TRUE;

    /* check for out of order, what are we expecting */
    if ((sfd_p->sfd_status & (SFD_BUSY | sfd_lookfor))
                          != (SFD_BUSY | sfd_lookfor)) {
      __PANIC_RADIO(6, sfd_fill, sfd_drain, sfd_entries,
                    sfd_p->sfd_status);
      return TRUE;
    }
    sfd_p->sfd_status &= ~SFD_BUSY;
    if (++sfd_drain >= MAX_SFD_STAMPS)
      sfd_drain = 0;
    sfd_entries--;
    call Trace.trace(T_R_SFD_DRAIN, (sfd_fill << 8) | sfd_drain,
                     (sfd_lost ? 0x8000 : 0) | sfd_entries);
    return FALSE;
  }


  /* ----------------- Basic Access ----------------- */

  /* read from the SPI, putting bytes in buf */
  void readBlock(uint8_t *buf, uint8_t count) {
    uint8_t i;

    for (i = 1; i < count; i++)
      buf[i-1] = call FastSpiByte.splitReadWrite(0);
    buf[i-1] = call FastSpiByte.splitRead();
  }


  /* pull bytes from the SPI, throwing them away */
  void pullBlock(uint8_t count) {
    uint8_t i;

    for (i = 1; i < count; i++)
      call FastSpiByte.splitReadWrite(0);
    call FastSpiByte.splitRead();
  }


  /* write bytes from buf to the SPI */
  void writeBlock(uint8_t *buf, uint8_t count) {
    uint8_t i;

    for (i = 0; i < count; i++)
      call FastSpiByte.splitReadWrite(buf[i]);
    call FastSpiByte.splitRead();
  }


  /*
   * FIXME: this needs to get moved to PlatformCC2520
   *
   * Wiring and platform dependent.
   */
  void dr_hw_state() {
  }


  /*
   * It is unclear if dumping the FIFO is a) possible or b) useful.
   */
  void dump_radio_fifo() {
    uint8_t cts, rx_count, tx_count;

    /*
     * CSn (NSEL), needs to be held high (deasserted, cleared) for 80ns.
     * We throw a nop in just to make sure it stays up long enough.
     * Usually it isn't a problem but dump has a back to back because
     * we don't know the state of CS when called.
     */
    call HW.si446x_clr_cs();
    nop();
    call HW.si446x_set_cs();
    call FastSpiByte.splitWrite(SI446X_CMD_FIFO_INFO);
    call FastSpiByte.splitReadWrite(0);
    call FastSpiByte.splitRead();

    /* response */
    call FastSpiByte.splitWrite(0);
    cts = call FastSpiByte.splitReadWrite(0);           /* CTS */
    rx_count = call FastSpiByte.splitReadWrite(0);      /* RX_FIFO_CNT */
    tx_count = call FastSpiByte.splitRead();            /* TX_FIFO_CNT */
    call HW.si446x_clr_cs();

    /*
     * how to figure out if it is a tx or rx in the fifo.  So
     * we can pull the fifo contents.  Do we need to look at the
     * radio state to see what is going on?
     */
    if (tx_count < rx_count)
      tx_count = rx_count;
  }


  bool checkCCA() {
#ifdef notdef
    si446x_fsmstat1_t fsmstat1;

    fsmstat1.value  = readReg(SI446X_FSMSTAT1);
    if (fsmstat1.f.cca)
      return TRUE;
#endif
    return FALSE;
  }


  bool toogle;

  void drf();

  /*
   * stuff_config
   *
   * send a block of configuration data to the radio.  Each block is
   * is made up of multiple commands, (size, data array, starts with
   * command to send), terminated by (size 0, NULL).
   */
  void stuff_config(const si446x_radio_config_t *rcp) {
    const uint8_t *data;
    uint16_t size;

    while ((size = rcp->size)) {
      if (size > 16) {
        __PANIC_RADIO(7, (uint16_t) rcp, size, 0, 0);
      }
      data = rcp->data;
      si446x_send_cmd(data, rsp, size);
      nop();
      rcp++;
    }
  }


  /*
   * load configuration
   *
   * The configuration comes from a SiLabs program that generates
   * the file "radio_config_si446x.h" which lives in
   * tos/platforms/<platform>/hardware/si446x directory.  See the include
   * at the front of this file.  It is clearly denoted.
   *
   * this defines RADIO_CONFIGURATION_DATA_ARRAY.  We pull only the pieces
   * that we need rather than using RADIO_CONFIGURATION_DATA_ARRAY.
   *
   * "wds_config" pulls generated data from the SiLabs configuration data.
   *
   * "local_config" is data that is hand built and contains the driver and
   * h/w dependencies.
   *
   *  RF_POWER_UP       remove, requires timing
   *  RF_GPIO_PIN_CFG   remove, h/w dependent
   *  RF_INT_CTL_ENABLE_1 driver dependent
   *  RF_FRR_CTL_A_MODE_4 driver dependent
   *  RF_PKT_CRC_CONFIG_7 driver dependent (packet format)
   *  RF_PKT_LEN_12     driver dependent (packet format)
   *  RF_PKT_FIELD_2_CRC_CONFIG_12
   *  RF_PKT_FIELD_5_CRC_CONFIG_12
   *  RF_PKT_RX_FIELD_3_CRC_CONFIG_9
   *
   * The RF_* entries include the command being used to modify the chip state.
   * This is from the code generated from the EzRadioPro s/w from SiLabs.
   * It is too much trouble to change it so we just live
   * with it.
   */

  void load_config() {
    stuff_config(&si446x_wds_config[0]);
    stuff_config(&si446x_local_config[0]);
  }


  /* dump_properties */
  void dump_properties() {
    const dump_prop_desc_t *dpp;
    uint8_t group, index, length;
    uint8_t  *w, wl;                    /* working */
    uint16_t t0, t1;

    dpp = &dump_prop[0];
    while (dpp->length) {
      group = dpp->group;
      index = 0;
      length = dpp->length;
      w = dpp->where;
      while (length) {
        wl = (length > 16) ? 16 : length;
        call HW.si446x_set_cs();
        call FastSpiByte.splitWrite(SI446X_CMD_GET_PROPERTY);
        call FastSpiByte.splitReadWrite(group);
        call FastSpiByte.splitReadWrite(wl);
        call FastSpiByte.splitReadWrite(index);
        call FastSpiByte.splitRead();
        call HW.si446x_clr_cs();

        /*
         * wait for CTS, then suck the reply
         */
        t0 = call Platform.usecsRaw();
        t1 = t0;
        while (!si446x_get_cts()) {
          t1 = call Platform.usecsRaw();
          if ((t1-t0) > SI446X_CTS_TIMEOUT) {
            __PANIC_RADIO(64, t1, t0, t1-t0, 0);
          }
        }
        si446x_get_reply(w, wl);
        length -= wl;
        index += wl;
        w += wl;
      }
      dpp++;
    }
  }


  /* drf: dump_radio_full */
  void drf() __attribute__((noinline)) {

    mt0 = call LocalTime.get();

    /* do CSN before we reset the SPI port */
    rd.CSN_pin     = call HW.si446x_csn();

    call HW.si446x_clr_cs();          /* reset SPI on chip */
    nop();
    call HW.si446x_set_cs();
    nop();
    call HW.si446x_clr_cs();

    rd.u_ts        = call Platform.usecsRaw();
    rd.CTS_pin     = call HW.si446x_cts();
    rd.IRQ_pin     = call HW.si446x_irq();
    rd.SDN_pin     = call HW.si446x_sdn();
    rd.ta0ccr3     = TA0CCR3;
    rd.ta0cctl3    = TA0CCTL3;

    si446x_send_cmd(si446x_part_info, rsp, sizeof(si446x_part_info));
    si446x_get_reply((void *) &rd.part_info, SI446X_PART_INFO_SIZE);

    si446x_send_cmd(si446x_func_info, rsp, sizeof(si446x_func_info));
    si446x_get_reply((void *) &rd.func_info, SI446X_FUNC_INFO_SIZE);

    si446x_send_cmd(si446x_gpio_cfg_nc, rsp, sizeof(si446x_gpio_cfg_nc));
    si446x_get_reply((void *) &rd.gpio_cfg, SI446X_GPIO_CFG_SIZE);

    si446x_send_cmd(si446x_fifo_info_nc, rsp, sizeof(si446x_fifo_info_nc));
    si446x_get_reply(rsp, SI446X_FIFO_INFO_SIZE);
    rd.rxfifocnt  = rsp[0];
    rd.txfifofree = rsp[1];

    si446x_send_cmd(si446x_ph_status_nc, rsp, sizeof(si446x_ph_status_nc));
    si446x_get_reply((void *) &rd.ph_status, SI446X_PH_STATUS_SIZE);

    si446x_send_cmd(si446x_modem_status_nc, rsp, sizeof(si446x_modem_status_nc));
    si446x_get_reply((void *) &rd.modem_status, SI446X_MODEM_STATUS_SIZE);

    si446x_send_cmd(si446x_chip_status_nc, rsp, sizeof(si446x_chip_status_nc));
    si446x_get_reply((void *) &rd.chip_status, SI446X_CHIP_STATUS_SIZE);

    si446x_send_cmd(si446x_int_status_nc, rsp, sizeof(si446x_int_status_nc));
    si446x_get_reply((void *) &rd.int_status, SI446X_INT_STATUS_SIZE);

    si446x_send_cmd(si446x_device_state, rsp, sizeof(si446x_device_state));
    si446x_get_reply(rsp, SI446X_DEVICE_STATE_SIZE);
    rd.device_state = rsp[0];
    rd.channel      = rsp[1];

    rd.frr_a = si446x_read_frr(SI446X_CMD_FRR_A);
    rd.frr_b = si446x_read_frr(SI446X_CMD_FRR_B);
    rd.frr_c = si446x_read_frr(SI446X_CMD_FRR_C);
    rd.frr_d = si446x_read_frr(SI446X_CMD_FRR_D);

    si446x_send_cmd(si446x_packet_info_nc, rsp, sizeof(si446x_packet_info_nc));
    si446x_get_reply((void *) &rd.packet_info_len, SI446X_PACKET_INFO_SIZE);

    dump_properties();
    rd.m_ts        = call LocalTime.get();
    mt1 = rd.m_ts;
  }


  void dump_radio() __attribute__((noinline)) {
    atomic {
      drf();
    }
  }


  /*
   * writeTxFifo sends data bytes into the TXFIFO.
   *
   * First it sets CS which resets the radio SPI and enables
   * the SPI subsystem, next the cmd SI446X_CMD_TX_FIFO_WRITE
   * is sent followed by the data.  After the data is sent
   * CS is deasserted which terminates the block.
   *
   * If the TX fifo gets full, an additional write will throw a
   * FIFO Overflow exception.
   */
  void writeTxFifo(uint8_t *data, uint8_t length) {
    SI446X_ATOMIC {
      call HW.si446x_set_cs();
      call FastSpiByte.splitWrite(SI446X_CMD_TX_FIFO_WRITE);
      writeBlock(data, length);
      call HW.si446x_clr_cs();
    }
  }


  /*
   * flushFifo: resets internal chip fifo data structures
   *
   * The user of this routine needs to also consider the effect on the
   * sfd queue.   Typically, it gets flushed.  see flushSfdQueue().
   *
   * should not get used if RX or TX is currently active.  That is we
   * should make sure the chip is in Standby state first.
   */
  void flushFifo() {
    SI446X_ATOMIC {
      call HW.si446x_set_cs();
      call FastSpiByte.splitWrite(SI446X_CMD_FIFO_INFO);
      call FastSpiByte.splitReadWrite(SI446X_FIFO_FLUSH_RX |
                                      SI446X_FIFO_FLUSH_TX);
      call FastSpiByte.splitRead();

      /*
       * response, do we even need to read it?
       * does popping CS clean out any previous response?
       */
      call FastSpiByte.splitReadWrite(0);       /* CTS */
      call FastSpiByte.splitReadWrite(0);       /* RX_FIFO_CNT */
      call FastSpiByte.splitRead();             /* TX_FIFO_CNT */
      call HW.si446x_clr_cs();
    }
  }


  /*----------------- INIT -----------------*/

  command error_t SoftwareInit.init() {
    error_t err;

    /*
     * We need the SPI bus for initialization and SoftwareInit
     * is called early in the boot up process.  Because of this
     * only immediateRequest should be used.  Other pieces of the
     * system (like the arbiter fifos) have not been initialized
     * yet.  immediateRequest does not use those pieces.
     *
     * If one has minimal ports available full arbitration can be used
     * to share the port.  If no arbitration is needed simple changes
     * can be made to eliminate the overhead of arbitration.
     */
    err = call SpiResource.immediateRequest();
    if (err) {
      __PANIC_RADIO(8, err, 0, 0, 0);
      return err;
    }
    call HW.si446x_clr_cs();
    rxMsg = &rxMsgBuffer;
    return SUCCESS;
  }


  /*----------------- SPI -----------------*/

  event void SpiResource.granted() {
    call Tasklet.schedule();
  }


  bool isSpiAcquired() {
#ifdef SI446X_NO_ARB
    return TRUE;
#else
    if (call SpiResource.isOwner())
      return TRUE;
    if (call SpiResource.immediateRequest() == SUCCESS)
      return TRUE;
    call SpiResource.request();
    return FALSE;
#endif
  }


  void releaseSpi() {
#ifdef SI446X_NO_ARB
    return;
#else
    call SpiResource.release();
#endif
  }


  async event void SpiPacket.sendDone(uint8_t* txBuf, uint8_t* rxBuf,
                                      uint16_t len, error_t error) { };


  void loadRadioConfig() {
#ifdef notdef
    uint16_t i;

     for (i = 0; reg_config[i].len; i++)
      writeRegBlock(reg_config[i].reg_start, (void *) reg_config[i].vals,
                    reg_config[i].len);

    /* Manual register settings.  See Table 21 */
    writeReg(SI446X_TXPOWER,  0x32);
    writeReg(SI446X_FSCAL1,   0x2B);
#endif
  }


  void disableInterrupts() {
#ifdef notdef
    atomic {
      call ExcAInterrupt.disable();
      call SfdCapture.disable();
    }
#endif
  }


  /*
   * enableInterrupts: turn on interrupts we are interested in.
   *
   * Clears out anything pending
   */
  void enableInterrupts() {
#ifdef notdef
    atomic {
      call ExcAInterrupt.enableRisingEdge();
      call SfdCapture.captureBothEdges();
      call SfdCapture.clearOverflow();
      call SfdCapture.enableInterrupt();
    }
#endif
  }


  /*
   * resetRadio: kick the radio
   *
   * Reset always sets the chip's registers back to the Reset
   * configuration.   So we need to reload any changes we've
   * made.
   *
   * resetRadio has to disableInterrupts because it tweaks how
   * the gpio pins are connected which can easily cause them
   * to glitch and cause an interrupt or capture to occur.
   *
   * So anytime the radio is reset, radio interrupts are disabled.
   * The caller of resetRadio needs to figure out when it is reasonable
   * to reenable interrupts.  (most likely when we go back into RX_ON).
   *
   * No one currently resets the Radio, no calls to resetRadio.  Have a
   * proceedure that resets the Radio is problematic.  The documented
   * way to reset the radio according to SI446x documentation from SiLabs
   * is to shutdown the radio and reinitilize.  That takes a considerable
   * amount of time and requires sequencing the state machine.  Left as an
   * exercise for when needed.
   */


  /*
   * standbyInitRadio: radio power already on, assume config is correct
   *
   * on exit make sure exceptions cleared.  Assumed still
   * configured correctly.
   *
   * Do not call resetRadio, that will reset internal registers
   * requiring them to be reload which defeats the purpose
   * of going into standby.
   */
  void standbyInitRadio() {
    /*
     * do not reset!  Exceptions were cleared out when going into
     * STANDBY.  Interrupts get cleared out when they get enabled.
     */
    txPower = SI446X_DEF_RFPOWER;
    channel = SI446X_DEF_CHANNEL;
  }


  /*
   * fullInitRadio: radio was off full initilization
   *
   * needs to download config (loadRadioConfig).
   * on exit exceptions cleared and configured.
   */
  void fullInitRadio() {
#ifdef notdef
    /*
     * reset the radio which also reloads the configuration
     * because reset sets the config back to POR values.
     */
    disableInterrupts();
    loadRadioConfig();                          /* load registers */
    txPower = SI446X_DEF_RFPOWER & SI446X_TX_PWR_MASK;
    channel = SI446X_DEF_CHANNEL & SI446X_CHANNEL_MASK;
#endif
  }


  /*----------------- CHANNEL -----------------*/

  tasklet_async command uint8_t RadioState.getChannel() {
    return channel;
  }


  tasklet_async command error_t RadioState.setChannel(uint8_t c) {
    c &= SI446X_CHANNEL_MASK;
    if (dvr_cmd != CMD_NONE)
      return EBUSY;
    else if (channel == c)
      return EALREADY;

    channel = c;
    dvr_cmd = CMD_CHANNEL;
    call Tasklet.schedule();
    return SUCCESS;
  }


  void setChannel() {
#ifdef notdef
    uint8_t tmp;

    tmp = (11 + 5 * (channel - 11));
    writeReg(SI446X_FREQCTRL, tmp);
#endif
  }


  void changeChannel() {
#ifdef notdef
    if (isSpiAcquired()) {
      /*
       * changing channels requires recalibration etc.
       */
      setChannel();
      if (dvr_state == STATE_RX_ON) {
        disableInterrupts();
        resetExc();                                     /* clean out exceptions */
        strobe(SI446X_CMD_SRXON);                       /* force a calibration cycle */
        enableInterrupts();
        dvr_cmd = CMD_SIGNAL_DONE;
        return;
      }
    }
#endif
  }


  /*----------------- TURN_OFF, STANDBY, TURN_ON -----------------*/

  /*
   * task to actually load any configuration information into
   * the radio chip.   Done at task level because it takes a while
   * (up to 2ms) and we don't want to do this at interrupt level
   *
   * state will be LOAD_CONFIG or STANDBY_2_LOAD.
   *
   * We don't use a suspend/resume block because the radio won't
   * be generating any interrupt level events so Tasklet.schedule
   * should be fine.
   */
  task void SI446X_Load_Config() {
#ifdef notdef
    call Tasklet.suspend();
    if (dvr_state == STATE_LOAD_CONFIG)
      fullInitRadio();                /* in LOAD_CONFIG */
    else
      standbyInitRadio();             /* one of the STANDBYs */
    next_state(STATE_READY);
    call Tasklet.schedule();
    call Tasklet.resume();
#endif
  }


  void cs_sdn() {                       /* change state from SDN */
    /*
     * we need the spi, if not available we will
     * try again when the grant happens.
     */
    if (!isSpiAcquired())
      return;

    /*
     * the only command currently allowed is TURNON
     * if someone trys something different we will
     * bitch in an obvious way.
     */
    if (dvr_cmd != CMD_TURNON) {
      bad_state();
      return;
    }

    /*
     * we are going to need the RadioAlarm, if not free bail.  We stay in
     * STATE_OFF with a pending cmd TRUE.   When the RadioAlarm does
     * trip, it will run Tasklet.schedule() which will cause the Driver
     * state machine to run again and we will execute this code again.
     */
    if (!call RadioAlarm.isFree())
      return;
    next_state(STATE_POR_WAIT);
    call HW.si446x_unshutdown();
    stateAlarm_active = TRUE;
    call RadioAlarm.wait(SI446X_POR_WAIT_TIME);
  }


  void cs_por_wait() {
    /*
     * check to see if CTS is up, better be.  Then send POWER_UP to
     * continue with powering up the chip.  This will take some
     * time (16ms).  CTS will go back up when done.
     */
    if (!(xcts = call HW.si446x_cts())) {
      __PANIC_RADIO(9, 0, 0, 0, 0);
    }
    if (!isSpiAcquired())               /* if no SPI */
      return;
    if (dvr_cmd != CMD_TURNON) {
      bad_state();
      return;
    }
    next_state(STATE_PWR_UP_WAIT);
    si446x_send_cmd_no_cts(si446x_power_up, rsp, sizeof(si446x_power_up));
    stateAlarm_active = TRUE;
    call RadioAlarm.wait(SI446X_POWER_UP_WAIT_TIME);
  }


  void cs_pwr_up_wait() {
    if (!(xcts = call HW.si446x_cts())) {
      __PANIC_RADIO(10, 0, 0, 0, 0);
    }
    if (!isSpiAcquired())               /* if no SPI */
      return;
    if (dvr_cmd != CMD_TURNON) {
      bad_state();
      return;
    }

    drf();
    nop();
    if (!call HW.si446x_irq()) {
      __PANIC_RADIO(11, 0, 0, 0, 0);
    }

    /* clear out pending interrupts */
    si446x_getclr_int_state(&int_state);
    si446x_get_int_state(&chip_debug);
    nop();

    drf();
    nop();
    drf();
    nop();

    load_config();
    drf();
    nop();
  }


  void cs_xxx_2_load() {
    /*
     * This can be invoked when in SDN_2_LOAD or STANDBY_2_LOAD
     *
     * This doesn't run if the RadioAlarm is still active
     * stateAlarm_active is 1.
     */

    /*
     * check for SPI ownership.  No ownership -> stay in current state
     */
    if (!isSpiAcquired())               /* if no SPI */
      return;

    if (dvr_cmd != CMD_TURNON) {
      bad_state();
      return;
    }

    /*
     * SDN_2_LOAD -> LOAD_CONFIG to force full config.
     * STANDBY_2_LOAD only does StandbyInit
     */
    if (dvr_state == STATE_SDN_2_LOAD)
      next_state(STATE_LOAD);
    post SI446X_Load_Config();
  }


  void cs_standby() {
    uint16_t wait_time;

    if (!isSpiAcquired())
      return;

    if ((dvr_cmd == CMD_TURNOFF)) {
//      call PlatformCC2520.powerDown();
      call HW.si446x_shutdown();
      next_state(STATE_SDN);
      dvr_cmd = CMD_SIGNAL_DONE;
      return;
    }

    if (dvr_cmd == CMD_TURNON) {
//      wait_time = call PlatformCC2520.wakeup();
      wait_time = 0;
      if (wait_time) {
        if (!call RadioAlarm.isFree())
          return;
        next_state(STATE_STANDBY);
        stateAlarm_active = TRUE;
        call RadioAlarm.wait(wait_time);
        return;
      }
      next_state(STATE_STANDBY_2_LOAD);
      post SI446X_Load_Config();
      return;
    }

    bad_state();
  }


  void cs_ready() {
    /*
     * READY always transitions to RX_ON.
     */
    if (!isSpiAcquired())
      return;

    if (dvr_cmd == CMD_TURNON) {
      next_state(STATE_RX_ON);
      dvr_cmd = CMD_SIGNAL_DONE;
      setChannel();
      enableInterrupts();

      /*
       * all the majik starts to happen after the RXON is issued.
       * The chip will first go into RX Calibration (state 2) and
       * 192us later will enter SFDWait (3-6).  A preamble coming in
       * (after the 192us calibration) and SFD is another 160us.
       * So the minimum time before the 1st SFD interrupt is 192 + 160 us
       * (352 us, decimal).
       */
//      strobe(SI446X_CMD_SRXON);         /* (192+160)us before 1st SFD int.  */
      return;
    }

    /*
     * IDLE is a transitory state.  Other commands can't happen
     */

    bad_state();
  }


  void cs_rx_on() {
    if (!isSpiAcquired())
      return;

    if (dvr_cmd == CMD_STANDBY) {
      /*
       * going into standby, kill the radio.  But killing the radio
       * doesn't clean everything we need out.  So we need to kill any
       * pending exceptions and nuke the fifos.
       *
       * Interrupts are disabled here but cleaned out when they are
       * reenabled.
       *
       * We also need to clean out and reset any data structures associated
       * with the radio, like the SFD queue etc.       
       */
      disableInterrupts();
//      strobe(SI446X_CMD_SRFOFF);
//      strobe(SI446X_CMD_SFLUSHTX);      /* nuke  txfifo            */
      flushFifo();                      /* nuke fifo               */
      flushSfdQueue();                  /* reset sfd queue         */
//      resetExc();                       /* blow out exceptions     */
      timesync_absolute = 0;            /* no timesync in progress */
//      call PlatformCC2520.sleep();      /* tell PlatformCC2520 we are in standby */
      next_state(STATE_STANDBY);        /* no need to idle first */
      dvr_cmd = CMD_SIGNAL_DONE;
      return;
    }

    if (dvr_cmd == CMD_TURNOFF) {
      disableInterrupts();
      call HW.si446x_shutdown();
      next_state(STATE_SDN);
      dvr_cmd = CMD_SIGNAL_DONE;
      return;
    }

    bad_state();
  }


  void changeState() {
    /*
     * these only get called from the Main State Machine Sequencer (MSMS)
     * RadioAlarm has some other transitions
     */
    switch (dvr_state) {
      case STATE_SDN:           cs_sdn();               break;
      case STATE_POR_WAIT:      cs_por_wait();          break;
      case STATE_PWR_UP_WAIT:   cs_pwr_up_wait();       break;

      case STATE_SDN_2_LOAD:
                                cs_xxx_2_load(); break;
      case STATE_STANDBY:       cs_standby();    break;
      case STATE_READY:         cs_ready();      break;
      case STATE_RX_ON:         cs_rx_on();      break;

      case STATE_TX_START:
      default:
        bad_state();
        break;
    }
  }


  tasklet_async command error_t RadioState.turnOff() {
    if (dvr_cmd != CMD_NONE)
      return EBUSY;
    else if (dvr_state == STATE_SDN)
      return EALREADY;

    dvr_cmd = CMD_TURNOFF;
    call Tasklet.schedule();
    return SUCCESS;
  }


  tasklet_async command error_t RadioState.standby() {
    if (dvr_cmd != CMD_NONE)
      return EBUSY;
    if (dvr_state == STATE_STANDBY)
      return EALREADY;

    dvr_cmd = CMD_STANDBY;
    call Tasklet.schedule();
    return SUCCESS;
  }


  tasklet_async command error_t RadioState.turnOn() {
    if (dvr_cmd != CMD_NONE)
      return EBUSY;
    if (dvr_state >= STATE_RX_ON)
      return EALREADY;

    dvr_cmd = CMD_TURNON;
    call Tasklet.schedule();
    return SUCCESS;
  }


  default tasklet_async event void RadioState.done() { }


  /*----------------- TRANSMIT -----------------*/

  tasklet_async command error_t RadioSend.send(message_t *msg) {
    uint8_t     tmp;
//    bool        needs_CCA;

    uint8_t     length, preload_len;
    uint8_t   * dp;                     /* data pointer */
    void      * timesync;

    call PacketTimeStamp.clear(msg);
    if (txMsg) {
      /*
       * oops.   should be null.   Otherwise means we are trying to
       * have > 1 in flight.
       */
      __PANIC_RADIO(12, (uint16_t) txMsg, 0, 0, 0);
      txMsg = NULL;
    }
      
    /*
     * There is a handshake with the interrupt level that we use
     * to a) detect when a h/w abort has occurred.   And b) allows
     * us to tell the interrupt level when a signal send.sendDone is
     * needed.
     */
    tx_user_state = TXUS_STARTUP;

    /*
     * If something is going on cmdwise (dvr_cmd not CMD_NONE), bail.
     *
     * We only allow a transmit to start if we are in rx idle (RX_ON).
     * If currently receiving, tell the upper layer we are busy.
     */
    if (dvr_cmd != CMD_NONE       ||
        !isSpiAcquired()          ||
        dvr_state != STATE_RX_ON  ||
        radioIrq                  ||
        tx_user_state != TXUS_STARTUP) {
      tx_user_state = TXUS_IDLE;
      return EBUSY;
    }

    dp     = (void *) getPhyHeader(msg);
    length = *dp;                       /* length is first byte. */

    /*
     *  dp[0]   dp[1]   d[2]   dp[3] ...   dp[length - 2]   FCS (2)
     * length | fcf     fcf    dsn   ... 
     *
     * Start by sending PreloadLength to buy us some time on slow mcus.
     * (length, fcf, dsn, dpan, daddr  (7 bytes + len byte (1)))
     *
     * Note we could be sending an ACK, in which case we have:
     *
     *  dp[0]   dp[1]   dp[2]   dp[3]
     * length | fcf_0 | fcf_1 | dsn   | fcs_0 | fcs_1   (length of 5)
     * fcs is auto generated so we don't need to send it to the txfifo.
     */

    preload_len = call Config.headerPreloadLength();
    if (preload_len > length)
      preload_len = length;

    length -= preload_len;

    tmp =
      (call PacketTransmitPower.isSet(msg)
        ? call PacketTransmitPower.get(msg) : SI446X_DEF_RFPOWER)
      & SI446X_TX_PWR_MASK;

    if (tmp != txPower) {
      txPower = tmp;
//      writeReg(SI446X_TXPOWER, txPower);
    }

    /*
     * On the msp430, ISRs run by default with interrupts off but we have
     * some interrupt sensative issues.  For instance we really want the
     * SFDCapture interrupt to go off if a receive is happening.  Same is
     * true if there is an exception that is pending or about to go off.
     *
     * Once could try to manipulate the interrupts manually but that breaks
     * nesc's atomic analysis and it stops doing the right thing.  In other
     * words it does atomic elimination based on what it thinks is the known
     * interrupt status, but we've manipulated that status out from underneath
     * it.   This breaks things.   Don't do that.
     *
     * So we need to turn interrupts on in the appropriate place in the entry
     * routines on the msp430.
     */

    /*
     * We start with most of the 15.4 header loaded to the fifo, but
     * first we have to write the length byte.  This is why we send
     * preload_len + 1 bytes to the fifo, the +1 is to account for the
     * length.
     */
    preload_len++;                      /* account for the len byte */
    writeTxFifo(dp, preload_len);
    dp += preload_len;                  /* move to where to continue from */

    /*
     * Critical Region!
     *
     * First, the current state must be checked in an atomic block. We want to hold
     * off the SFD interrupt which can cause a change in dvr_state.
     *
     * Second, once we issue the strobe, we want to look for the TXA coming up
     * in a tight loop.  It should come up fast and we only look for about 30uS
     * or so (TXA_MAX_WAIT).  So don't let anything else in either.
     */
    atomic {
      /*
       * while we were sending stuff to the fifo, something may have happened
       * that changed our state.   Check again.
       */
      if (dvr_cmd != CMD_NONE        ||
          dvr_state != STATE_RX_ON   ||
          radioIrq                   ||
          tx_user_state != TXUS_STARTUP) {
        tx_user_state = TXUS_IDLE;
//        strobe(SI446X_CMD_SFLUSHTX);          /* discard header */
        return EBUSY;
      }

      txMsg = msg;                            /* driver now has the msg */
      next_state(STATE_TX_START);
      dvr_cmd = CMD_TRANSMIT;                 /* prevents other commands */

#ifdef notdef
      needs_CCA = (call Config.requiresRssiCca(msg) ? 1 : 0);
      if (needs_CCA)
        strobe(SI446X_CMD_STXONCCA);
      else
        strobe(SI446X_CMD_STXON);
#endif

#ifdef notdef
      /*
       * To avoid cpu dependent majik values for how long to wait, we
       * require Platform.usecsRaw to be properly working.   A reasonable
       * trade off to get non-cpu dependent timing values.
       *
       * If we are going to get the chip, TXA (tx_active) happens almost
       * immediately, but to be on the safe side we wait for up to TXA_MAX_WAIT
       * before giving up.  This only costs us in the case where we don't get
       * the channel.
       *
       * We can't use BusyWait because we dump out of the middle with
       * a check for TXA being up.
       */

      t0 = call Platform.usecsRaw();
      while (!call TXA.get()) {
        t1 = call Platform.usecsRaw();
        if ((t1 - t0) > TXA_MAX_WAIT)
          break;
      }
      if (call TXA.get() == 0) {
        /*
         * the TX didn't start up.  flush the txfifo and bail
         *
         * We could be actively receiving, in which case our state will be
         * RX_ACTIVE (done by SfdCapture).  An RX SFD was seen.
         *
         * or ...  not receiving but enough energy to trip the CCA check.
         * In which case we will still be in TX_START.  So transition back
         * to RX_ON which indicates idle receive.
         */
        txMsg = NULL;
        tx_user_state = TXUS_IDLE;
        if (dvr_cmd == CMD_TRANSMIT)
          dvr_cmd = CMD_NONE;
        strobe(SI446X_CMD_SFLUSHTX);
        if (dvr_state == STATE_TX_START)  /* must be protected */
          next_state(STATE_RX_ON);        /* with atomic       */
        return EBUSY;
      }
#endif
    } /* end atomic */

    timesync = call PacketTimeSyncOffset.isSet(msg) ? ((void*)msg) + call PacketTimeSyncOffset.get(msg) : 0;
    if (timesync) {
      /*
       * if we have a pointer into the packet, (timesync non-NULL), then
       * it points to where the absolute time of the event is stored.
       *
       * grab the absolute time and store in m_timesync_absolute.   This also
       * tells SfdCapture that we need to finish the timesync writing.
       *
       * Write all the payload to the txfifo except the last 4 bytes which is
       * the relative timesync value.  This will be done from the SfdCapture
       * interrupt.
       */
      writeTxFifo(dp, length - sizeof(timesync_relative_t) - FCS_SIZE);
      timesync_absolute = (*(timesync_absolute_t *) timesync);
    } else {
      /* no timesync, write full packet */
      if (length > 0)
        writeTxFifo(dp, length - FCS_SIZE);
    }

    /*
     * If something catastrophic, we may have let the interrupt handler
     * deal with it.  This will cause the driver to reset.  The interrupt
     * level will change tx_user_state to ABORT.
     */
    atomic {              /* protect tx_user_state access */
      if (tx_user_state == TXUS_ABORT) {
        txMsg = NULL;
        tx_user_state = TXUS_IDLE;
        if (dvr_cmd == CMD_TRANSMIT)
          dvr_cmd = CMD_NONE;
        return FAIL;
      }
      tx_user_state = TXUS_PENDING;
    }
    return SUCCESS;
  }


  default tasklet_async event void RadioSend.sendDone(error_t error) { }
  default tasklet_async event void RadioSend.ready() { }


  /*----------------- CCA -----------------*/

  tasklet_async command error_t RadioCCA.request() {
    if (dvr_cmd != CMD_NONE || dvr_state != STATE_RX_ON)
      return EBUSY;

    dvr_cmd = CMD_CCA;
    call Tasklet.schedule();        /* still can signal out of here */
    return SUCCESS;
  }

  default tasklet_async event void RadioCCA.done(error_t error) { }


  /*----------------- RECEIVE -----------------*/

  /*
   * nuke2rxon: reset the chip back to RX_ON
   *
   * o disables interrupts
   * o turns off RX and TX -> forces to IDLE state (on chip)
   * o flush both rx and tx fifos
   * o cleans out any exceptions
   * o restart the chip ==> RX_ON.
   *
   * We do not need to protect against interrupts because the very first
   * thing we do is disable interrupts which turns off both the exception
   * and SFD interrupts.  This protects us against any critical region
   * violations.
   */
  void nuke2rxon() {
    disableInterrupts();
//    strobe(SI446X_CMD_SRFOFF);
//    strobe(SI446X_CMD_SFLUSHTX);
    flushFifo();
    flushSfdQueue();
//    resetExc();
    setChannel();
    timesync_absolute = 0;
    next_state(STATE_RX_ON);            /* before enableInts and RXON */
//    strobe(SI446X_CMD_SRXON);
    si446x_inst_nukes++;
    enableInterrupts();                 /* clears all ints out too */
  }


  /*
   * process an incoming packet.
   *
   * o check lengths (RXFIRST, first byte of packet, passed in)
   * o account for SFD stamp entry.
   * o sfd_stamp (at sfd_drain) has been checked for reasonableness
   *
   * Interrupts disabled on the way in.  When we copy the packet out of
   * the rxfifo, we reenable interrupts to allow SFDCapture interrupts
   * to minimize losing edges.  After the copy is complete we disable
   * interrupts again.
   *
   * return TRUE   to force a recovery
   * return FALSE, no problems.
   */
  bool snarfMsg(uint8_t length) {       /* snag message from rxfifo */
    uint8_t     * dp;                   /* data pointer */
    uint8_t       tmp, rssi;
    uint8_t       crc_lqi;
    sfd_stamp_t * sfd_p;

    /*
     * start pulling data from the rxfifo
     * length was checked outside.  Looks reasonable.
     *
     * we haven't pulled anything from the fifo yet so
     * we still have the length byte at the front of the fifo.
     *
     * We are guaranteed at least 5 bytes so we use FastSpi to
     * be reasonable with the pipeline.
     */

    call Trace.trace(T_R_RX_PKT, length, 0xff00 | READ_SR);
    __nesc_enable_interrupt();      /* let SFD interrupts in, and others */
    call HW.si446x_set_cs();
//    call FastSpiByte.splitWrite(SI446X_CMD_RXBUF);      /* start pipe up */
    call FastSpiByte.splitReadWrite(0);                 /* return status */
    tmp = call FastSpiByte.splitReadWrite(0);           /* pull length   */
    if (tmp != length) {
      /* weird.  better match or something is very weird */
      __PANIC_RADIO(13, tmp, length, 0, 0);
       /* no recovery, don't know how to tweak it, believe the value read */
      length = tmp;
    }

    /*
     * FIXME
     * i don't think this is right, isn't maxPayload referring to the data area?
     * while length refers to entire 802.15.4 frame.  shouldn't we subtract
     * off the header size as well.
     */
    if ((length - FCS_SIZE) > call RadioPacket.maxPayloadLength()) {
      si446x_inst_pkt_toolarge++;
      pullBlock(length);                /* length is number of spi reads to do */
      call HW.si446x_clr_cs();
      __nesc_disable_interrupt();

      /*
       * We need to account for the SFD entry too.  See below for the details
       * but this is a subset of what is done below.
       *
       * interrupts need to be off, SfdQueue gets manipulated at interrupt level
       * so it needs to be protected.
       */
      if (sfd_lost || sfd_entries == 0)
        return FALSE;

      sfd_p  = sfd_ptrs[sfd_drain];
      return drainOneSfd(sfd_p, SFD_RX);
    }

    if (!rxMsg) {                       /* never should be null */
      __PANIC_RADIO(14, (uint16_t) rxMsg, 0, 0, 0);
      /* just plain ugly.   bail.   no null pointer dereferences */
      __nesc_disable_interrupt();
      return TRUE;                      /* force recovery */
    }
    dp = (void *) getPhyHeader(rxMsg);
    *dp++ = length;
    length -= FCS_SIZE;                 /* lose fcs bytes */
    readBlock(dp, length);              /* read packet data */

    /*
     * last two bytes aren't the actual FCS but have been replaced
     * by the radio chip with RSSI (8), CRC_OK(1) + LQI(7)
     */
    call FastSpiByte.splitWrite(0);
    rssi    = call FastSpiByte.splitReadWrite(0);
    crc_lqi = call FastSpiByte.splitRead();
    call HW.si446x_clr_cs();

    /*
     * SFD handling.
     *
     * Overflow/Overwrite (sfd_lost TRUE) causes the entire sfdqueue to be
     * ignored until both fifos are emptied.  Overwrite, sets sfd_lost and
     * sets sfd_entries to 0.  sfd_entries will stay 0 until the
     * sfd_lost condition is cleared.
     *
     * If we are receiving packets, we process the sfdqueue for only rx
     * packets.  We assume that there are no tx packets in the way.  The
     * single TX packet should have been taken care of before any other rx
     * packets could get in the way.
     */
    if (sfd_lost || sfd_entries == 0)
      call PacketTimeStamp.clear(rxMsg);
    else {
      sfd_p  = sfd_ptrs[sfd_drain];
      if ((sfd_p->sfd_status & (SFD_BUSY | SFD_RX))
                            == (SFD_BUSY | SFD_RX)) {
        call PacketTimeStamp.set(rxMsg, sfd_p->local);
        sfd_p->time_finish = call LocalTime.get();
      } else
        call PacketTimeStamp.clear(rxMsg);
      if (drainOneSfd(sfd_p, SFD_RX))
        return TRUE;                    /* oops */
    }

    /* see if we should accept the packet */
    if (signal RadioReceive.header(rxMsg)) {
      call PacketRSSI.set(rxMsg, rssi);         /* set only if accepting */
      call PacketLinkQuality.set(rxMsg, crc_lqi & 0x7f);
    }

    nop();
    if (crc_lqi & 0x80) {              /* upper bit set says crc ok */
      call Trace.trace(T_R_RX_RECV, 0, 0);
      rxMsg = signal RadioReceive.receive(rxMsg);
    } else {
      si446x_inst_bad_crc++;
      call Trace.trace(T_R_RX_BAD_CRC, 0, 0);
    }
    nop();
    __nesc_disable_interrupt();
    return FALSE;
  }


  /*----------------- IRQs -----------------*/

  /*
   * We use SFD capture interrupts to denote packet edges and to sequence the
   * state machine as packets are transmitted and received.
   *
   * SFD timing values are stored in the SFDQueue along with what radio state
   * we are in (tx or rx).  The SFDQueue is a strict FIFO queue.
   *
   * The SFD capture interrupt should be a higher priority than the exception
   * interrupt.  While on the exception interrupt, interrupts should be
   * reenabled to allow the SFDCapture interrupt to come in if we are being
   * slammed with incoming RX packets.
   *
   * RX sequencing:
   *
   * When the chip is put into RX_ON, RX calibration occurs and the chip is
   * ready to accept packets.  The following is what happens:
   *
   *     SFD rises, SFD capture, SFD interrupt
   *         SFD up, RX mode, insert into SFD queue
   *         -> STATE_RX_ACTIVE
   *
   *     packet completes
   *
   *     SFD falls, SFD capture, SFD interrupt, EXCA (RX_FRM_DONE) interrupt
   *         SFD down, RX mode, complete SFD queue entry.
   *         -> STATE_RX_ON
   *
   * how to handle multiple packets in the rxfifo.  We can't handle back
   * to back RX packets.  The first packet will set the variable length
   * cell.  If the first packet hasn't been processed yet and another packet
   * comes in it will modify the length cell....   How to detect when another
   * rx packet has come in and messed with the fifo?
   *
   *
   * Timing:
   *
   * Preamble(4), SFD(1), len(1) -> (6).
   * MPDU(len).  Minimum is FC(2) DSN(1) FCS(2) -> (5).
   *     addressing adds (4)
   *
   * no addressing:
   *   <sfd up> len(1) MPDU(5) <sfd down> preamble(4) sfd(1) <sfd up>
   *     min time: sfd_up to sfd_down: 192us
   *     min time: sfd_down to sfd_up: 160us   (b2b happens?)
   *     min time: sfd_up to sfd_up:   352us
   *
   * short addressing:
   *   <sfd up> len(1) MPDU(9) <sfd down> preamble(4) sfd(1) <sfd up>
   *     min time: sfd_up to sfd_down: 320us
   *     min time: sfd_down to sfd_up: 160us
   *     min time: sfd_up to sfd_up:   480us
   *
   * Performance issues:
   *
   * 1) TX doesn't have an issue (but it can effect RX timing).   TXfifo can
   *    only have one packet so isn't a gating issue.
   *
   * 2) RX packets don't get copied out until RX_FRM_DONE.   This is to
   *    minimize complexity.  However with back to back packets we only
   *    have 160us to handle the sfd_down and RX_FRM_DONE which includes
   *    coping the packet out.
   *
   *    ==> need the SFD interrupt to preempt any frame processing being
   *    done at a lower level.
   *
   *    ==> under load this means multiple packets in the rxfifo.
   *
   * TimeSync messages:
   *   TimeSync messages require that an absolute time that is embedded
   *   in the TX packet be modified to a time relative to the start of
   *   the packet's SFD.  We want this to be as accurate as possible which
   *   requires a good SFD timing value for the TX packet on the way out.
   *   This is done if the TX took.
   *
   *   A timesync message is defined to have the last 4 bytes of its
   *   data as the absolute time value (32 bits) of some event that
   *   occurred.   When transmitted it is converted to a time relative
   *   to the SFD rising edge of timesync packet.   Time of the event
   *   at the receiving end is then T_sfd + T_rel + T_transit.
   *
   *   When a timesync message is being sent, the full message minus the
   *   last 4 bytes is written to txfifo.  The original absolute time
   *   is stored in m_timesync_absolute, which if set to non-zero
   *   indicates to SFDCapture that a timesync is being done.   This
   *   value is initilized by RadioSend.send.   This keeps the overhead
   *   down to a minimum in the capture interrupt code.
   *
   *   If for some reason we have taken too long to get to actually
   *   processing the SfdCapture interrupt it is possible for the
   *   timesync transmit to generate a TX_UNDERFLOW/Exception.  Note,
   *   The SFD_up will occur first because it is a higher priority than
   *   the exception interrupt.   SFD processing is run to completion.
   *
   *   TX_UNDERFLOW gets caught in exception interrupt processing and
   *   generates a Panic which then resets the radio h/w back to RX_ON.
   *   This will also reset the SfdQueue.
   *
   *
   * Edge Lossage:
   *
   * It is possible to lose an SFD edge.  The code is explicitly written
   * to recover from this situation.  The state machine always returns
   * to RX_ON (it may take another SFD edge, which is guaranteed to happen
   * if we either transmit or if a RX starts to occur).
   *
   * When in an Overwritten state, time stamps are crap until resync'd.
   * This happens after the rxfifo has been drained.   Either flushed or
   * packet processing.
   *
   * We don't try to keep any sequencing after the SfdQueue becomes crap.
   * there really isn't any point, since we lost an edge.  We no longer
   * even know where we are.
   *
   * Normal operation:
   *
   * 1) Rising edge of SFD.  Gets new entry at sfd_fill.
   * 2) marked SFD_BUSY | SFD_UP
   * 3) sfd_entries++, one more active entry.
   * 4) state goes to {RX,TX}_ACTIVE.
   *
   * 5) falling edge of SFD.  uses same sfd_fill entry.
   * 6) marked SFD_DOWN
   * 7) sfd_fill gets incremented.
   *
   * 8) {RX,TX}_FD (frame done) exception processes entry from
   *    sfd_drain side of queue.  FIFO.
   * 9) entry marked ~SFD_BUSY.
   * 10) sfd_entries--
   *
   *
   * Overwritten Operation:
   *
   * When in an SFD overwritten state (1 or more SFD edges have been lost), we
   * ignore all timestamps in the queue.  We don't try to figure out which
   * edge (timestamp) got lost.
   *
   * We can resync the SFDQueue, when both TX and RX are quiescent.  This will
   * occur when the RXFIFO has been drained and the number of sfd_entries is 0.
   * When in overwrite status, sfd_entries at most will be 1, when a new RX
   * frame has been seen (SFD rising).
   *
   * While in overwrite, we only care about being in the middle of an RX packet,
   * in which case we have an active SFD entry being worked on.   We don't want
   * to yank that entry out by processing an exception and then trying to
   * resync the SfdQueue.  So we need to keep try of this state.  (this is
   * denoted by sfd_entries being 1).
   *
   * We also don't want to run out of SFDQueue entries if we continue to be
   * hammered.  New entries keep getting assigned, but we haven't been able
   * to resync yet because we have stayed busy.  We just make sure we
   * can use the next entry.  (SFDDown logic takes care of this).
   */

  bool in_sfdcapture_captured;

#ifdef notdef
  async event void SfdCapture.captured(uint16_t cap_time, bool overwritten)  {
    sfd_stamp_t         *sfd_p;
    uint8_t              sfd_up;
    uint32_t             local;
    uint16_t             upper, lower;
    timesync_relative_t  event_rel;
    uint8_t              tx_active;

    if (in_sfdcapture_captured) {
      __PANIC_RADIO(15, cap_time, overwritten, 0, 0);
      /* no recovery */
    }
    in_sfdcapture_captured = TRUE;

    sfd_up    = call SFD.get();
    tx_active = call TXA.get();
    sfd_p     = sfd_ptrs[sfd_fill];

    if (overwritten) {
      call Trace.trace(T_R_SFD_OVW, (sfd_fill << 8) | sfd_drain, sfd_entries);
      sfd_lost = TRUE;
      si446x_inst_sfd_overwrites++;
    }

    if (sfd_up) {
      /*
       * SFD is up, must be a rising edge
       *
       * rising edges always get a new SFD timing entry.  If none
       * available puke.  sfd_fill is the entry to use.
       */

      call Trace.trace(T_R_SFD_UP, (sfd_fill << 8) | sfd_drain,
                       (overwritten ? 0x8000 : 0) |
                       (tx_active   ? 0x4000 : 0) |
                       sfd_entries);
      if (sfd_lost) {
        /*
         * When sfd_lost is active, we could be looping around (because we
         * are getting hammered or got busy (long interrupt latency) and never
         * have time to clear out the mungled SfdQueue.  So we always make the
         * current fill entry available so we don't blow up.
         *
         * Also if we lost the previous falling edge, we will be filling into
         * a previously busy entry.  Back to back rising edges.  Make sure to
         * reuse current entry.
         */
        sfd_p->sfd_status = 0;          /* clear busy, if there. */
        sfd_entries = 0;                /* never more than 1, goes to 1 below */
      }

      if (sfd_p->sfd_status & SFD_BUSY) {
        /*
         * If BUSY is set, we must have lost an edge (trailing), and the
         * state machine got wedged Panic, then reset the entry to 0 which
         * will restart us.
         *
         * Can this happen?  Possibly a wild memory writer.  Doesn't
         * hurt to leave it in.  Other possibility is we've wrapped because
         * too many packets are in flight.  1 tx possible and multiple
         * receives that aren't getting processed.
         *
         * We also set sfd_lost, indicating that the timestamps are out of
         * sync again.  This lets the exceptionProcessor at least cycle
         * the queues and will eventually resync.
         */
        __PANIC_RADIO(16, sfd_fill, sfd_drain, sfd_entries, sfd_p->sfd_status);
        sfd_lost = TRUE;
        sfd_p->sfd_status = 0;
        sfd_entries--;                  /* made one go away. */
      }
      sfd_entries++;                    /* we are using this entry       */
      sfd_p->sfd_status = SFD_BUSY;     /* also clear out previous state */
      if (overwritten)
        sfd_p->sfd_status |= SFD_OVW;   /* remember what happened        */

      /*
       * Combine current time stamp (16 bits, uS, from h/w capture) with the
       * 32 bit localtime (TMicro) that the system is using.
       *
       * Note, if we have overwritten the captured timestamp we won't use
       * these timestamp results, because we've lost sync.
       *
       * However, that said, we want to adjust the localtime we've gotten
       * above to reflect the captured time of the SFD_up event.
       *
       * From observations, the captured time is around 15 uS later
       * then the actual observed event.   But this can vary because of
       * possible interrupt latency.  The capture time is done in h/w while
       * the localtime call happens in the interrupt handler so can be
       * delayed for various reasons.
       *
       * We want to back localtime up to reflect when the capture actually
       * occured.  This must take into account corner cases involving what
       * LocalTime can do.
       */
      local = call LocalTime.get();
      upper = local >> 16;
      lower = local & 0xffff;
      if (lower < cap_time) {           /* cap_time should be < lower */
        /*
         * if the low 16 of local are less than cap_time, it means the local
         * time has wrapped (16 bit wrap).  So we need to back local up
         * appropriately.
         */
        upper--;
      }
      sfd_p->time_up = cap_time;
      sfd_p->local   = ((uint32_t) upper << 16) | cap_time;

      if (tx_active) {
        /* tx sfd */
        sfd_p->sfd_status |= (SFD_UP | SFD_TX) ;
        if (dvr_state == STATE_TX_START) {      /* at interrupt level */
          next_state(STATE_TX_ACTIVE);          /* already protected  */
          if (timesync_absolute) {
            /*
             * compute relative time of the event from sfd_up.
             *
             * we need to adjust sfd_p->local to take into account when
             * sfd_up was captured, ie.  sfd_p->time_up
             */
            event_rel = timesync_absolute - sfd_p->local;
            writeTxFifo((uint8_t *) &event_rel, sizeof(timesync_relative_t));
            timesync_absolute = 0;
          }
        }
      } else {
        /* rx sfd */
        sfd_p->sfd_status |= (SFD_UP | SFD_RX);
        if (dvr_state == STATE_TX_START) {        /* protected */
          /*
           * race condition between send.send (tx_start) and an
           * rx coming in and winning.   TX actually issued the strobe
           * but tx didn't win.
           *
           * if debugging, note the if jumps directly into the next condition
           * because they both do the same thing.
           */
          next_state(STATE_RX_ACTIVE);
        } else if (dvr_state == STATE_RX_ON) {    /* protected */
          /*
           * Normal condition for rx coming in.  Also handles the
           * race condition where TX is starting up, but the RX sfd_up
           * happens prior to the TX send critical region (where the
           * strobe happens.  ie.  dvr_state != TX_START.   Setting
           * state to RX_ACTIVE will cause the transmit to abort.
           */
          next_state(STATE_RX_ACTIVE);
        }
      }
      in_sfdcapture_captured = FALSE;
      return;
    }

    /*
     * SFD is down, falling edge.  This tells us the radio is back to RX_ON.
     */
    call Trace.trace(T_R_SFD_DOWN, (sfd_fill << 8) | sfd_drain,
                     (overwritten ? 0x8000 : 0) |
                     (tx_active   ? 0x4000 : 0) |
                     sfd_entries);
    if (overwritten) {
      /*
       * Missed something, most likely it was the rising edge.  We want
       * to make sure to mark as BUSY so it shows as something happened
       * (valid state).  But also signal that things  are SNAFU'd.  Note that
       * if we did lose the rising edge, this entry won't have RX or TX set so
       * it will look weird.   That is yet another cookie crumb that might tell
       * us something about what happened.
       */
      sfd_p->sfd_status = (SFD_BUSY | SFD_OVW);         /* flag it */
    }
    if (sfd_lost) {
      /*
       * if sfd_lost is active, we throw all entries away except for the
       * partial.  We can't have a partial here (sfd is down) so zero entries
       */
      sfd_entries = 0;                 /* this lets resync happen */
    }

    if ((sfd_p->sfd_status & SFD_BUSY) == 0) {
      /*
       * oht oh.   really should have been busy from the rising edge
       * If we got overwritten, this got fixed above.  So must be a strange
       * situation.   Flag it, something is going really weird.
       */
        __PANIC_RADIO(17, sfd_fill, sfd_drain, sfd_entries, sfd_p->sfd_status);
        sfd_p->sfd_status |= SFD_BUSY;
    }

    sfd_p->sfd_status |= SFD_DWN;
    sfd_p->time_down = cap_time;
    if ((++sfd_fill) >= MAX_SFD_STAMPS)
      sfd_fill = 0;
    call Trace.trace(T_R_SFD_FILL, (sfd_fill << 8) | sfd_drain,
                     (overwritten ? 0x8000 : 0) |
                     (tx_active   ? 0x4000 : 0) |
                     sfd_entries);

    if (dvr_state == STATE_RX_ACTIVE) {           /* protected */
      /*
       * packet fully in rxfifo, rx_frm_done will kick pulling it
       * in the meantime, say back in rx_on (rx idle).
       */
      next_state(STATE_RX_ON);
    } else if (dvr_state == STATE_TX_ACTIVE) {
      /*
       * transmit is complete.  final processing is handled by the
       * tx_frm_done exception processing.   Different interrupt.
       *
       * switch back into RX_ON.
       */
      next_state(STATE_RX_ON);
    }

    in_sfdcapture_captured= FALSE;
  }
#endif


#ifdef notdef
  async event void ExcAInterrupt.fired() {
    radioIrq = TRUE;
    call Tasklet.schedule();
  }
#endif


  /*
   * Process a TX_FRM_DONE
   *
   * the sfd entry pointed to by drain is guaranteed to be pointing at
   * the TX entry.
   *
   * interrupts assumed off.  Assumed head of the sfdQueue is the TX
   * entry.  This is checked prior to getting here.
   *
   * The txMsg packet has had its timestamp cleared on the way in, only
   * set it if we have something reasonable to set it to.
   *
   * returns TRUE if we want recovery.
   */
  bool process_tx_frm_done() {
    sfd_stamp_t         *sfd_p;

    call Trace.trace(T_R_TX_PKT, (sfd_fill << 8) | sfd_drain,
                     (sfd_lost ? 0x8000 : 0) | sfd_entries);
    if (!sfd_lost && sfd_entries) {
      sfd_p  = sfd_ptrs[sfd_drain];
      call PacketTimeStamp.set(txMsg, sfd_p->local);
      sfd_p->time_finish = call LocalTime.get();
      if (drainOneSfd(sfd_p, SFD_TX))   /* we should be pointing at a SFD_TX */
        return TRUE;                    /* so shouldn't ever happen */
    }
//    writeReg(SI446X_EXCFLAG0, ~SI446X_EXC0_TX_FRM_DONE);
//    writeReg(SI446X_EXCFLAG1, ~SI446X_EXC1_CLR_OTHERS);
    if (dvr_cmd == CMD_TRANSMIT)
      dvr_cmd = CMD_NONE;                     /* must happen before signal */
    else
      __PANIC_RADIO(18, dvr_cmd, tx_user_state, (uint16_t) txMsg, 0);

    if (tx_user_state == TXUS_PENDING) {
      txMsg = NULL;
      tx_user_state = TXUS_IDLE;            /* needs to happen prior to signal */
      if (dvr_cmd == CMD_TRANSMIT)
        dvr_cmd = CMD_NONE;
      signal RadioSend.sendDone(SUCCESS);   /* this is from interrupt level    */
    } else {
      /*
       * strange, why isn't a transmit waiting?
       * we will eventually, ignore silently.
       */
      __PANIC_RADIO(19, tx_user_state, (uint16_t) txMsg, 0, 0);
      txMsg = NULL;
      tx_user_state = TXUS_IDLE;
      if (dvr_cmd == CMD_TRANSMIT)
        dvr_cmd = CMD_NONE;
    }
    return FALSE;
  }


  /*
   * make a pass at processing any ExcA exceptions that are up.  We only
   * process exceptions that are connected to excA.
   *
   * On entry, interrupts need to be disabled.  snarfMsg will reenable
   * interrupts while it is draining the rxfifo.
   *
   * NASTY: RF_NO_LOCK, SPI_ERROR, OPERAND_ERROR, USAGE_ERROR, MEMADDR_ERROR
   * TX_{UNDER,OVER}FLOW: These should happen.   Something went wrong.
   * RX_UNDERFLOW: shouldn't happen.
   *
   * RX_OVERFLOW: In the presence of outside packets, we need to deal with
   *     this.  Outside sources can send packets that we will receive that
   *     can cause the rxfifo to fill up.
   *
   *     We have observed large unknown packets in our testing.  From
   *     Smart Meters?  When decoded the packet's fcf field doesn't make
   *     sense but we still receive the packet (we can mess with filtering).
   *
   *     Also by handling RX_Overflow in a reasonable fashion we can
   *     cut down on DNS attacks.
   *
   * TX_ACK_DONE: h/w acking?   not implemented.
   *
   * RX_FRM_ABORTED: frame being received when SXOSCOFF, SFLUSHRX, SRXON,
   *     STXON, SRFOFF, etc.
   */

  void processExceptions() {
#ifdef notdef
    uint8_t       exc0, exc1, exc2;
    uint8_t       length, fifocnt;
    sfd_stamp_t * sfd_p;
    bool          recover,    rx_overflow;
    bool          tx_pending, rx_pending;

    /*
     * before starting let other interrupts in, just incase
     * something else needs to get executed before we dive
     * in to processing the exception.
     *
     * We just open a brief window and if anything is pending
     * it will take.
     *
     * Later, if we start something that will take a while (like
     * receiving a packet (pulling from the RXFIFO) we will reenable
     * interrupts while that is occuring.
     */

    __nesc_enable_interrupt();
    __nesc_disable_interrupt();


    /*
     * The do {} while(0) structure is used to allow exception processing to
     * bail out easily.  After the do {} while {}, additional per exception
     * checks are done, ie. recovery and overwrite resyncing.
     */

    do {
#ifdef notdef
      exc0 = readReg(SI446X_EXCFLAG0);
      exc1 = readReg(SI446X_EXCFLAG1);
      exc2 = readReg(SI446X_EXCFLAG2);
#endif
      recover = FALSE;
      call Trace.trace(T_R_EXCEP, (exc0 << 8) | exc1, exc2);

      /*
       * First check for nasty uglyness.
       *   EXC2_RF_NO_LOCK   EXC2_SPI_ERROR      EXC2_OPERAND_ERROR
       *   EXC2_USAGE_ERROR  EXC2_MEMADDR_ERROR
       */
#ifdef notdef
      if (exc2 & SI446X_FATAL_NASTY) {
        drs(FALSE);
        __PANIC_RADIO(20, exc0, exc1, exc2, 0);
        recover = TRUE;
        break;
      }
#endif

      if (exc0 & (SI446X_EXC0_TX_UNDERFLOW | SI446X_EXC0_TX_OVERFLOW)) {
        drs(FALSE);
        __PANIC_RADIO(21, exc0, exc1, exc2, 0);
        recover = TRUE;
        break;                          /* bail out, recover */
      }

      if (exc0 & SI446X_EXC0_RX_UNDERFLOW) {
        drs(FALSE);
        __PANIC_RADIO(22, exc0, exc1, exc2, 0);
        recover = TRUE;
        break;                          /* bail out, recover */
      }

      /*
       * Other strange stuff.  Currently not implemented.
       *
       * Just look and bitch.
       *
       * h/w ack processing:
       *   TX_ACK_DONE: (currently not implemented)
       *
       * RX_FRM_ABORTED: (shouldn't happen)
       */

      if ((exc0 & SI446X_EXC0_TX_ACK_DONE) ||
          (exc2 & SI446X_EXC2_RX_FRM_ABORTED)) {
        __PANIC_RADIO(23, exc0, exc1, exc2, 0);

        /* shouldn't ever happen, just looking for now */
//        if (exc0 & SI446X_EXC0_TX_ACK_DONE)
//          writeReg(SI446X_EXCFLAG0, ~SI446X_EXC0_TX_ACK_DONE);
//        if (exc2 & SI446X_EXC2_RX_FRM_ABORTED)
//          writeReg(SI446X_EXCFLAG2, ~SI446X_EXC2_RX_FRM_ABORTED);

        /* doesn't force a recovery */
      }

      /*
       * Normal handling: (packet processing)
       *   TX_FRM_DONE:
       *   RX_FRM_DONE:
       *
       * We need to process in the order that they have been seen.  This
       * is reflected in the SfdQueue.  We don't want any strange timing
       * effects if we start finishing packets out of order.
       *
       * That gets blown up if the SFDQueue gets blown up (out of sync)
       * and then we just do our best to get rid of what we have.
       *
       *******************************************************************
       *
       * Normal TX frame completion
       *
       * o clean out TX_FRM_DONE exception
       * o time stamp the packet.
       * o clean out the SFD entry.
       * o respond to tx_user_state (ie. PENDING -> signal upper layer)
       *
       * To actually start processing the TX_FRM_DONE we need a valid TX entry
       * at the start of the SfdQueue (or the queue is in an overwritten
       * condition).
       */
      sfd_p  = sfd_ptrs[sfd_drain];
      rx_pending = tx_pending = rx_overflow = FALSE;
      if (exc0 & SI446X_EXC0_TX_FRM_DONE) {
        tx_pending = TRUE;
        call Trace.trace(T_R_TX_FD, (sfd_lost ? 0x8000 : 0) | sfd_drain,
                         sfd_p->sfd_status);
        if (sfd_lost ||               /* no timestamps */
            ((sfd_p->sfd_status & (SFD_BUSY | SFD_TX))
                               == (SFD_BUSY | SFD_TX))) {
          tx_pending = FALSE;
          if (process_tx_frm_done()) {
            recover = TRUE;
            break;
          }

          /*
           * We can return from here (unlike RX_FRM_DONE) because we can have
           * one and only one TX outstanding at a time.  Any other exceptions
           * will still be up and need to be checked for anyway.  So exit out
           * and then come right back in.
           */
          return;
        }

        /*
         * Can't process the TX_FRM just yet, something else at the start
         * of the SfdQueue.  Hopefully there is an RX_FRM_DONE pending but
         * if we end up at the end we will bitch like hell.
         */

      }

      if (exc0 & SI446X_EXC0_RX_OVERFLOW) {
        /*
         * The rxfifo has overflowed.  Last (incomplete) packet can't be
         * recovered (incomplete, last byte thrown away).  When done
         * processing any packets in the rxfifo (to minimize DNS), we
         * need to flush the last packet, and then restart the RX up
         * again.
         */
//        writeReg(SI446X_EXCFLAG0, ~SI446X_EXC0_RX_OVERFLOW);
        rx_overflow = TRUE;
        si446x_inst_rx_overflows++;
        call Trace.trace(T_R_RX_OVR, (sfd_fill << 8) | sfd_drain, sfd_entries);
      }

      if (exc1 & SI446X_EXC1_RX_FRM_DONE) {
        rx_pending = TRUE;
        call Trace.trace(T_R_RX_FD, (sfd_lost ? 0x8000 : 0) | sfd_drain,
                         sfd_p->sfd_status);
        if (sfd_lost ||               /* no timestamps */
            ((sfd_p->sfd_status & (SFD_BUSY | SFD_RX))
                               == (SFD_BUSY | SFD_RX))) {
          rx_pending = FALSE;
          while (TRUE) {
            /*
             * Process all packets that have been fully received into the
             * RxFifo.  We have to process all of them, because there is
             * only one RX_FRM_DONE indication for however many packets are
             * in the rxfifo.  It would be nice if it was something like
             * RX_PACKETS_AVAIL instead and stays up until all complete
             * packets have been pulled.   But wishful thinking.
             *
             * Once we start to receive we want to continue until the rxfifo
             * is empty enough (length >= fifocnt, left with the currently
             * active RX packet or we have overflowed).  We also have to
             * check for a potentially interspersed TX_FRM that might have
             * gotten interleaved with the incoming rx packets.  I would think
             * that the TX would either be at the front or the back.  There is
             * at least 192us + 160us after the TX completes before a RX
             * packet can start coming in (rising SFD).  So there should be
             * enough time for the driver to finish dealing with the TX packet.
             *
             * We won't start a TX until the receiver is quiescent (has to be
             * in RX_ON and CCA).  However, once an rx packet is done (signaled
             * by sfd_down), we go back to RX_ON and a transmit potentially
             * can be started up.
             *
             * Note: RXFIRST may or may not have a valid byte.  If it is valid
             * it will typically be the length byte of the next packet (but
             * only if it is the first byte).  At all other times it is simply
             * left over from whatever previous data was in the rxfifo.
             *
             * If we are in a sfd_lost state, we will reset the SfdQueue once
             * the chip goes quiesent.  Ordinarily, we would have to protect
             * the SfdQueue access because the SfdCapture code (interrupt
             * level) also manipulates the SfdQueue.  But not a problem
             * because this routine only gets called with interrupts disabled.
             *
             * While processing a RX packet, another RX packet may have completed.
             * First, we will process this packet, but we also need to clear out
             * any new RX_FRM_DONE exceptions.  We won't have a new RX_FRM_DONE
             * exception if length < fifocnt, which says the packet hasn't been
             * completed yet, and will eventually generate the RX_FRM_DONE
             * exception.
             */
//            writeReg(SI446X_EXCFLAG1, ~SI446X_EXC1_RX_CLR);
//            length  = readReg(SI446X_RXFIRST);
//            fifocnt = readReg(SI446X_RXFIFOCNT);
            call Trace.trace(T_R_RX_LOOP, length, fifocnt);

            /*
             * nothing in the fifo?  no further checks, RXFIRST is nonsense
             */
            if (fifocnt == 0)
              break;

            /*
             * check for rxfifo being in a weird state, too short, or too long
             * indicates out of sync.   It may be a partial packet but if we
             * abort (via recover), the SfdQueue and the chip will get reset
             * by the recovery code.
             *
             * Minimum packet is...    LEN FC_0 FC_1 DSN FCS_0 FCS_1
             */
            if (length < 5) {
              /* below minimum size, must be out of sync */
              si446x_inst_rx_toosmall++;
              recover = TRUE;
              break;
            }

            if (length > 127) {
              si446x_inst_rx_toolarge++;
              recover = TRUE;
              break;
            }

            if (length >= fifocnt)              /* verify that rx_overflow and normal completion still works. */
              break;

            if (snarfMsg(length)) {       /* true says recover */
              recover = TRUE;
              break;
            }

            /***********************************************************
             *
             * All of this needs to be here.   We want to process tx and
             * rx packets in order.  So we have to be looking for what's
             * next in the SFDQueue.  But it is really driven off the
             * exception bits from the chip (RX_FRM_DONE and TX_FRM_DONE).
             * The SFDQueue is advisory for timestamps.
             *
             * Since we have to check in order to see of we have a pending
             * TX, we also need to be checking for nasty bits and
             * rx_overflow.
             *
             * Pain in the ass but its the architecture of the chip
             * coupled with being pedantic for keeping packets properly
             * ordered.
             *
             * You have been warned :-)
             *
             ***********************************************************/

            /*
             * see if anything nasty happened
             *
             * If really nasty, blow the chip up.  If rx_overflow, then
             * continue processing the rxfifo until all good packets
             * are gone, then handle the overflow.
             *
             * Fetch an updated value for exc0 to check for TX_FRM_DONE.
             */
//            exc0 = readReg(SI446X_EXCFLAG0);
//            exc1 = readReg(SI446X_EXCFLAG1);
//            exc2 = readReg(SI446X_EXCFLAG2);

            /*
             * if no exception bits, do another loop from the head
             * we have to keep processing packets in the rxfifo
             * until its empty.  There is only one rx_frm_done for
             * any rx packets that are already in the rxfifo.
             */
            if ((exc0 | exc1 | exc2) == 0)
              continue;

            /* more exception bits, see what we've got */
            call Trace.trace(T_R_EXCEP_1, (exc0 << 8) | exc1, exc2);
            if ((exc2 & SI446X_FATAL_NASTY) ||
                (exc0 & (SI446X_EXC0_TX_UNDERFLOW | SI446X_EXC0_TX_OVERFLOW)) ||
                (exc0 & SI446X_EXC0_RX_UNDERFLOW)) {
              __PANIC_RADIO(24, exc0, exc1, exc2, 0);
              recover = TRUE;
              break;
            }

            if (exc0 & SI446X_EXC0_RX_OVERFLOW) {
//              writeReg(SI446X_EXCFLAG0, ~SI446X_EXC0_RX_OVERFLOW);
              rx_overflow = TRUE;
              si446x_inst_rx_overflows++;
              call Trace.trace(T_R_RX_OVR_1, (sfd_fill << 8) | sfd_drain,
                               sfd_entries);
            }

            /* snarfMsg advanced sfd_drain, we need to refetch. */
            sfd_p  = sfd_ptrs[sfd_drain];
            if (exc0 & SI446X_EXC0_TX_FRM_DONE) {
              call Trace.trace(T_R_TX_FD_1, (sfd_lost ? 0x8000 : 0) | sfd_drain,
                               sfd_p->sfd_status);
              if (sfd_lost ||
                  ((sfd_p->sfd_status & (SFD_BUSY | SFD_TX))
                                     == (SFD_BUSY | SFD_TX))) {
                tx_pending = FALSE;
                if (process_tx_frm_done()) {
                  recover = TRUE;
                  break;
                }
              }
            }
          }
        }

        /*
         * Can't process the RX_FRM just yet, something else at the start
         * of the SfdQueue.  Hopefully a TX_FRM_DONE was present and got
         * processed, but if it didn't we'll exit out and will bitch.
         */
      }

      if (rx_overflow) {
        /*
         * RX_OVERFLOW processing.
         *
         * rx_overflow can be standalone or part of a rx stream.  Either way
         * when we get here we have length > rxfifocnt and the receiver is turned
         * off.  Chip will be in state 17 (rx_overflow).  We should have seen
         * a sfd_up and a sfd_down.  When we overflow, sfd is lowered.  The driver
         * state really should be RX_ON.  Nothing else makes sense.
         *
         * To start up the receiver again, we need to flush the rxfifo, clean up
         * the SFD entry for this packet start, and restart the receiver.
         */
        call Trace.trace(T_R_RX_OVR_1, (sfd_fill << 8) | sfd_drain,
                         (sfd_lost ? 0x8000 : 0) | sfd_entries);
        if (sfd_lost) {
          recover = TRUE;
          break;
        }
        if (dvr_state != STATE_RX_ON) {         /* really should be RX_ON */
          __PANIC_RADIO(25, exc0, exc1, exc2, dvr_state);
          recover = TRUE;
          break;
        }
        sfd_p  = sfd_ptrs[sfd_drain];
        if (drainOneSfd(sfd_p, SFD_RX)) {
          recover = TRUE;
          break;
        }
        flushRxFifo();
        next_state(STATE_RX_ON);
        strobe(SI446X_CMD_SRXON);
        rx_overflow = FALSE;
      }
    } while (0);

    /*
     * Additional Processing:
     *
     * First check for out of order sfdqueue.
     */

    if (!recover && (tx_pending || rx_pending)) {
      /*
       * if recover is set we will blow up the machine.  If we are here
       * and either tx_pending or rx_pending is set that means that we have
       * a unprocessed FRM_DONE and the SfdQueue doesn't match.  Something
       * really bent out of sorts.
       *
       * We will also cause a recovery after Panicing.
       */
      __PANIC_RADIO(26, exc0, exc1, exc2, (recover ? 0x4 : 0) |
                    (tx_pending ? 0x2 : 0) | (rx_pending ? 0x1 : 0));
      recover = TRUE;
    }
    if (recover) {
      call Trace.trace(T_R_RECOVER, 0xffff, 0xff00 | READ_SR);
      /*
       * nuke2rxon blows the h/w up and sets it back up to initial RX_ON state.
       *
       * We don't worry about more interrupts coming in because when running
       * at full speed, the radio takes 192us to do a rx_calibration and then
       * there will be another 160 uS before the first SFD can be recognized.
       * (4 bytes preamble and 1 byte SFD).
       *
       * We should be well out of here before that happens.  But single
       * stepping is a different story.
       */
      nuke2rxon();

      /*
       * if TXUS_STARTUP, tell the TX code we aborted and the h/w
       *    state has been reset.
       * if TXUS_PENDING  tell the waiting higher level, we blew up
       */
      if (tx_user_state == TXUS_STARTUP)
        tx_user_state = TXUS_ABORT;
      else if (tx_user_state == TXUS_PENDING) {
        txMsg = NULL;
        tx_user_state = TXUS_IDLE;        /* do this before signalling    */
        if (dvr_cmd == CMD_TRANSMIT)
          dvr_cmd = CMD_NONE;
        signal RadioSend.sendDone(FAIL);  /* this is from interrupt level */
      }                                   /* be careful                   */
    }

    /*
     * if we get this far, check for sfd_lost being active and try to do a resync
     * interrupts are off here.
     */
    if (sfd_lost) {
      if (dvr_state == STATE_RX_ON) {
        /*
         * the chip is only quiescent if in RX_ON.  Otherwise we have
         * something going on.  Don't rip the SfdQueue state out from
         * under any of that.
         */
        if (sfd_entries == 0) {
          /*
           * when sfd_lost is active, sfd_entries can be 0 or 1.  It will
           * be 1 if we've seen a rising edge and are using an entry.
           * don't yank the Queue.  This should already be protected by the
           * check for RX_ON above.
           */
//          fifocnt = readReg(SI446X_RXFIFOCNT);
          fifocnt = 0;
          if (fifocnt) {
            /*
             * Only yank if the rxfifo is completely empty.
             * it is odd to have fifocnt > 0 and be in RX_ON.
             */
            __PANIC_RADIO(27, exc0, exc1, exc2, fifocnt);
          }
          flushSfdQueue();
        }
      }
    }
#endif
  }


  void serviceRadio() {
    /*
     * what happens if Spi isn't owned?  How does this work?
     * leave radioIrq up.   And then when we get scheduled
     * from the grant, serviceRadio will get invoked again.
     *
     * What to do with existing interrupts?   Already cleared?
     */

    /* ******************************************************************** */

    /*
     * Normally, serviceRadio is an interrupt service routine and interrupts
     * are by default disabled.  However, in the presence of arbitration it is
     * possible that execution can be delayed until after granted is signalled.
     * When this happens we get called from Task(Sync) context and we need to
     * make sure interrupts are disabled.  Hence the atomic block.
     *
     * Later, in processExceptions, we reenable interrupts while copying bytes
     * out of the rxfifo.  We want to allow the SfdCapture interrupt to get
     * in for Sfd edges.  This has a higher priority than copying bytes out of
     * the rxfifo.
     */
    if (isSpiAcquired()) {
      atomic {
        radioIrq = FALSE;

        /*
         * Typically, a set of exception bits will be set for a single packet
         * that needs to be processed.  These bits get cleared by software as
         * the packet is processed.
         *
         * If all excA bits are down, excA will drop.  The next rising edge of
         * excA will generate another interrupt.
         *
         * But, there are corner cases where events can overlap.  So if an
         * exception bit gets raised after we have read the exception registers
         * during exception processing, then it won't be processed by the current
         * interation.  But because it is already up, it won't result in another
         * edge on excA so another interrupt won't be generated.
         *
         * Bottom line, is we need to continue to process exception bits as long
         * as excA is still up.   We may want to add a check for doing too many
         * loops.
         *
         * Spurious interrupts can occur and EXCA can be 0 because of this.  Do
         * nothing, if no EXCA.
         */

#ifdef notdef
        while (call EXCA.get())
          processExceptions();
#endif
      }
    }
  }


  default tasklet_async event bool RadioReceive.header(message_t *msg) {
    return TRUE;
  }


  default tasklet_async event message_t* RadioReceive.receive(message_t *msg) {
    return msg;
  }


  /* ----------------- TASKLET ----------------- */
  /* -------------- State Machine -------------- */

  tasklet_async event void RadioAlarm.fired() {
    nop();
    nop();
    stateAlarm_active = FALSE;
    call Tasklet.schedule();            /* process additional work */
  }


  /*
   * Main State Machine Sequencer
   */
  tasklet_async event void Tasklet.run() {
    nop();
    nop();
    if (radioIrq)
      serviceRadio();

    if (stateAlarm_active)
      return;

    switch (dvr_cmd) {
      case CMD_NONE:
        break;

      case CMD_TURNOFF:
      case CMD_STANDBY:
      case CMD_TURNON:
        changeState();
        break;

      case CMD_TRANSMIT:
      case CMD_RECEIVE:
        break;

      case CMD_CCA:
        signal RadioCCA.done(checkCCA() ? SUCCESS : EBUSY);
        dvr_cmd = CMD_NONE;
        break;

      case CMD_CHANNEL:
        changeChannel();
        break;

      case CMD_SIGNAL_DONE:
        break;

      default:
        break;
    }

    if (dvr_cmd == CMD_SIGNAL_DONE) {
      dvr_cmd = CMD_NONE;
      signal RadioState.done();
    }

    if (dvr_cmd == CMD_NONE && dvr_state == STATE_RX_ON && ! radioIrq)
      signal RadioSend.ready();

    if (dvr_cmd == CMD_NONE) {
      releaseSpi();
    }
  }


  /*----------------- RadioPacket -----------------*/

  /*
   * this returns the total offset from the start of the message buffer
   * to the MPDU header.
   */
  async command uint8_t RadioPacket.headerLength(message_t *msg) {
    return call Config.headerOffset(msg) + sizeof(si446x_packet_header_t);
  }


  async command uint8_t RadioPacket.payloadLength(message_t *msg) {
    return getPhyHeader(msg)->length - FCS_SIZE;
  }


  async command void RadioPacket.setPayloadLength(message_t *msg, uint8_t length) {
    RADIO_ASSERT( 1 <= length && length <= 125 );
    RADIO_ASSERT( call RadioPacket.headerLength(msg) + length + call RadioPacket.metadataLength(msg) <= sizeof(message_t) );

    // we add the length of the CRC, which is automatically generated
    getPhyHeader(msg)->length = length + FCS_SIZE;
  }


  async command uint8_t RadioPacket.maxPayloadLength() {
    RADIO_ASSERT( call Config.maxPayloadLength() - sizeof(si446x_packet_header_t) <= 125 );

    return call Config.maxPayloadLength() - sizeof(si446x_packet_header_t);
  }


  async command uint8_t RadioPacket.metadataLength(message_t *msg) {
//    return call Config.metadataLength(msg) + sizeof(si446x_metadata_t);
    return call Config.metadataLength(msg);
  }


  async command void RadioPacket.clear(message_t *msg) {
    // all flags are automatically cleared
  }


  /*----------------- PacketTransmitPower -----------------*/

  async command bool PacketTransmitPower.isSet(message_t *msg) {
    return call TransmitPowerFlag.get(msg);
  }


  async command uint8_t PacketTransmitPower.get(message_t *msg) {
    return getMeta(msg)->tx_power;
  }


  async command void PacketTransmitPower.clear(message_t *msg) {
    call TransmitPowerFlag.clear(msg);
  }


  async command void PacketTransmitPower.set(message_t *msg, uint8_t value) {
    call TransmitPowerFlag.set(msg);
    getMeta(msg)->tx_power = value;
  }


  /*----------------- PacketRSSI -----------------*/

  async command bool PacketRSSI.isSet(message_t *msg) {
    return call RSSIFlag.get(msg);
  }


  async command uint8_t PacketRSSI.get(message_t *msg) {
    return getMeta(msg)->rssi;
  }


  async command void PacketRSSI.clear(message_t *msg) {
    call RSSIFlag.clear(msg);
  }


  async command void PacketRSSI.set(message_t *msg, uint8_t value) {
    // just to be safe if the user fails to clear the packet
    call TransmitPowerFlag.clear(msg);

    call RSSIFlag.set(msg);
    getMeta(msg)->rssi = value;
  }


  /*----------------- PacketTimeSyncOffset -----------------*/

  async command bool PacketTimeSyncOffset.isSet(message_t *msg) {
    return call TimeSyncFlag.get(msg);
  }


  async command uint8_t PacketTimeSyncOffset.get(message_t *msg) {
    return call RadioPacket.headerLength(msg) + call RadioPacket.payloadLength(msg) - sizeof(timesync_absolute_t);
  }


  async command void PacketTimeSyncOffset.clear(message_t *msg) {
    call TimeSyncFlag.clear(msg);
  }


  async command void PacketTimeSyncOffset.set(message_t *msg, uint8_t value) {
    // we do not store the value, the time sync field is always the last 4 bytes
    RADIO_ASSERT( call PacketTimeSyncOffset.get(msg) == value );
    call TimeSyncFlag.set(msg);
  }


  /*----------------- PacketLinkQuality -----------------*/

  async command bool PacketLinkQuality.isSet(message_t *msg) {
    return TRUE;
  }


  async command uint8_t PacketLinkQuality.get(message_t *msg) {
    return getMeta(msg)->lqi;
  }


  async command void PacketLinkQuality.clear(message_t *msg) { }


  async command void PacketLinkQuality.set(message_t *msg, uint8_t value) {
    getMeta(msg)->lqi = value;
  }


#ifdef notdef
  ieee154_simple_header_t* getIeeeHeader(message_t* msg) {
    return (ieee154_simple_header_t *) msg;
  }
#endif


  async command error_t PacketAcknowledgements.requestAck(message_t *msg) {
    //call SoftwareAckConfig.setAckRequired(msg, TRUE);
//    getIeeeHeader(msg)->fcf |= (1 << IEEE154_FCF_ACK_REQ);
    return SUCCESS;
  }


  async command error_t PacketAcknowledgements.noAck(message_t* msg) {
//    getIeeeHeader(msg)->fcf &= ~(uint16_t)(1 << IEEE154_FCF_ACK_REQ);
    return SUCCESS;
  }


  async command bool PacketAcknowledgements.wasAcked(message_t* msg) {
#ifdef SI446X_HARDWARE_ACK
    return call AckReceivedFlag.get(msg);
#else
    return FALSE;
#endif
  }


  async event void Panic.hook() {
    dump_radio();
#ifdef notdef
    call CSN.set();
    call CSN.clr();
    call CSN.set();
    drs(TRUE);
    nop();
#endif
  }


#ifndef REQUIRE_PLATFORM
  /*
   * We always require Platform.usecsRaw to be working.
   *
   *  default async command uint16_t Platform.usecsRaw()   { return 0; }
   */

  default async command uint16_t Platform.jiffiesRaw() { return 0; }
#endif

#ifndef REQUIRE_PANIC
  default async command void Panic.panic(uint8_t pcode, uint8_t where, uint16_t arg0,
					 uint16_t arg1, uint16_t arg2, uint16_t arg3) { }
  default async command void  Panic.warn(uint8_t pcode, uint8_t where, uint16_t arg0,
					 uint16_t arg1, uint16_t arg2, uint16_t arg3) { }
#endif
}