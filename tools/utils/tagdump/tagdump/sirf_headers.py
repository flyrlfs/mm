# Copyright (c) 2017-2018 Eric B. Decker, Daniel J. Maltbie
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

# object descriptors for gps data blocks

'''sirfbin protocol headers'''

__version__ = '0.2.1.dev2 (sh)'

import binascii
from   decode_base  import *
from   collections  import OrderedDict
from   sirf_defs    import SIRF_END_SIZE

####
#
# Special atom class for sirf_swver
# not a simple value.
# format string must include two strings.  ie. '{} {}'
#

class atom_sirf_swver(object):
    '''sirf_swver atom.  special.
    takes 2-tuple: ('struct_string', 'default_print_format')

    default_print_format must have space for two items.

    optional 3-tuple: (..., ..., formating_function)

    set will set the instance.attribute "val" to the value
    of the atom's decode of the buffer.  swver.val is the 2-tuple,
    (str0, str1).
    '''
    def __init__(self, a_tuple):
        self.s_str = a_tuple[0]
        self.s_rec = struct.Struct(self.s_str)
        self.p_str = a_tuple[1]
        if (len(a_tuple) > 2):
            self.f_str = a_tuple[2]
        else:
            self.f_str = None
        self.val = ('','')

    def __len__(self):
        return len(self.val[0]) + len(self.val[1]) + 2

    def __repr__(self):
        if callable(self.f_str):
            return self.p_str.format(self.f_str(self.val))
        return self.p_str.format(*self.val)

    def set(self, buf):
        '''set the swver val from the buffer

        len0 len1 str0 str1   is what we expect.

        return the number of bytes (size) consumed,
          len(str0) + len(str1) + 2

        store val as the tuple (str0, str1)
        stored strings do NOT include any trailing NUL.
        however, the consumed value returned is the actual
        number of bytes consumed.
        '''
        len0 = buf[0]
        len1 = buf[1]
        str0 = buf[2:len0+2]
        str1 = buf[2+len0:2+len0+len1]
        self.val = ( str0.rstrip('\0'), str1.rstrip('\0') )
        return len(str0) + len(str1) + 2


class atom_sirf_dev_data(object):
    '''sirf_dev_data atom.  special.
    takes 2-tuple: ('struct_string', 'default_print_format')

    default_print_format must have space for two items.

    optional 3-tuple: (..., ..., formating_function)

    set will set the instance.attribute "val" to the value
    of the atom's decode of the buffer.  dev_data.val is the
    string from the buffer.  It is not null terminated, and
    we want to throw away the chksum and terminator so we
    want buf[:-SIRF_END_SIZE]
    '''
    def __init__(self, a_tuple):
        self.s_str = a_tuple[0]
        self.s_rec = struct.Struct(self.s_str)
        self.p_str = a_tuple[1]
        if (len(a_tuple) > 2):
            self.f_str = a_tuple[2]
        else:
            self.f_str = None
        self.val = ('','')

    def __len__(self):
        return len(self.val)

    def __repr__(self):
        if callable(self.f_str):
            return self.p_str.format(self.f_str(self.val))
        return self.p_str.format(self.val)

    def set(self, buf):
        '''set the dev_data val from the buffer

        <string><chksum><term> is what we have in buf.

        return the number of bytes (size) consumed,
          len(string) + checksum + term

        store val as the string
        '''
        self.val = buf[:-SIRF_END_SIZE]
        return len(buf)


#########
#
# list of mids that have sids.
# usage: if mid in mids_w_sids:  <mid has a sid>
#
mids_w_sids = [
     19,  48,  51,  56,  63,  64,  65,  68,  69,  70,  72,  73,  74,  75,
     77,  90,  91,  92,  93, 161, 172, 177, 178, 205, 211, 212, 213, 215,
    216, 218, 219, 220, 221, 225, 233, 232, 233, 234
]


#######
#
# sirfbin header, big endian.
#
# start: 0xa0a2
# len:   big endian, < 2047
# mid:   byte
sirf_hdr_obj = aggie(OrderedDict([
    ('start',   atom(('>H', '0x{:04x}'))),
    ('len',     atom(('>H', '0x{:04x}'))),
    ('mid',     atom(('B',  '0x{:02x}'))),
]))


