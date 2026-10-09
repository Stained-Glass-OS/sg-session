/* A program on the session bus that holds org.freedesktop.ScreenSaver
 * inhibitions, for test/screensaver-test.sh. Commands on stdin, one a line:
 *   inhibit APP        -> prints "cookie N"
 *   uninhibit N        -> prints "ok" or "error NAME"
 *   activity | lock    -> SimulateUserActivity / Lock, prints "ok"
 *   active             -> prints "active 0|1"
 *   quit
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#include <dbus/dbus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DBusMessage *call(DBusConnection *conn, const char *method, int type, void *arg, int type2, void *arg2)
{
    DBusMessage *msg = dbus_message_new_method_call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                                                    "org.freedesktop.ScreenSaver", method);
    DBusMessage *reply;
    DBusError err;

    if (type != DBUS_TYPE_INVALID) dbus_message_append_args(msg, type, arg, DBUS_TYPE_INVALID);
    if (type2 != DBUS_TYPE_INVALID) dbus_message_append_args(msg, type2, arg2, DBUS_TYPE_INVALID);
    dbus_error_init(&err);
    reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
    if (!reply) printf("error %s\n", err.name ? err.name : "?");
    dbus_error_free(&err);
    dbus_message_unref(msg);
    return reply;
}

int main(void)
{
    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SESSION, NULL);
    char line[256];

    if (!conn) { printf("no bus\n"); return 1; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("ready\n");
    while (fgets(line, sizeof(line), stdin))
    {
        DBusMessage *reply;
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "inhibit ", 8))
        {
            const char *app = line + 8, *reason = "test";
            dbus_uint32_t cookie = 0;
            if ((reply = call(conn, "Inhibit", DBUS_TYPE_STRING, &app, DBUS_TYPE_STRING, &reason)))
            {
                dbus_message_get_args(reply, NULL, DBUS_TYPE_UINT32, &cookie, DBUS_TYPE_INVALID);
                printf("cookie %u\n", cookie);
                dbus_message_unref(reply);
            }
        }
        else if (!strncmp(line, "uninhibit ", 10))
        {
            dbus_uint32_t cookie = strtoul(line + 10, NULL, 10);
            if ((reply = call(conn, "UnInhibit", DBUS_TYPE_UINT32, &cookie, DBUS_TYPE_INVALID, NULL)))
            {
                printf(dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_ERROR ? "error\n" : "ok\n");
                dbus_message_unref(reply);
            }
        }
        else if (!strcmp(line, "activity") || !strcmp(line, "lock"))
        {
            if ((reply = call(conn, !strcmp(line, "lock") ? "Lock" : "SimulateUserActivity",
                              DBUS_TYPE_INVALID, NULL, DBUS_TYPE_INVALID, NULL)))
            {
                printf("ok\n");
                dbus_message_unref(reply);
            }
        }
        else if (!strcmp(line, "active"))
        {
            dbus_bool_t active = 0;
            if ((reply = call(conn, "GetActive", DBUS_TYPE_INVALID, NULL, DBUS_TYPE_INVALID, NULL)))
            {
                dbus_message_get_args(reply, NULL, DBUS_TYPE_BOOLEAN, &active, DBUS_TYPE_INVALID);
                printf("active %d\n", active);
                dbus_message_unref(reply);
            }
        }
        else if (!strcmp(line, "quit")) break;
    }
    return 0;
}
