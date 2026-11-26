#!/usr/bin/env python3
"""A minimal VNC (RFB 3.8) viewer for the remote-support gate.

Connects without authentication ("None", which the gate's VNC server is set
to, on loopback only), asks for 32-bit raw frames, and either saves the whole
screen as a PPM or sends keys and pointer events -- what a technician's
viewer does. Usage:

  rfb-client.py HOST:PORT shot FILE.ppm
  rfb-client.py HOST:PORT type TEXT          (keysyms of the characters)
  rfb-client.py HOST:PORT key NAME...        (Return, Escape, Tab, ctrl-alt-del)
  rfb-client.py HOST:PORT click X Y
  rfb-client.py HOST:PORT hold SECONDS       (stay connected, as a viewer left open)

Exit 0 on success; messages on stderr.
"""
import socket
import struct
import sys
import time

KEYSYMS = {'Return': 0xff0d, 'Escape': 0xff1b, 'Tab': 0xff09, 'BackSpace': 0xff08,
           'Control_L': 0xffe3, 'Alt_L': 0xffe9, 'Delete': 0xffff, 'Super_L': 0xffeb,
           'space': 0x20, 'Shift_L': 0xffe1}


def recvall(s, n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError('the server closed the connection')
        b += c
    return b


def connect(addr):
    host, port = addr.rsplit(':', 1)
    s = socket.create_connection((host, int(port)), timeout=30)
    ver = recvall(s, 12)
    if not ver.startswith(b'RFB '):
        raise RuntimeError('not a VNC server: %r' % ver)
    s.sendall(b'RFB 003.008\n')
    n = recvall(s, 1)[0]
    if n == 0:
        ln = struct.unpack('>I', recvall(s, 4))[0]
        raise RuntimeError('refused: %s' % recvall(s, ln).decode(errors='replace'))
    types = recvall(s, n)
    if 1 not in types:
        raise RuntimeError('the server wants authentication %r' % list(types))
    s.sendall(b'\x01')
    if struct.unpack('>I', recvall(s, 4))[0] != 0:
        raise RuntimeError('security handshake failed')
    s.sendall(b'\x01')  # shared
    w, h = struct.unpack('>HH', recvall(s, 4))
    recvall(s, 16)
    ln = struct.unpack('>I', recvall(s, 4))[0]
    name = recvall(s, ln).decode(errors='replace')
    # 32 bpp, depth 24, little endian, true colour, BGRX in memory
    s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    s.sendall(struct.pack('>BxHi', 2, 1, 0))  # encodings: raw only
    return s, w, h, name


def shot(s, w, h, path, settle=2.0):
    fb = bytearray(w * h * 4)
    # a server's first picture may be from before it looked (an empty
    # buffer): ask, wait, and keep what the last full request brings
    s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
    read_update(s, w, fb)
    time.sleep(settle)
    s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
    read_update(s, w, fb)
    out = bytearray(w * h * 3)
    out[0::3] = fb[2::4]
    out[1::3] = fb[1::4]
    out[2::3] = fb[0::4]
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, h))
        f.write(out)


def read_update(s, w, fb):
    got = False
    deadline = time.time() + 30
    while not got and time.time() < deadline:
        t = recvall(s, 1)[0]
        if t == 0:
            recvall(s, 1)
            nrect = struct.unpack('>H', recvall(s, 2))[0]
            for _ in range(nrect):
                x, y, rw, rh, enc = struct.unpack('>HHHHi', recvall(s, 12))
                if enc != 0:
                    raise RuntimeError('unexpected encoding %d' % enc)
                data = recvall(s, rw * rh * 4)
                for row in range(rh):
                    o = ((y + row) * w + x) * 4
                    fb[o:o + rw * 4] = data[row * rw * 4:(row + 1) * rw * 4]
            got = True
        elif t == 2:
            pass  # bell
        elif t == 3:
            recvall(s, 3)
            ln = struct.unpack('>I', recvall(s, 4))[0]
            recvall(s, ln)
        elif t == 1:
            recvall(s, 1)
            first, n = struct.unpack('>HH', recvall(s, 4))
            recvall(s, n * 6)
        else:
            raise RuntimeError('unexpected message %d' % t)
    if not got:
        raise RuntimeError('no frame')


def key(s, sym, down):
    s.sendall(struct.pack('>BBxxI', 4, 1 if down else 0, sym))


def tap(s, sym):
    key(s, sym, True)
    time.sleep(0.03)
    key(s, sym, False)
    time.sleep(0.05)


def main():
    addr, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    s, w, h, name = connect(addr)
    print('connected to "%s" %dx%d' % (name, w, h), file=sys.stderr)
    if cmd == 'shot':
        shot(s, w, h, args[0])
    elif cmd == 'type':
        for ch in args[0]:
            tap(s, ord(ch))
    elif cmd == 'key':
        for k in args:
            if k == 'ctrl-alt-del':
                for x in ('Control_L', 'Alt_L', 'Delete'):
                    key(s, KEYSYMS[x], True)
                    time.sleep(0.03)
                for x in ('Delete', 'Alt_L', 'Control_L'):
                    key(s, KEYSYMS[x], False)
                    time.sleep(0.03)
            else:
                tap(s, KEYSYMS[k])
    elif cmd == 'hold':
        deadline = time.time() + float(args[0])
        fb = bytearray(w * h * 4)
        while time.time() < deadline:
            s.sendall(struct.pack('>BBHHHH', 3, 1, 0, 0, w, h))
            s.settimeout(max(0.5, deadline - time.time()))
            try:
                read_update(s, w, fb)
            except (socket.timeout, OSError):
                break
            time.sleep(0.5)
    elif cmd == 'click':
        x, y = int(args[0]), int(args[1])
        s.sendall(struct.pack('>BBHH', 5, 0, x, y))
        time.sleep(0.05)
        s.sendall(struct.pack('>BBHH', 5, 1, x, y))
        time.sleep(0.05)
        s.sendall(struct.pack('>BBHH', 5, 0, x, y))
    else:
        raise SystemExit('unknown command ' + cmd)
    time.sleep(0.5)
    s.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # the gate reads the message
        print('rfb-client: %s' % e, file=sys.stderr)
        sys.exit(1)
