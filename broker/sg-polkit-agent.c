/* sg-polkit-agent -- the session's polkit authentication agent (Stained Glass OS).
 *
 * A Linux program that wants to act as an administrator -- pkexec (GParted,
 * Timeshift), a disk or a service -- asks polkit, and polkit asks the
 * session's authentication agent. The session had none, so such programs
 * simply failed. This one asks the elevation broker (sg-brokerd), which shows
 * the same consent as "Run as administrator" on the secure surface: an
 * administrator says Yes or No, anyone else gives an administrator's name and
 * password. If the person agrees, the broker's root monitor gives polkitd the
 * answer, and this agent then finishes the request.
 *
 * It runs as the session's user (sg-session-start), on the system bus, as the
 * agent of this process's session. The request it sends the broker: the
 * working directory "@polkit", then POLKIT_COOKIE, POLKIT_ACTION and
 * POLKIT_IDENTITIES (the uids polkit would accept), then what to show as the
 * program: the program pkexec runs and its arguments, or polkit's message.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <gio/gio.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define AGENT_PATH "/org/stainedglass/PolicyKit1/AuthenticationAgent"

static const char introspection[] =
    "<node>"
    "  <interface name='org.freedesktop.PolicyKit1.AuthenticationAgent'>"
    "    <method name='BeginAuthentication'>"
    "      <arg type='s' name='action_id' direction='in'/>"
    "      <arg type='s' name='message' direction='in'/>"
    "      <arg type='s' name='icon_name' direction='in'/>"
    "      <arg type='a{ss}' name='details' direction='in'/>"
    "      <arg type='s' name='cookie' direction='in'/>"
    "      <arg type='a(sa{sv})' name='identities' direction='in'/>"
    "    </method>"
    "    <method name='CancelAuthentication'>"
    "      <arg type='s' name='cookie' direction='in'/>"
    "    </method>"
    "  </interface>"
    "</node>";

/* one authentication in progress: the broker's connection, closed to cancel */
struct request {
    char *cookie;
    int fd;
};

static GMutex g_lock;
static GList *g_requests;
static const char *g_sock = "/run/stained-glass-broker/broker.sock";

static size_t put(char *blob, size_t off, size_t max, const char *s)
{
    size_t n = strlen(s) + 1;
    if (off + n <= max) memcpy(blob + off, s, n);
    return off + n;
}

static int write_full(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        p += n; len -= (size_t)n;
    }
    return 0;
}

/* Asks the broker; 0 = authorised (polkitd has the answer), 1 = declined,
 * 2 = failed. */
static int ask_broker(struct request *req, const char *action, const char *message, GVariant *details,
                      GVariant *identities)
{
    char blob[16384], kv[4096], ids[1024] = "";
    const char *program = NULL, *cmdline = NULL;
    struct sockaddr_un addr;
    GVariantIter iter;
    GVariant *details_in;
    const char *kind;
    unsigned char status = 2;
    size_t off = 0;
    uint32_t len;

    g_variant_lookup(details, "program", "&s", &program);
    g_variant_lookup(details, "command_line", "&s", &cmdline);
    /* polkitd passes the agent only some of pkexec's details; its message
     * names the program: "... to run `/usr/sbin/gparted' as the super user" */
    char quoted[1024] = "";
    if (!program && message && (program = strchr(message, '`'))) {
        const char *q = strchr(program + 1, '\'');
        size_t n = q ? (size_t)(q - program - 1) : 0;
        if (n && n < sizeof(quoted)) { memcpy(quoted, program + 1, n); quoted[n] = 0; program = quoted; }
        else program = NULL;
    }

    /* the uids polkit would take */
    g_variant_iter_init(&iter, identities);
    while (g_variant_iter_next(&iter, "(&s@a{sv})", &kind, &details_in)) {
        guint32 uid;
        if (!strcmp(kind, "unix-user") && g_variant_lookup(details_in, "uid", "u", &uid)) {
            char one[16];
            snprintf(one, sizeof(one), "%s%u", ids[0] ? "," : "", uid);
            if (strlen(ids) + strlen(one) < sizeof(ids)) strcat(ids, one);
        }
        g_variant_unref(details_in);
    }
    if (!ids[0]) return 2;   /* nobody polkit would take is a person here */

    off = put(blob, off, sizeof(blob), "@polkit");
    snprintf(kv, sizeof(kv), "POLKIT_COOKIE=%s", req->cookie); off = put(blob, off, sizeof(blob), kv);
    snprintf(kv, sizeof(kv), "POLKIT_ACTION=%s", action); off = put(blob, off, sizeof(blob), kv);
    snprintf(kv, sizeof(kv), "POLKIT_IDENTITIES=%s", ids); off = put(blob, off, sizeof(blob), kv);
    off = put(blob, off, sizeof(blob), "");
    if (program && *program) {
        /* the program pkexec runs, then its arguments (the command line
         * without its first word) */
        off = put(blob, off, sizeof(blob), program);
        if (cmdline && (cmdline = strchr(cmdline, ' '))) {
            gchar **words = g_strsplit(cmdline + 1, " ", 64);
            for (int i = 0; words[i]; i++) if (*words[i]) off = put(blob, off, sizeof(blob), words[i]);
            g_strfreev(words);
        }
    } else off = put(blob, off, sizeof(blob), message && *message ? message : action);
    if (off > sizeof(blob)) return 2;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", g_sock);
    if (connect(req->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        g_warning("no broker at %s: %s", g_sock, strerror(errno));
        return 2;
    }
    len = (uint32_t)off;
    if (write_full(req->fd, &len, sizeof(len)) || write_full(req->fd, blob, off)) return 2;
    if (read(req->fd, &status, 1) != 1) return 2;
    return status;
}

struct begin {
    GDBusMethodInvocation *invocation;
    char *action, *message;
    GVariant *details, *identities;
    struct request *req;
};

static void begin_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancellable)
{
    struct begin *b = data;
    int status;

    (void)source; (void)cancellable;
    status = ask_broker(b->req, b->action, b->message, b->details, b->identities);

    g_mutex_lock(&g_lock);
    g_requests = g_list_remove(g_requests, b->req);
    g_mutex_unlock(&g_lock);
    close(b->req->fd);

    if (status == 0) g_dbus_method_invocation_return_value(b->invocation, NULL);
    else if (status == 1)
        g_dbus_method_invocation_return_dbus_error(b->invocation, "org.freedesktop.PolicyKit1.Error.Cancelled",
                                                   "The person declined.");
    else
        g_dbus_method_invocation_return_dbus_error(b->invocation, "org.freedesktop.PolicyKit1.Error.Failed",
                                                   "The request could not be completed.");
    g_free(b->req->cookie);
    g_free(b->req);
    g_free(b->action);
    g_free(b->message);
    g_variant_unref(b->details);
    g_variant_unref(b->identities);
    g_free(b);
    g_task_return_boolean(task, TRUE);
}

