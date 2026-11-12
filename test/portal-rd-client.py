#!/usr/bin/env python3
"""portal-rd-client: a RemoteDesktop portal client, as remote support would be.

  portal-rd-client.py [--click X Y] [--type TEXT] [--hold SECONDS]

CreateSession, SelectDevices (keyboard and pointer), ScreenCast.SelectSources
(the monitor), Start -- the person answers on the secure surface -- then the
input asked for, through the portal. Prints one line per step:

  start <response> devices=<n> streams=<node>,...
  clicked X Y / typed TEXT
  closed-by-portal              (the session ended from the other side)
Exit 0 if Start succeeded and the input was sent; 1 if not; 2 on error.
"""
import argparse
import sys
import time

from gi.repository import Gio, GLib

BUS = 'org.freedesktop.portal.Desktop'
PATH = '/org/freedesktop/portal/desktop'
RD = 'org.freedesktop.portal.RemoteDesktop'
SC = 'org.freedesktop.portal.ScreenCast'
BTN_LEFT = 0x110

conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
sender = conn.get_unique_name()[1:].replace('.', '_')
loop = GLib.MainLoop()
counter = [0]


def call(iface, method, args, reply='(o)'):
    return conn.call_sync(BUS, PATH, iface, method, args, GLib.VariantType(reply), Gio.DBusCallFlags.NONE, 200000, None)


def request(iface, method, build):
    """call a portal method that answers with a Request; wait for its Response"""
    counter[0] += 1
    token = 'sgtest%d' % counter[0]
    path = '/org/freedesktop/portal/desktop/request/%s/%s' % (sender, token)
    result = {}

    def on_response(c, s, p, i, sig, params, data):
        result['code'], result['results'] = params.unpack()
        loop.quit()
    sub = conn.signal_subscribe(BUS, 'org.freedesktop.portal.Request', 'Response', path, None,
                                Gio.DBusSignalFlags.NO_MATCH_RULE, on_response, None)
    call(iface, method, build(token))
    GLib.timeout_add_seconds(180, loop.quit)
    loop.run()
    conn.signal_unsubscribe(sub)
    return result.get('code', -1), result.get('results', {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--click', nargs=2, type=float)
    ap.add_argument('--type')
    ap.add_argument('--hold', type=float, default=1)
    a = ap.parse_args()

    code, res = request(RD, 'CreateSession', lambda t: GLib.Variant(
        '(a{sv})', ({'handle_token': GLib.Variant('s', t), 'session_handle_token': GLib.Variant('s', 's' + t)},)))
    if code != 0:
        print('create-session %d' % code)
        return 1
    session = res['session_handle']
    closed = []
    conn.signal_subscribe(BUS, 'org.freedesktop.portal.Session', 'Closed', session, None,
                          Gio.DBusSignalFlags.NONE, lambda *x: closed.append(1), None)
    code, _ = request(RD, 'SelectDevices', lambda t: GLib.Variant(
        '(oa{sv})', (session, {'handle_token': GLib.Variant('s', t), 'types': GLib.Variant('u', 3)})))
    if code != 0:
        print('select-devices %d' % code)
        return 1
    code, _ = request(SC, 'SelectSources', lambda t: GLib.Variant(
        '(oa{sv})', (session, {'handle_token': GLib.Variant('s', t), 'types': GLib.Variant('u', 1)})))
    if code != 0:
        print('select-sources %d' % code)
        return 1
    code, res = request(RD, 'Start', lambda t: GLib.Variant(
        '(osa{sv})', (session, '', {'handle_token': GLib.Variant('s', t)})))
    streams = [s[0] for s in res.get('streams', [])]
    print('start %d devices=%s streams=%s' % (code, res.get('devices', 0), ','.join(map(str, streams))), flush=True)
    if code != 0:
        return 1

    def notify(method, sig, *args):
        conn.call_sync(BUS, PATH, RD, method, GLib.Variant(sig, (session, {}) + args), None,
                       Gio.DBusCallFlags.NONE, 5000, None)

    if a.click and streams:
        notify('NotifyPointerMotionAbsolute', '(oa{sv}udd)', streams[0], a.click[0], a.click[1])
        time.sleep(0.2)
        notify('NotifyPointerButton', '(oa{sv}iu)', BTN_LEFT, 1)
        notify('NotifyPointerButton', '(oa{sv}iu)', BTN_LEFT, 0)
        print('clicked %g %g' % tuple(a.click), flush=True)
        time.sleep(0.5)
    if a.type:
        for ch in a.type:
            sym = 0xff0d if ch == '\n' else ord(ch) if ord(ch) < 0x100 else 0x1000000 | ord(ch)
            notify('NotifyKeyboardKeysym', '(oa{sv}iu)', sym, 1)
            notify('NotifyKeyboardKeysym', '(oa{sv}iu)', sym, 0)
            time.sleep(0.03)
        print('typed %s' % a.type, flush=True)
    end = time.time() + a.hold
    ctx = GLib.MainContext.default()
    while time.time() < end and not closed:
        ctx.iteration(False)
        time.sleep(0.05)
    if closed:
        print('closed-by-portal', flush=True)
    else:
        conn.call_sync(BUS, session, 'org.freedesktop.portal.Session', 'Close', None, None,
                       Gio.DBusCallFlags.NONE, 5000, None)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except GLib.Error as e:
        print('error %s' % e.message)
        sys.exit(2)
