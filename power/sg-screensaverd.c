/* sg-screensaverd: the session's org.freedesktop.ScreenSaver service.
 *
 * Programs that want the screen kept on -- a video player, a presentation,
 * Wine's power requests and SetThreadExecutionState -- ask through this
 * standard interface on the session bus (Inhibit/UnInhibit). While any
 * inhibition is held, this service holds an INHIBIT connection to the
 * compositor's control socket, which keeps the compositor's idle
 * notifications from firing -- and with them sg-settingsctl's swayidle
 * timers: "turn off the screen after" and "put the computer to sleep after".
 *
 * An inhibition goes when its program says so or when the program's bus
 * connection goes away (it exited or crashed). D-Bus starts this service on
 * the first call (share/dbus-1/services/org.freedesktop.ScreenSaver.service).
 *
 * SimulateUserActivity starts the idle time again; Lock, and SetActive(true),
 * lock the session (LOCK on the control socket); GetActive tells whether it is
 * locked.
 *
 * The control socket is $SG_LOCK_CONTROL, or the session's in the seat
 * directory: $SG_SEAT_DIR (default /run/stained-glass-seat/seat0)/<uid>/
 * control.sock. Authority over it is the compositor's (SO_PEERCRED): this
 * service has none of its own.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#define _GNU_SOURCE
#include <dbus/dbus.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

#define SERVICE "org.freedesktop.ScreenSaver"
#define IFACE "org.freedesktop.ScreenSaver"

struct inhibition {
    dbus_uint32_t cookie;
    char *owner;  /* the unique bus name that asked */
    char *app, *reason;
};

static struct inhibition *held;
static size_t n_held, size_held;
static dbus_uint32_t next_cookie = 1;
static int inhibit_fd = -1;
static char control_path[sizeof(((struct sockaddr_un *) 0)->sun_path)];

static const char introspection[] =
    DBUS_INTROSPECT_1_0_XML_DOCTYPE_DECL_NODE
    "<node>\n"
    " <interface name=\"org.freedesktop.ScreenSaver\">\n"
    "  <method name=\"Inhibit\"><arg name=\"application_name\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"reason_for_inhibit\" type=\"s\" direction=\"in\"/><arg name=\"cookie\" type=\"u\" direction=\"out\"/></method>\n"
    "  <method name=\"UnInhibit\"><arg name=\"cookie\" type=\"u\" direction=\"in\"/></method>\n"
    "  <method name=\"SimulateUserActivity\"/>\n"
    "  <method name=\"Lock\"/>\n"
    "  <method name=\"GetActive\"><arg type=\"b\" direction=\"out\"/></method>\n"
    "  <method name=\"SetActive\"><arg name=\"e\" type=\"b\" direction=\"in\"/><arg type=\"b\" direction=\"out\"/></method>\n"
    "  <method name=\"GetActiveTime\"><arg type=\"u\" direction=\"out\"/></method>\n"
    "  <method name=\"GetSessionIdleTime\"><arg type=\"u\" direction=\"out\"/></method>\n"
    "  <signal name=\"ActiveChanged\"><arg type=\"b\"/></signal>\n"
    " </interface>\n"
    " <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
    "  <method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method>\n"
    " </interface>\n"
    "</node>\n";

