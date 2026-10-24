/* mpris-standin NAME STATUS TITLE LOG -- a stand-in MPRIS player for
 * media-keys-test.py: org.mpris.MediaPlayer2.NAME on the session bus, its
 * PlaybackStatus and Metadata (title, artist "Artist NAME"); every Player
 * method it is called with is appended to LOG as "NAME Method".
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdio.h>
#include <string.h>
#include <systemd/sd-bus.h>

static const char *g_name, *g_status, *g_title, *g_log;

static int method(sd_bus_message *m, void *data, sd_bus_error *err)
{
    FILE *f = fopen(g_log, "a");
    (void) data; (void) err;
    if (f) { fprintf(f, "%s %s\n", g_name, sd_bus_message_get_member(m)); fclose(f); }
    return sd_bus_reply_method_return(m, NULL);
}

static int get_status(sd_bus *bus, const char *path, const char *iface, const char *prop,
                      sd_bus_message *reply, void *data, sd_bus_error *err)
{
    (void) bus; (void) path; (void) iface; (void) prop; (void) data; (void) err;
    return sd_bus_message_append(reply, "s", g_status);
}

static int get_metadata(sd_bus *bus, const char *path, const char *iface, const char *prop,
                        sd_bus_message *reply, void *data, sd_bus_error *err)
{
    char artist[256];
    (void) bus; (void) path; (void) iface; (void) prop; (void) data; (void) err;
    snprintf(artist, sizeof(artist), "Artist %s", g_name);
    return sd_bus_message_append(reply, "a{sv}", 2, "xesam:title", "s", g_title,
                                 "xesam:artist", "as", 1, artist);
}

static const sd_bus_vtable player[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("PlayPause", "", "", method, 0),
    SD_BUS_METHOD("Play", "", "", method, 0),
    SD_BUS_METHOD("Pause", "", "", method, 0),
    SD_BUS_METHOD("Stop", "", "", method, 0),
    SD_BUS_METHOD("Next", "", "", method, 0),
    SD_BUS_METHOD("Previous", "", "", method, 0),
    SD_BUS_PROPERTY("PlaybackStatus", "s", get_status, 0, 0),
    SD_BUS_PROPERTY("Metadata", "a{sv}", get_metadata, 0, 0),
    SD_BUS_VTABLE_END
};

int main(int argc, char **argv)
{
    sd_bus *bus = NULL;
    char well_known[256];
    if (argc != 5) return 2;
    g_name = argv[1]; g_status = argv[2]; g_title = argv[3]; g_log = argv[4];
    if (sd_bus_open_user(&bus) < 0) return 1;
    if (sd_bus_add_object_vtable(bus, NULL, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
                                 player, NULL) < 0) return 1;
    snprintf(well_known, sizeof(well_known), "org.mpris.MediaPlayer2.%s", g_name);
    if (sd_bus_request_name(bus, well_known, 0) < 0) return 1;
    for (;;) {
        int r = sd_bus_process(bus, NULL);
        if (r < 0) return 1;
        if (r == 0 && sd_bus_wait(bus, (uint64_t) -1) < 0) return 1;
    }
}
