/* A stand-in polkitd for test/polkit-test.sh, on a private bus.
 *
 *   polkit-fixture LOG COOKIE IDENTITY_UIDS MESSAGE
 *
 * Owns org.freedesktop.PolicyKit1 and serves its Authority's
 * RegisterAuthenticationAgent and AuthenticationAgentResponse2. When an agent
 * registers, asks it BeginAuthentication for org.freedesktop.policykit.exec
 * with COOKIE, MESSAGE and the unix-user identities IDENTITY_UIDS
 * (comma-separated), as polkitd does for pkexec. Appends to LOG:
 *   REGISTERED <subject kind>
 *   RESPONSE <agent uid> <cookie> <identity uid>   (from root, in real life)
 *   BEGIN ok | BEGIN <D-Bus error name>
 * and exits after the BEGIN line.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char introspection[] =
    "<node>"
    "  <interface name='org.freedesktop.PolicyKit1.Authority'>"
    "    <method name='RegisterAuthenticationAgent'>"
    "      <arg type='(sa{sv})' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/>"
    "    </method>"
    "    <method name='AuthenticationAgentResponse2'>"
    "      <arg type='u' direction='in'/><arg type='s' direction='in'/><arg type='(sa{sv})' direction='in'/>"
    "    </method>"
    "  </interface>"
    "</node>";

static FILE *log_file;
static const char *g_cookie, *g_ids, *g_message;
static GMainLoop *g_loop;

static void begin_done(GObject *source, GAsyncResult *res, gpointer data)
{
    GError *error = NULL;
    GVariant *ret = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
    (void)data;
    if (ret) { fprintf(log_file, "BEGIN ok\n"); g_variant_unref(ret); }
    else {
        gchar *name = g_dbus_error_get_remote_error(error);
        fprintf(log_file, "BEGIN %s\n", name ? name : "?");
        g_free(name);
    }
    fflush(log_file);
    g_main_loop_quit(g_loop);
}

static void begin(GDBusConnection *bus, const char *agent, const char *path)
{
    GVariantBuilder ids, details;
    gchar **uids = g_strsplit(g_ids, ",", 32);

    g_variant_builder_init(&ids, G_VARIANT_TYPE("a(sa{sv})"));
    for (int i = 0; uids[i]; i++) {
        GVariantBuilder d;
        g_variant_builder_init(&d, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&d, "{sv}", "uid", g_variant_new_uint32((guint32)strtoul(uids[i], NULL, 10)));
        g_variant_builder_add(&ids, "(sa{sv})", "unix-user", &d);
    }
    g_strfreev(uids);
    g_variant_builder_init(&details, G_VARIANT_TYPE("a{ss}"));
    g_variant_builder_add(&details, "{ss}", "polkit.message", g_message);
    g_dbus_connection_call(bus, agent, path, "org.freedesktop.PolicyKit1.AuthenticationAgent", "BeginAuthentication",
                           g_variant_new("(sssa{ss}sa(sa{sv}))", "org.freedesktop.policykit.exec", g_message,
                                         "", &details, g_cookie, &ids),
                           NULL, G_DBUS_CALL_FLAGS_NONE, 60000, NULL, begin_done, NULL);
}

static void method_call(GDBusConnection *bus, const char *sender, const char *path, const char *iface,
                        const char *method, GVariant *params, GDBusMethodInvocation *invocation, gpointer data)
{
    (void)path; (void)iface; (void)data;
    if (!strcmp(method, "RegisterAuthenticationAgent")) {
        const char *kind, *locale, *object;
        GVariant *subject_details;
        g_variant_get(params, "((&s@a{sv})&s&s)", &kind, &subject_details, &locale, &object);
        fprintf(log_file, "REGISTERED %s\n", kind);
        fflush(log_file);
        g_variant_unref(subject_details);
        g_dbus_method_invocation_return_value(invocation, NULL);
        begin(bus, sender, object);
    } else if (!strcmp(method, "AuthenticationAgentResponse2")) {
        guint32 agent_uid, uid = 0;
        const char *cookie, *kind;
        GVariant *details;
        g_variant_get(params, "(u&s(&s@a{sv}))", &agent_uid, &cookie, &kind, &details);
        g_variant_lookup(details, "uid", "u", &uid);
        fprintf(log_file, "RESPONSE %u %s %s:%u\n", agent_uid, cookie, kind, uid);
        fflush(log_file);
        g_variant_unref(details);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method);
}

static const GDBusInterfaceVTable vtable = { method_call, NULL, NULL, { 0 } };

static void acquired(GDBusConnection *bus, const char *name, gpointer data)
{
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(introspection, NULL);
    (void)name; (void)data;
    g_dbus_connection_register_object(bus, "/org/freedesktop/PolicyKit1/Authority", node->interfaces[0], &vtable,
                                      NULL, NULL, NULL);
    fprintf(log_file, "READY\n");
    fflush(log_file);
}

int main(int argc, char **argv)
{
    if (argc != 5 || !(log_file = fopen(argv[1], "a"))) return 2;
    g_cookie = argv[2]; g_ids = argv[3]; g_message = argv[4];
    g_bus_own_name(G_BUS_TYPE_SYSTEM, "org.freedesktop.PolicyKit1", G_BUS_NAME_OWNER_FLAGS_NONE, NULL, acquired,
                   NULL, NULL, NULL);
    g_loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(g_loop);
    return 0;
}
