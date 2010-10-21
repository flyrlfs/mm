
#no threads

source ../../.gdb2618
source ../../.gdb_mm

set remoteaddresssize 0d64
set remotetimeout 0d999999
target remote localhost:2000

disp/i $pc
x/i $pc
set pri ele 0

define inst
p/d SDspP__last_reset_time_uis
p/d SDspP__last_reset_time_mis
p/d SDspP__last_read_time_uis
p/d SDspP__last_read_time_mis
p/d SDspP__last_write_time_uis
p/d SDspP__last_write_time_mis
end

b RealMainP.nc:75
b RealMainP.nc:80
b SchedulerBasicP.nc:151
b SchedulerBasicP.nc:148
b VirtualizeTimerC.nc:81
dis

# 5 debug_break  (optimized out)
# b PanicP.nc:62

# 6 panic
b PanicP.nc:78
comm
printf "pcode: 0d%d (0x%0x)  where: 0d%d  0x%04x 0x%04x 0x%04x 0x%04x\n",_p,_p, _w, _a0, _a1, _a2, _a3
end

# 7
# b mmP.nc:44

# 7
b FileSystemP.nc:285
comm
p FileSystemP__fsc
end

#b mmSyncP.nc:89
#b DTSenderP.nc:95

# 8
b SDspP.nc:631
comm
p/d SDspP__last_pwr_on_first_cmd_uis
p/d SDspP__last_full_reset_time_uis
p/d SDspP__last_reset_time_uis
p/d SDspP__last_reset_time_mis
end
dis 8

# 9
b SDspP.nc:920
comm
p SDspP__last_write_time_mis
end


# 10
b SDspP.nc:1047
comm
p SDspP__last_erase_time_mis
end


# ******************************************************************************
# gps start
#b GPSP.nc:448

# gps finish
#b GPSP.nc:301

# 7 Msg Collect too big
#b GPSMsgP.nc:538

# 8 Msg checksum fail
#b GPSMsgP.nc:561

# GPSP.nc
#  9 finish      502
# 10 signal surface mmControlP.nc:107
# 11 start       669
# 14 msgBoundary 1102

# 9 finish
#b GPSP.nc:502

# b sig_TIMERA0_VECTOR
# b sig_TIMERA1_VECTOR
# b sig_TIMERB0_VECTOR
# b sig_TIMERB1_VECTOR

define nx
fini
ni 3
si 2
end

define noint
printf "cur sr: %02x\n", $r2
set $r2=0
end