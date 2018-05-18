# Copyright (c) 2017-2018, Daniel J. Maltbie, Eric B. Decker
# All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# See COPYING in the top level directory of this source tree.
#
# Contact: Daniel J. Maltbie <dmaltbie@daloma.org>
#          Eric B. Decker <cire831@gmail.com>

'''Core Data Type decoders and objects'''

from   __future__         import print_function

__version__ = '0.3.0.dev1'

import binascii
from   collections  import OrderedDict

from   base_objs    import *
from   sirf_headers import sirf_hdr_obj
from   sirf_headers import sirf_swver_obj

from   sirf_defs    import *
import sirf_defs    as     sirf


########################################################################
#
# Core Decoders
#
########################################################################

#
# REBOOT decoder, dt_reboot_obj, owcb_obj
#

def decode_reboot(level, offset, buf, obj):
    consumed  = obj.set(buf)
    consumed += owcb_obj.set(buf[consumed:])
    return consumed


#
# VERSION decoder, dt_version_obj, image_info_obj
#

def decode_version(level, offset, buf, obj):
    consumed  = obj.set(buf)
    consumed += image_info_obj.set(buf[consumed:])
    return consumed


#
# GPS RAW decoder
#
# main gps raw decoder, decodes DT_GPS_RAW_SIRFBIN
# dt_gps_raw_obj, 2nd level decode on mid
#

def decode_gps_raw(level, offset, buf, obj):
    consumed = obj.set(buf)

    if obj['sirf_hdr']['start'].val != SIRF_SOP_SEQ:
        return consumed - len(sirf_hdr_obj)

    mid = obj['sirf_hdr']['mid'].val

    try:
        sirf.mid_count[mid] += 1
    except KeyError:
        sirf.mid_count[mid] = 1

    v = sirf.mid_table.get(mid, (None, None, None, ''))
    decoder     = v[MID_DECODER]            # dt function
    decoder_obj = v[MID_OBJECT]             # dt object
    if not decoder:
        if (level >= 5):
            print('*** no decoder/obj defined for mid {}'.format(mid))
        return consumed
    return consumed + decoder(level, offset, buf[consumed:], decoder_obj)


########################################################################
#
# Core Header objects
#
########################################################################

rtctime_obj = aggie(OrderedDict([
    ('sub_sec', atom(('<H', '{}'))),
    ('sec',     atom(('<B', '{}'))),
    ('min',     atom(('<B', '{}'))),
    ('hr',      atom(('<B', '{}'))),
    ('dow',     atom(('<B', '{}'))),
    ('day',     atom(('<B', '{}'))),
    ('mon',     atom(('<B', '{}'))),
    ('year',    atom(('<H', '{}'))),
]))

dt_hdr_obj = aggie(OrderedDict([
    ('len',     atom(('<H', '{}'))),
    ('type',    atom(('<H', '{}'))),
    ('recnum',  atom(('<I', '{}'))),
    ('rt',      rtctime_obj),
    ('recsum',  atom(('<H', '0x{:04x}'))),
]))

dt_simple_hdr   = aggie(OrderedDict([
    ('hdr', dt_hdr_obj),
]))

dt_reboot_obj   = aggie(OrderedDict([
    ('hdr',       dt_hdr_obj),
    ('prev_sync', atom(('<I', '{:08x}'))),
    ('majik',     atom(('<I', '{:08x}'))),
    ('core_rev',  atom(('<I', '{:08x}'))),
    ('base',      atom(('<I', '{:08x}'))),
]))

#
# reboot is followed by the ow_control_block
# We want to decode that as well.  native order, little endian.
# see OverWatch/overwatch.h.
#
owcb_obj        = aggie(OrderedDict([
    ('ow_sig',          atom(('<I', '0x{:08x}'))),
    ('rpt',             atom(('<I', '0x{:08x}'))),
    ('boot_time',       rtctime_obj),
    ('prev_boot',       rtctime_obj),
    ('reset_status',    atom(('<I', '0x{:08x}'))),
    ('reset_others',    atom(('<I', '0x{:08x}'))),
    ('from_base',       atom(('<I', '0x{:08x}'))),
    ('panic_count',     atom(('<I', '{}'))),
    ('fault_gold',      atom(('<I', '0x{:08x}'))),
    ('fault_nib',       atom(('<I', '0x{:08x}'))),
    ('subsys_disable',  atom(('<I', '0x{:08x}'))),
    ('ow_sig_b',        atom(('<I', '0x{:08x}'))),
    ('ow_req',          atom(('<B', '{}'))),
    ('reboot_reason',   atom(('<B', '{}'))),
    ('ow_boot_mode',    atom(('<B', '{}'))),
    ('owt_action',      atom(('<B', '{}'))),
    ('reboot_count',    atom(('<I', '{}'))),
    ('strange',         atom(('<I', '{}'))),
    ('strange_loc',     atom(('<I', '0x{:04x}'))),
    ('chk_fails',       atom(('<I', '{}'))),
    ('ow_sig_c',        atom(('<I', '0x{:08x}')))
]))


dt_version_obj  = aggie(OrderedDict([
    ('hdr',       dt_hdr_obj),
    ('base',      atom(('<I', '{:08x}'))),
]))


hw_version_obj      = aggie(OrderedDict([
    ('rev',       atom(('<B', '{:x}'))),
    ('model',     atom(('<B', '{:x}'))),
]))