static int
control_connect(const char *command)
{
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    struct timeval tv = {.tv_sec = 2};
    int fd;

    if (!control_path[0]) {
        return -1;
    }
    memcpy(addr.sun_path, control_path, sizeof(addr.sun_path));
    if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0) {
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0 ||
        send(fd, command, strlen(command), MSG_NOSIGNAL) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* one command, its reply line into buf */
static int
control_command(const char *command, char *buf, size_t len)
{
    int fd = control_connect(command);
    ssize_t n;

    if (fd < 0) {
        return -1;
    }
    n = recv(fd, buf, len - 1, 0);
    close(fd);
    if (n <= 0) {
        return -1;
    }
    buf[n] = 0;
    return 0;
}

/* hold the compositor's idle off while anything is held */
static void
update_hold(void)
{
    char reply[64];

#ifdef SG_MUTANT_NO_HOLD
    return;
#endif
    if (n_held && inhibit_fd < 0) {
        if ((inhibit_fd = control_connect("INHIBIT\n")) >= 0) {
            ssize_t n = recv(inhibit_fd, reply, sizeof(reply) - 1, 0);
            if (n <= 0 || strncmp(reply, "OK", 2)) {
                syslog(LOG_WARNING, "the compositor refused INHIBIT");
                close(inhibit_fd);
                inhibit_fd = -1;
            }
        } else {
            syslog(LOG_WARNING, "cannot reach the compositor at %s: %m", control_path);
        }
    } else if (!n_held && inhibit_fd >= 0) {
        close(inhibit_fd);
        inhibit_fd = -1;
    }
}

static void
drop(size_t i)
{
    syslog(LOG_INFO, "released: %s (%s)", held[i].app, held[i].reason);
    free(held[i].owner);
    free(held[i].app);
    free(held[i].reason);
    held[i] = held[--n_held];
}

static dbus_uint32_t
add(const char *owner, const char *app, const char *reason)
{
    if (n_held == size_held) {
        size_t size = size_held ? size_held * 2 : 8;
        struct inhibition *n = realloc(held, size * sizeof(*n));
        if (!n) {
            return 0;
        }
        held = n;
        size_held = size;
    }
    held[n_held].cookie = next_cookie++;
    if (!next_cookie) {
        next_cookie = 1;
    }
    held[n_held].owner = strdup(owner ? owner : "");
    held[n_held].app = strdup(app);
    held[n_held].reason = strdup(reason);
    syslog(LOG_INFO, "inhibited by %s: %s", app, reason);
    return held[n_held++].cookie;
}

static int
is_locked(void)
{
    char reply[64];
    return !control_command("STATUS\n", reply, sizeof(reply)) && !strncmp(reply, "OK locked", 9);
}

static DBusHandlerResult
handle_message(DBusConnection *conn, DBusMessage *msg, void *data)
{
    const char *path = dbus_message_get_path(msg);
    const char *member = dbus_message_get_member(msg);
    DBusMessage *reply = NULL;
    DBusError err;
    char buf[64];

    (void) data;
    if (dbus_message_is_signal(msg, DBUS_INTERFACE_DBUS, "NameOwnerChanged")) {
        const char *name, *old_owner, *new_owner;
        if (dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &name, DBUS_TYPE_STRING, &old_owner,
                                  DBUS_TYPE_STRING, &new_owner, DBUS_TYPE_INVALID) &&
            name[0] == ':' && !new_owner[0]) {
            /* a program's connection went: so do its inhibitions */
            size_t i = 0;
            while (i < n_held) {
                if (!strcmp(held[i].owner, name)) {
                    drop(i);
                } else {
                    i++;
                }
            }
            update_hold();
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (dbus_message_get_type(msg) != DBUS_MESSAGE_TYPE_METHOD_CALL || !path || !member ||
        (strcmp(path, "/org/freedesktop/ScreenSaver") && strcmp(path, "/ScreenSaver"))) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    dbus_error_init(&err);
    if (dbus_message_is_method_call(msg, DBUS_INTERFACE_INTROSPECTABLE, "Introspect")) {
        const char *xml = introspection;
        reply = dbus_message_new_method_return(msg);
        dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
    } else if (dbus_message_is_method_call(msg, IFACE, "Inhibit")) {
        const char *app, *reason;
        dbus_uint32_t cookie;
        if (!dbus_message_get_args(msg, &err, DBUS_TYPE_STRING, &app, DBUS_TYPE_STRING, &reason, DBUS_TYPE_INVALID)) {
            reply = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS, err.message);
        } else if (!(cookie = add(dbus_message_get_sender(msg), app, reason))) {
            reply = dbus_message_new_error(msg, DBUS_ERROR_NO_MEMORY, "out of memory");
        } else {
            update_hold();
            reply = dbus_message_new_method_return(msg);
            dbus_message_append_args(reply, DBUS_TYPE_UINT32, &cookie, DBUS_TYPE_INVALID);
        }
    } else if (dbus_message_is_method_call(msg, IFACE, "UnInhibit")) {
        dbus_uint32_t cookie;
        const char *sender = dbus_message_get_sender(msg);
        if (!dbus_message_get_args(msg, &err, DBUS_TYPE_UINT32, &cookie, DBUS_TYPE_INVALID)) {
            reply = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS, err.message);
        } else {
            size_t i;
            /* only the program that holds a cookie may give it back */
            for (i = 0; i < n_held; i++) {
                if (held[i].cookie == cookie && sender && !strcmp(held[i].owner, sender)) {
                    break;
                }
            }
            if (i == n_held) {
                reply = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS, "no such inhibition");
            } else {
                drop(i);
                update_hold();
                reply = dbus_message_new_method_return(msg);
            }
        }
    } else if (dbus_message_is_method_call(msg, IFACE, "SimulateUserActivity")) {
        /* holding the idle off and letting it go starts the idle time again */
        int fd = control_connect("INHIBIT\n");
        if (fd >= 0) {
            if (recv(fd, buf, sizeof(buf) - 1, 0) < 0) {
                /* the compositor did not answer: nothing more to do */
            }
            close(fd);
        }
        reply = dbus_message_new_method_return(msg);
    } else if (dbus_message_is_method_call(msg, IFACE, "Lock")) {
        control_command("LOCK\n", buf, sizeof(buf));
        reply = dbus_message_new_method_return(msg);
    } else if (dbus_message_is_method_call(msg, IFACE, "SetActive")) {
        dbus_bool_t active;
        if (!dbus_message_get_args(msg, &err, DBUS_TYPE_BOOLEAN, &active, DBUS_TYPE_INVALID)) {
            reply = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS, err.message);
        } else {
            /* only locking can be asked for; unlocking is the lock screen's */
            dbus_bool_t done = active && !control_command("LOCK\n", buf, sizeof(buf)) && !strncmp(buf, "OK", 2);
            reply = dbus_message_new_method_return(msg);
            dbus_message_append_args(reply, DBUS_TYPE_BOOLEAN, &done, DBUS_TYPE_INVALID);
        }
    } else if (dbus_message_is_method_call(msg, IFACE, "GetActive")) {
        dbus_bool_t active = is_locked();
        reply = dbus_message_new_method_return(msg);
        dbus_message_append_args(reply, DBUS_TYPE_BOOLEAN, &active, DBUS_TYPE_INVALID);
    } else if (dbus_message_is_method_call(msg, IFACE, "GetActiveTime") ||
               dbus_message_is_method_call(msg, IFACE, "GetSessionIdleTime")) {
        /* not kept: the compositor's idle time is not reported to clients */
        dbus_uint32_t zero = 0;
        reply = dbus_message_new_method_return(msg);
        dbus_message_append_args(reply, DBUS_TYPE_UINT32, &zero, DBUS_TYPE_INVALID);
    } else {
        reply = dbus_message_new_error(msg, DBUS_ERROR_UNKNOWN_METHOD, member);
    }
    dbus_error_free(&err);
    if (reply) {
        dbus_connection_send(conn, reply, NULL);
        dbus_message_unref(reply);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
}