static void method_call(GDBusConnection *bus, const char *sender, const char *path, const char *iface,
                        const char *method, GVariant *params, GDBusMethodInvocation *invocation, gpointer data)
{
    (void)bus; (void)sender; (void)path; (void)iface; (void)data;
    if (!strcmp(method, "BeginAuthentication")) {
        struct begin *b = g_new0(struct begin, 1);
        const char *action, *message, *icon, *cookie;
        GTask *task;

        g_variant_get(params, "(&s&s&s@a{ss}&s@a(sa{sv}))", &action, &message, &icon, &b->details, &cookie,
                      &b->identities);
        b->invocation = invocation;
        b->action = g_strdup(action);
        b->message = g_strdup(message);
        b->req = g_new0(struct request, 1);
        b->req->cookie = g_strdup(cookie);
        b->req->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        g_mutex_lock(&g_lock);
        g_requests = g_list_prepend(g_requests, b->req);
        g_mutex_unlock(&g_lock);
        task = g_task_new(NULL, NULL, NULL, NULL);
        g_task_set_task_data(task, b, NULL);
        g_task_run_in_thread(task, begin_thread);
        g_object_unref(task);
    } else if (!strcmp(method, "CancelAuthentication")) {
        const char *cookie;
        GList *l;

        g_variant_get(params, "(&s)", &cookie);
        g_mutex_lock(&g_lock);
        for (l = g_requests; l; l = l->next) {
            struct request *req = l->data;
            if (!strcmp(req->cookie, cookie)) shutdown(req->fd, SHUT_RDWR);   /* its thread answers */
        }
        g_mutex_unlock(&g_lock);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method);
}

static const GDBusInterfaceVTable vtable = { method_call, NULL, NULL, { 0 } };

int main(void)
{
    GDBusConnection *bus;
    GDBusNodeInfo *node;
    GVariant *subject, *ret;
    GVariantBuilder sd;
    GError *error = NULL;
    const char *env, *session = getenv("XDG_SESSION_ID");
    const char *locale = getenv("LANG");
    GMainLoop *loop;

    if ((env = getenv("SG_BROKER_SOCK"))) g_sock = env;
    if (!(bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error))) {
        fprintf(stderr, "sg-polkit-agent: %s\n", error->message);
        return 1;
    }
    node = g_dbus_node_info_new_for_xml(introspection, NULL);
    if (!g_dbus_connection_register_object(bus, AGENT_PATH, node->interfaces[0], &vtable, NULL, NULL, &error)) {
        fprintf(stderr, "sg-polkit-agent: %s\n", error->message);
        return 1;
    }

    /* the agent of this session (or, without a session id, of the session
     * this process is in) */
    g_variant_builder_init(&sd, G_VARIANT_TYPE("a{sv}"));
    if (session && *session) {
        g_variant_builder_add(&sd, "{sv}", "session-id", g_variant_new_string(session));
        subject = g_variant_new("(sa{sv})", "unix-session", &sd);
    } else {
        g_variant_builder_add(&sd, "{sv}", "pid", g_variant_new_uint32((guint32)getpid()));
        g_variant_builder_add(&sd, "{sv}", "start-time", g_variant_new_uint64(0));
        subject = g_variant_new("(sa{sv})", "unix-process", &sd);
    }
    ret = g_dbus_connection_call_sync(bus, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority",
                                      "org.freedesktop.PolicyKit1.Authority", "RegisterAuthenticationAgent",
                                      g_variant_new("(@(sa{sv})ss)", subject, locale && *locale ? locale : "C.UTF-8",
                                                    AGENT_PATH),
                                      NULL, G_DBUS_CALL_FLAGS_NONE, 30000, NULL, &error);
    if (!ret) {
        fprintf(stderr, "sg-polkit-agent: polkit refused the agent: %s\n", error->message);
        return 1;
    }
    g_variant_unref(ret);
    fprintf(stderr, "sg-polkit-agent: the session's agent (%s)\n", session && *session ? session : "by process");

    loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    return 0;
}
