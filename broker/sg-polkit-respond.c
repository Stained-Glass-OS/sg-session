/* sg-polkit-respond -- tells polkitd who authenticated (Stained Glass OS).
 *
 *   sg-polkit-respond AGENT_UID COOKIE IDENTITY_UID
 *
 * Run by sg-brokerd's root monitor once the person consented on the secure
 * surface: polkitd's AuthenticationAgentResponse2, which it takes from root
 * only, for the authentication COOKIE that the agent of AGENT_UID was asked
 * to do, made by the account IDENTITY_UID. The same answer polkit's own
 * helper gives after a password; here the consent is the broker's.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    GDBusConnection *bus;
    GVariant *identity, *ret;
    GError *error = NULL;
    char *end;
    unsigned long agent, uid;

    if (argc != 4) {
        fprintf(stderr, "usage: sg-polkit-respond AGENT_UID COOKIE IDENTITY_UID\n");
        return 2;
    }
    agent = strtoul(argv[1], &end, 10);
    if (*end || !*argv[1]) return 2;
    uid = strtoul(argv[3], &end, 10);
    if (*end || !*argv[3]) return 2;
    if (!(bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error))) {
        fprintf(stderr, "sg-polkit-respond: %s\n", error->message);
        return 1;
    }
    {
        GVariantBuilder details;
        g_variant_builder_init(&details, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&details, "{sv}", "uid", g_variant_new_uint32((guint32)uid));
        identity = g_variant_new("(sa{sv})", "unix-user", &details);
    }
    ret = g_dbus_connection_call_sync(bus, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority",
                                      "org.freedesktop.PolicyKit1.Authority", "AuthenticationAgentResponse2",
                                      g_variant_new("(us@(sa{sv}))", (guint32)agent, argv[2], identity),
                                      NULL, G_DBUS_CALL_FLAGS_NONE, 30000, NULL, &error);
    if (!ret) {
        fprintf(stderr, "sg-polkit-respond: %s\n", error->message);
        return 1;
    }
    g_variant_unref(ret);
    return 0;
}