int
main(void)
{
    DBusConnection *conn;
    DBusError err;
    const char *env;
    int ret;

    openlog("sg-screensaverd", LOG_PID, LOG_USER);
    if ((env = getenv("SG_LOCK_CONTROL")) && env[0]) {
        snprintf(control_path, sizeof(control_path), "%s", env);
    } else {
        const char *seat = getenv("SG_SEAT_DIR");
        snprintf(control_path, sizeof(control_path), "%s/%u/control.sock",
                 seat && seat[0] ? seat : "/run/stained-glass-seat/seat0", (unsigned) getuid());
    }

    dbus_error_init(&err);
    if (!(conn = dbus_bus_get(DBUS_BUS_SESSION, &err))) {
        fprintf(stderr, "sg-screensaverd: no session bus: %s\n", err.message);
        return 1;
    }
    ret = dbus_bus_request_name(conn, SERVICE, DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
    if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        /* another program provides the service already */
        fprintf(stderr, "sg-screensaverd: %s is taken\n", SERVICE);
        return 0;
    }
    dbus_bus_add_match(conn, "type='signal',sender='" DBUS_SERVICE_DBUS "',interface='" DBUS_INTERFACE_DBUS
                       "',member='NameOwnerChanged'", NULL);
    dbus_connection_add_filter(conn, handle_message, NULL, NULL);
    while (dbus_connection_read_write_dispatch(conn, -1)) {
    }
    return 0;
}
