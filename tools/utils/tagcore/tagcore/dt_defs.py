# Copyright (c) 2018 Eric B. Decker
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
# Contact: Eric B. Decker <cire831@gmail.com>

'''
data type (data block) basic definitions

define low level record manipulation and basic definitions for dblk
stream record headers.
'''

from   __future__         import print_function

import struct
from   misc_utils   import dump_buf
from   core_headers import dt_hdr_obj

__version__ = '0.3.0.dev1'


# __all__ exports commonly used definitions.  It gets used
# when someone does a wild import of this module.

__all__ = [
    # object identifiers in each dt_record tuple
    'DTR_REQ_LEN',
    'DTR_DECODER',
    'DTR_EMITTERS',
    'DTR_OBJ',
    'DTR_NAME',

    # dt record types
    'DT_REBOOT',
    'DT_VERSION',
    'DT_SYNC',
    'DT_EVENT',
    'DT_DEBUG',
    'DT_GPS_VERSION',
    'DT_GPS_TIME',
    'DT_GPS_GEO',
    'DT_GPS_XYZ',
    'DT_SENSOR_DATA',
    'DT_SENSOR_SET',
    'DT_TEST',
    'DT_NOTE',
    'DT_CONFIG',
    'DT_GPS_RAW_SIRFBIN',

    'rec0',
    'rtctime_str',
    'dt_name',
    'print_hdr',
    'print_record',
]


# dt_records
#
# dictionary of all data_typed records we understand dict key is the
# record id (rtype).  Contents of each entry is a vector consisting of
# (req_len, decoder, object, name).
#
# req_len: required length if any.  0 if variable and not checked.
# decoder: a pointer to a routne that knows how to decode and display
#          the record
# object:  a pointer to an object descriptor for this record.
# name:    a string denoting the printable name for this record.
#
#
# when decoder code is imported, it is required to populate its entry
# in the dt_records dictionary.  Each decode is required to know its
# key and uses that to insert its vector (req_len. decode, obj, name)
# into the dictionary.
#
# dt_count keeps track of what rtypes we have seen.
#

dt_records = {}
dt_count   = {}

DTR_REQ_LEN  = 0                        # required length
DTR_DECODER  = 1                        # decode said rtype
DTR_EMITTERS = 2                        # emitters for said record struct
DTR_OBJ      = 3                        # rtype obj descriptor
DTR_NAME     = 4                        # rtype name


# all dt parts are native and little endian

# headers are accessed via the dt_simple_hdr object
# hdr object dt, native, little endian

dt_sync_majik = 0xdedf00ef
quad_struct   = struct.Struct('<I')      # for searching for syncs

DT_REBOOT               = 1
DT_VERSION              = 2
DT_SYNC                 = 3
DT_EVENT                = 4
DT_DEBUG                = 5
DT_GPS_VERSION          = 16
DT_GPS_TIME             = 17
DT_GPS_GEO              = 18
DT_GPS_XYZ              = 19
DT_SENSOR_DATA          = 20
DT_SENSOR_SET           = 21
DT_TEST                 = 22
DT_NOTE                 = 23
DT_CONFIG		= 24
DT_GPS_RAW_SIRFBIN      = 32


# offset    recnum     rtime    len   dt name         offset
# 99999999 9999999  3599.999969 999   99 xxxxxxxxxxxx @999999 (0xffffff) [0xffff]
rec_title_str = "---  offset    recnum    rtime    len  dt  name"

# common format used by all records.  (rec0)
# ---  offset    recnum    rtime    len  dt  name
# --- @99999999 9999999 3599.999969 999  99  ssssss
# --- @512            1 1099.105926 120   1  REBOOT  unset -> GOLD  [GOLD]  (r 3/0 p)

rec0  = '--- @{:<8d} {:7d} {:>11s} {:3d}  {:2d}  {:s}'

# header format when normal processing doesn't work (see print_record)
rec_format    = "@{:<8d} {:7d} {:>11s} {:<3d}  {:2}  {:12s} @{} (0x{:06x}) [0x{:04x}]"


def rtctime_str(rtctime, fmt = 'basic'):
    '''
    convert a rtctime into a simple 'basic' string displaying the time
    as seconds.us since the top of the hour.

    input:      rtctime, a rtctime_obj
    output:     string seconds.us since the top of the hour

    ie. Thu 17 May 00:04:29 UTC 2018 9589 jiffies
        2018-05-17-(4)-00:04:29.9589j is displayed as '269.292633'

        269.292633      2018-05-17-(4)-00:04:29.9589j  (0x2575
        298.999969      2018-05-17-(4)-00:04:58.32767j (0x7fff)
        299.000000      2018-05-17-(4)-00:04:59.0j     (0x0000)
        299.999969      2018-05-17-(4)-00:04:59.32767j (0x7fff)
        300.000000      2018-05-17-(4)-00:05:00.0j     (0x0000)
       3599.999969      2018-05-17-(4)-00:59:59.32767j (0x7fff)
          0.000000      2018-05-17-(4)-01:00:00.0      (0x0000)

    the rtctime object must be set prior to calling get_basic_rt.
    '''
    rt = rtctime
    rt_secs  = rt['min'].val * 60 + rt['sec'].val
    rt_subsecs = (rt['sub_sec'].val * 1000000) / 32768
    return '{:d}.{:06d}'.format(rt_secs, rt_subsecs)


def dt_name(rtype):
    v = dt_records.get(rtype, (0, None, None, None, 'unk'))
    return v[DTR_NAME]


def print_hdr(obj):
    #  rec       rtime rtype name
    #    1 3599.999969  (20) REBOOT

    rtype    = obj['hdr']['type'].val
    recnum   = obj['hdr']['recnum'].val
    rtctime  = obj['hdr']['rt']
    brt      = rtctime_str(rtctime)
    print('{:4} {:>11} ({:2}) {:6} --'.format(recnum, brt,
        rtype, dt_name(rtype)), end = '')


# used for identifing records that have problems.
def print_record(offset, buf):
    hdr = dt_hdr_obj
    hdr_len = len(hdr)
    if (len(buf) < hdr_len):
        print('*** print_record, buf too small for a header, wanted {}, ' + \
              'got {}, @{}'.format(hdr_len, len(buf), offset))
        dump_buf(buf, '    ')
    else:
        hdr.set(buf)
        rlen     = hdr['len'].val
        rtype    = hdr['type'].val
        recnum   = hdr['recnum'].val
        rtctime  = hdr['rt']
        brt      = rtctime_str(rtctime)
        recsum   = hdr['recsum'].val
        print(rec_format.format(offset, recnum, brt, rlen, rtype,
            dt_name(rtype), offset, offset, recsum))