########################################################################
#
# Gps Raw decode messages
#
# warning GPS messages are big endian.  The surrounding header (the dt header
# etc) is little endian (native order).
#

# navdata (2)
sirf_nav_obj = aggie(OrderedDict([
    ('xpos',  atom(('>i', '{}'))),
    ('ypos',  atom(('>i', '{}'))),
    ('zpos',  atom(('>i', '{}'))),
    ('xvel',  atom(('>h', '{}'))),
    ('yvel',  atom(('>h', '{}'))),
    ('zvel',  atom(('>h', '{}'))),
    ('mode1', atom(('B', '0x{:02x}'))),
    ('hdop',  atom(('B', '0x{:02x}'))),
    ('mode2', atom(('B', '0x{:02x}'))),
    ('week10',atom(('>H', '{}'))),
    ('tow',   atom(('>I', '{}'))),
    ('nsats', atom(('B', '{}'))),
    ('prns',  atom(('12s', '{}', binascii.hexlify))),
]))


# navtrack (4)
sirf_navtrk_obj = aggie(OrderedDict([
    ('week10', atom(('>H', '{}'))),
    ('tow',    atom(('>I', '{}'))),
    ('chans',  atom(('B',  '{}'))),
]))


sirf_navtrk_chan = aggie(OrderedDict([
    ('sv_id',    atom(('B',  '{:2}'))),
    ('sv_az23',  atom(('B',  '{:3}'))),
    ('sv_el2',   atom(('B',  '{:3}'))),
    ('state',    atom(('>H', '0x{:04x}'))),
    ('cno0',     atom(('B',  '{}'))),
    ('cno1',     atom(('B',  '{}'))),
    ('cno2',     atom(('B',  '{}'))),
    ('cno3',     atom(('B',  '{}'))),
    ('cno4',     atom(('B',  '{}'))),
    ('cno5',     atom(('B',  '{}'))),
    ('cno6',     atom(('B',  '{}'))),
    ('cno7',     atom(('B',  '{}'))),
    ('cno8',     atom(('B',  '{}'))),
    ('cno9',     atom(('B',  '{}'))),
]))


# swver (6), its special
sirf_swver_obj = atom_sirf_swver(('', '--<{}>--  --<{}>--'))


# sat vis (13)
sirf_vis_obj     = aggie(OrderedDict([
    ('vis_sats', atom(('B',  '{}'))),
]))

sirf_vis_azel    = aggie(OrderedDict([
    ('sv_id',    atom(('B',  '{}'))),
    ('sv_az',    atom(('>h', '{}'))),
    ('sv_el',    atom(('>h', '{}'))),
]))


# almanac data (14)
sirf_alm_data_obj = aggie(OrderedDict([
    ('sv_id',               atom(('B',   '{}'))),
    ('alm_week_status',     atom(('>H',  '0x{:04x}'))),
    ('data',                atom(('24s', '{}', binascii.hexlify))),
    ('checksum',            atom(('>H',  '0x{:04x}'))),
]))


# ephemeris data (15)
sirf_ephem_data_obj = aggie(OrderedDict([
    ('sv_id',               atom(('B',   '{}'))),
    ('data',                atom(('90s', '{}', binascii.hexlify))),
]))


# OkToSend (18)
sirf_ots_obj = atom(('B', '{}'))


