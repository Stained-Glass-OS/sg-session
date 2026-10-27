#!/usr/bin/python3
"""sni-item.py LOG -- a stand-in Linux tray program for sni-test.sh: a
StatusNotifierItem (red 32x32 pixmap, title "Gate Item", tooltip) with a
dbusmenu (Open, a separator, More > Sub, a disabled item, Quit), registered
with the session's watcher. Every call it gets is a line in LOG."""
import os
import sys
from gi.repository import Gio, GLib

LOG = sys.argv[1]


def log(s):
    with open(LOG, 'a') as f:
        f.write(s + '\n')


ITEM_XML = """<node><interface name="org.kde.StatusNotifierItem">
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="IconName" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
<property name="ToolTip" type="(sa(iiay)ss)" access="read"/><property name="Menu" type="o" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/>
<signal name="NewIcon"/><signal name="NewTitle"/>
</interface></node>"""
MENU_XML = """<node><interface name="com.canonical.dbusmenu">
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
<arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"""

red = bytes([0xFF, 0xE0, 0x20, 0x20]) * (32 * 32)   # ARGB


def node(i, props, kids=()):
    return GLib.Variant('(ia{sv}av)', (i, props, [GLib.Variant('(ia{sv}av)', k) for k in kids]))


def layout():
    def v(t, x):
        return GLib.Variant(t, x)
    sub = (5, {'label': v('s', 'Sub')}, [])
    kids = [(1, {'label': v('s', '_Open')}, []),
            (2, {'type': v('s', 'separator')}, []),
            (4, {'label': v('s', 'More'), 'children-display': v('s', 'submenu')}, [sub]),
            (6, {'label': v('s', 'Disabled'), 'enabled': v('b', False)}, []),
            (3, {'label': v('s', 'Quit')}, [])]
    return (0, {}, kids)


def to_variant(n):
    i, props, kids = n
    return (i, props, [GLib.Variant('(ia{sv}av)', to_variant(k)) for k in kids])


def item_call(con, sender, path, iface, method, params, inv):
    log('%s %s' % (method, ' '.join(str(x) for x in params.unpack())))
    inv.return_value(None)


def item_prop(con, sender, path, iface, prop):
    vals = {
        'Category': GLib.Variant('s', 'ApplicationStatus'), 'Id': GLib.Variant('s', 'gate-item'),
        'Title': GLib.Variant('s', 'Gate Item'), 'Status': GLib.Variant('s', 'Active'),
        'IconName': GLib.Variant('s', ''),
        'IconPixmap': GLib.Variant('a(iiay)', [(32, 32, red)]),
        'ToolTip': GLib.Variant('(sa(iiay)ss)', ('', [], 'Gate Item', 'all is well')),
        'Menu': GLib.Variant('o', '/MenuBar'), 'ItemIsMenu': GLib.Variant('b', False),
    }
    return vals.get(prop)


def menu_call(con, sender, path, iface, method, params, inv):
    if method == 'GetLayout':
        inv.return_value(GLib.Variant('(u(ia{sv}av))', (1, to_variant(layout()))))
    elif method == 'Event':
        a = params.unpack()
        log('Event %d %s' % (a[0], a[1]))
        inv.return_value(None)
        if a[0] == 3:
            GLib.timeout_add(200, loop.quit)
    elif method == 'AboutToShow':
        inv.return_value(GLib.Variant('(b)', (False,)))


con = Gio.bus_get_sync(Gio.BusType.SESSION, None)
con.register_object('/StatusNotifierItem', Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0], item_call, item_prop, None)
con.register_object('/MenuBar', Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0], menu_call, None, None)
name = 'org.kde.StatusNotifierItem-%d-1' % os.getpid()
Gio.bus_own_name_on_connection(con, name, Gio.BusNameOwnerFlags.NONE, None, None)
loop = GLib.MainLoop()


def register():
    try:
        con.call_sync('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher',
                      'RegisterStatusNotifierItem', GLib.Variant('(s)', (name,)), None, Gio.DBusCallFlags.NONE, 3000, None)
        log('registered %s' % name)
    except GLib.Error as e:
        log('register failed: %s' % e.message)
    return False


GLib.timeout_add(300, register)
loop.run()
log('exit')
