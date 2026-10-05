#!/usr/bin/env python3
# Read the ChromeOS EC charge-control state (EC_CMD_CHARGE_CONTROL v2 GET) over /dev/cros_ec.
# Shows mode (0 NORMAL, 1 IDLE, 2 DISCHARGE) and the battery sustainer bounds (-1 = off).
# Usage: sudo ./ec-charge-control.py
import fcntl, struct, ctypes
IOC = 0xC014EC00
def ec(cmd, ver, out=b'', insz=64):
    buf = bytearray(struct.pack('<IIIII', ver, cmd, len(out), insz, 0xffffffff) + out + b'\0'*max(0, insz-len(out)))
    b = (ctypes.c_char*len(buf)).from_buffer(buf)
    with open('/dev/cros_ec','rb+', buffering=0) as f:
        r = fcntl.ioctl(f, IOC, b)
    return struct.unpack_from('<IIIII', buf)[4], bytes(buf[20:20+max(r,0)])
res, d = ec(0x0096, 2, struct.pack('<IBBHbb', 0, 1, 0, 0, 0, 0), 8)
mode, lower, upper = struct.unpack_from('<Ibb', d)
print('EC charge_control GET result=%d mode=%d sustain lower=%d upper=%d' % (res, mode, lower, upper))