# NavParams (19)
sirf_nav_params_obj = aggie(OrderedDict([
    ('rsvd0',               atom(('>H', '0x{:04x}'))),
    ('pos_calc_mode',       atom(('B',  '0x{:02x}'))),
    ('alt_hold_mode',       atom(('B',  '0x{:02x}'))),
    ('alt_hold_src',        atom(('B',  '0x{:02x}'))),
    ('alt_src_input',       atom(('>h', '0x{:04x}'))),
    ('degraded_mode',       atom(('B',  '0x{:02x}'))),
    ('degraded_timeout',    atom(('B',  '{}'))),
    ('dr_timeout',          atom(('B',  '{}'))),
    ('track_smooth_mode',   atom(('B',  '0x{:02x}'))),
    ('static_nav',          atom(('B',  '0x{:02x}'))),
    ('3sv_least',           atom(('B',  '0x{:02x}'))),
    ('rsvd1',               atom(('>I', '0x{:04x}'))),
    ('dop_mask_mode',       atom(('B',  '0x{:02x}'))),
    ('nav_ele_mask',        atom(('>h', '0x{:04x}'))),
    ('nav_pwr_mask',        atom(('B',  '{}'))),
    ('rsvd2',               atom(('>I', '0x{:04x}'))),
    ('dgps_source',         atom(('B',  '0x{:02x}'))),
    ('dgps_mode',           atom(('B',  '0x{:02x}'))),
    ('dgps_timeout',        atom(('B',  '0x{:02x}'))),
    ('rsvd3',               atom(('>I', '0x{:04x}'))),
    ('lp_push_2_fix',       atom(('B',  '0x{:02x}'))),
    ('lp_on_time',          atom(('>i', '0x{:04x}'))),
    ('lp_interval',         atom(('>i', '{}'))),
    ('user_tasks_ena',      atom(('B',  '0x{:02x}'))),
    ('user_task_int',       atom(('>i', '0x{:04x}'))),
    ('lp_pwr_cycling',      atom(('B',  '0x{:02x}'))),
    ('lp_max_acq_srch',     atom(('>I', '0x{:04x}'))),
    ('lp_max_off_time',     atom(('>I', '0x{:04x}'))),
    ('apm_pwr_duty',        atom(('B',  '0x{:02x}'))),
    ('num_fixes',           atom(('>H', '0x{:04x}'))),
    ('time_btwn_fixes',     atom(('>H', '0x{:04x}'))),
    ('hve_max',             atom(('B',  '0x{:02x}'))),
    ('rsp_time_max',        atom(('B',  '0x{:02x}'))),
    ('time_acq_duty_prio',  atom(('B',  '0x{:02x}'))),
]))


# geodata (41)
sirf_geo_obj = aggie(OrderedDict([
    ('nav_valid',        atom(('>H', '0x{:04x}'))),
    ('nav_type',         atom(('>H', '0x{:04x}'))),
    ('week_x',           atom(('>H', '{}'))),
    ('tow',              atom(('>I', '{}'))),
    ('utc_year',         atom(('>H', '{}'))),
    ('utc_month',        atom(('B', '{}'))),
    ('utc_day',          atom(('B', '{}'))),
    ('utc_hour',         atom(('B', '{}'))),
    ('utc_min',          atom(('B', '{}'))),
    ('utc_ms',           atom(('>H', '{}'))),
    ('sat_mask',         atom(('>I', '0x{:08x}'))),
    ('lat',              atom(('>i', '{}'))),
    ('lon',              atom(('>i', '{}'))),
    ('alt_elipsoid',     atom(('>i', '{}'))),
    ('alt_msl',          atom(('>i', '{}'))),
    ('map_datum',        atom(('B', '{}'))),
    ('sog',              atom(('>H', '{}'))),
    ('cog',              atom(('>H', '{}'))),
    ('mag_var',          atom(('>H', '{}'))),
    ('climb',            atom(('>h', '{}'))),
    ('heading_rate',     atom(('>h', '{}'))),
    ('ehpe',             atom(('>I', '{}'))),
    ('evpe',             atom(('>I', '{}'))),
    ('ete',              atom(('>I', '{}'))),
    ('ehve',             atom(('>H', '{}'))),
    ('clock_bias',       atom(('>i', '{}'))),
    ('clock_bias_err',   atom(('>i', '{}'))),
    ('clock_drift',      atom(('>i', '{}'))),
    ('clock_drift_err',  atom(('>i', '{}'))),
    ('distance',         atom(('>I', '{}'))),
    ('distance_err',     atom(('>H', '{}'))),
    ('head_err',         atom(('>H', '{}'))),
    ('nsats',            atom(('B', '{}'))),
    ('hdop',             atom(('B', '{}'))),
    ('additional_mode',  atom(('B', '0x{:02x}'))),
]))


# 56/42 sifStatus (sifStat)
sirf_ee56_sifStat_obj = aggie(OrderedDict([
    ('sifState',            atom(('B',   '{}'))),
    ('cgeePredState',       atom(('B',   '{}'))),
    ('sifAiding',           atom(('B',   '{}'))),
    ('sgeeDwnLoad',         atom(('B',   '{}'))),
    ('cgeePredTimeLeft',    atom(('>I',  '{}'))),
    ('cgeePredPendingMask', atom(('>I',  '0x{:04x}'))),
    ('svidCGEEpred',        atom(('B',   '{}'))),
    ('sgeeAgeValidity',     atom(('B',   '{}'))),
    ('cgeeAgeValidity',     atom(('32s', '{}', binascii.hexlify))),
]))