image_version_obj   = aggie(OrderedDict([
    ('build',     atom(('<H', '{:x}'))),
    ('minor',     atom(('<B', '{:x}'))),
    ('major',     atom(('<B', '{:x}'))),
]))


IMG_DESC_MAX = 44
STAMP_MAX    = 30

image_info_obj  = aggie(OrderedDict([
    ('ii_sig',    atom(('<I', '0x{:08x}'))),
    ('im_start',  atom(('<I', '0x{:08x}'))),
    ('im_len',    atom(('<I', '0x{:08x}'))),
    ('ver_id',    image_version_obj),
    ('im_chk',    atom(('<I', '0x{:08x}'))),
    ('image_desc',atom(('44s', '{:s}'))),
    ('repo0',     atom(('44s', '{:s}'))),
    ('repo1',     atom(('44s', '{:s}'))),
    ('stamp_date',atom(('30s', '{:s}'))),
    ('hw_ver',    hw_version_obj),
]))


dt_sync_obj     = aggie(OrderedDict([
    ('hdr',       dt_hdr_obj),
    ('prev_sync', atom(('<I', '{:x}'))),
    ('majik',     atom(('<I', '{:08x}'))),
]))


# EVENT
event_names = {
     1: "SURFACED",
     2: "SUBMERGED",
     3: "DOCKED",
     4: "UNDOCKED",

     5: "GPS_GEO",
     6: "GPS_XYZ",
     7: "GPS_TIME",

     8: "SSW_DELAY_TIME",
     9: "SSW_BLK_TIME",
    10: "SSW_GRP_TIME",
    11: "PANIC_WARN",

    32: "GPS_BOOT",
    33: "GPS_BOOT_TIME",
    49: "GPS_BOOT_FAIL",
    50: "GPS_HW_CONFIG",
    34: "GPS_RECONFIG",
    35: "GPS_TURN_ON",
    36: "GPS_STANDBY",
    37: "GPS_TURN_OFF",
    38: "GPS_MPM",
    39: "GPS_FULL_PWR",
    40: "GPS_PULSE",
    41: "GPS_FAST",
    42: "GPS_FIRST",
    43: "GPS_SATS_2",
    44: "GPS_SATS_7",
    45: "GPS_SATS_41",
    46: "GPS_CYCLE_TIME",
    47: "GPS_RX_ERR",
    48: "GPS_AWAKE_S",
    51: "GPS_CMD",
    52: "GPS_RAW_TX",
    53: "GPS_SWVER_TO",
    54: "GPS_CANNED",
    55: "GPS_LOST_INT",
}

PANIC_WARN = 11
GPS_CMD    = 51


# GPS_CMD, first arg of GPS_CMD
gps_cmd_names = {
       0: "NOP",
       1: "TURNON",
       2: "TURNOFF",
       3: "STANDBY",
       4: "POWER_ON",
       5: "POWER_OFF",
       6: "CYCLE",                      # gps position cycle

      16: "AWAKE_STATUS",
      17: "MPM",
      18: "PULSE",
      19: "RESET",
      20: "RAW_TX",
      21: "HIBERNATE",
      22: "WAKE",

    0x80: "CANNED",                     # place holder for canned.

    0xfd: "SLEEP",
    0xfe: "PANIC",
    0xff: "REBOOT",
}


dt_event_obj    = aggie(OrderedDict([
    ('hdr',   dt_hdr_obj),
    ('event', atom(('<H', '{}'))),
    ('pcode', atom(('<B', '{}'))),
    ('w',     atom(('<B', '{}'))),
    ('arg0',  atom(('<I', '0x{:04x}'))),
    ('arg1',  atom(('<I', '0x{:04x}'))),
    ('arg2',  atom(('<I', '0x{:04x}'))),
    ('arg3',  atom(('<I', '0x{:04x}'))),
]))


#
# not implemented yet.
#
dt_debug_obj    = dt_simple_hdr

#
# dt, native, little endian
# used by DT_GPS_VERSION and DT_GPS_RAW_SIRFBIN (gps_raw)
#
dt_gps_hdr_obj = aggie(OrderedDict([
    ('hdr',     dt_hdr_obj),
    ('mark',    atom(('<I', '0x{:04x}'))),
    ('chip',    atom(('B',  '0x{:02x}'))),
    ('dir',     atom(('B',  '{}'))),
    ('pad',     atom(('<H', '{}'))),
]))

dt_gps_ver_obj = aggie(OrderedDict([
    ('gps_hdr',    dt_gps_hdr_obj),
    ('sirf_swver', sirf_swver_obj),
]))

dt_gps_time_obj = dt_simple_hdr
dt_gps_geo_obj  = dt_simple_hdr
dt_gps_xyz_obj  = dt_simple_hdr

dt_sen_data_obj = dt_simple_hdr
dt_sen_set_obj  = dt_simple_hdr

dt_test_obj     = dt_simple_hdr

####
#
# NOTES
#
# A note record consists of a dt_note_t header (same as dt_header_t, a
# simple header) followed by n bytes of note.  typically a printable
# ascii string (yeah, localization is an issue, but not now).
#
dt_note_obj     = dt_simple_hdr
dt_config_obj   = dt_simple_hdr

# DT_GPS_RAW_SIRFBIN, dt, native, little endian
#  sirf data big endian.
dt_gps_raw_obj = aggie(OrderedDict([
    ('gps_hdr',  dt_gps_hdr_obj),
    ('sirf_hdr', sirf_hdr_obj),
]))