# pwr_mode_rsp (90), has SID
sirf_pwr_mode_rsp_obj = aggie(OrderedDict([
    ('sid',              atom(('B', '{}'))),
    ('error',            atom(('>H', '0x{:02x}'))),
    ('reserved',         atom(('>H', '{}'))),
]))


# init_data_src (128)
sirf_init_data_src_obj = aggie(OrderedDict([
    ('ecef_x',           atom(('>i', '{}'))),
    ('ecef_y',           atom(('>i', '{}'))),
    ('ecef_z',           atom(('>i', '{}'))),
    ('clock_drift',      atom(('>i', '{}'))),
    ('tow',              atom(('>I', '{}'))),
    ('week_x',           atom(('>H', '{}'))),
    ('chans',            atom(('B',  '{}'))),
    ('reset_config',     atom(('B',  '0x{:02x}'))),
]))


# almanac set (130)
sirf_alm_set_obj = aggie(OrderedDict([
    ('data',             atom(('892s', '{}', binascii.hexlify))),
]))


# ephemeris set (149)
sirf_ephem_set_obj = aggie(OrderedDict([
    ('data',             atom(('90s', '{}', binascii.hexlify))),
]))


# set msg rate (166)
sirf_set_msg_rate_obj = aggie(OrderedDict([
    ('mode',             atom(('B', '{}'))),
    ('mid',              atom(('B', '{}'))),
    ('rate',             atom(('B', '{}'))),
    ('rsvd0',            atom(('B', '{}'))),
    ('rsvd1',            atom(('B', '{}'))),
    ('rsvd2',            atom(('B', '{}'))),
    ('rsvd3',            atom(('B', '{}'))),
]))


# HW Config Response
sirf_hw_conf_rsp_obj = aggie(OrderedDict([
    ('hw_config',        atom(('B',  '{}'))),
    ('nominal_upper',    atom(('B',  '{}'))),
    ('nominal_freq',     atom(('>I', '{}'))),
    ('nw_enhance',       atom(('B',  '{}'))),
]))


# pwr_mode_req (218), has SID
sirf_pwr_mode_req_obj = aggie(OrderedDict([
    ('sid',              atom(('B',  '{}'))),
    ('timeout',          atom(('B',  '{}'))),
    ('control',          atom(('B',  '{}'))),
    ('reserved',         atom(('>H', '{}'))),
]))


# statistics (225/6)
sirf_statistics_obj    = aggie(OrderedDict([
    ('sid',             atom(('B',  '{}'))),
    ('ttff_reset',      atom(('>H', '{}'))),
    ('ttff_aiding',     atom(('>H', '{}'))),
    ('ttff_nav',        atom(('>H', '{}'))),
    ('pae_n',           atom(('>i', '{}'))),
    ('pae_e',           atom(('>i', '{}'))),
    ('pae_d',           atom(('>i', '{}'))),
    ('time_aiding_err', atom(('>i', '{}'))),
    ('freq_aiding_err', atom(('>h', '{}'))),
    ('pos_unc_horz',    atom(('B',  '{}'))),
    ('pos_unc_vert',    atom(('>H', '{}'))),
    ('time_unc',        atom(('B',  '{}'))),
    ('freq_unc',        atom(('B',  '{}'))),
    ('n_aided_ephem',   atom(('B',  '{}'))),
    ('n_aided_acq',     atom(('B',  '{}'))),
    ('nav_mode',        atom(('B',  '{}'))),
    ('pos_mode',        atom(('B',  '{}'))),
    ('status',          atom(('>H', '{}'))),
    ('start_mode',      atom(('B',  '{}'))),
    ('reserved',        atom(('B',  '{}'))),
]))


# dev_data, MID 255
# following the MID is ascii data, the length of the sirfbin
# packet tells how long this string is.  The buffer contains
# the string followed by chksum and terminating sequence.

sirf_dev_data_obj = atom_sirf_dev_data(('', '{}'))
