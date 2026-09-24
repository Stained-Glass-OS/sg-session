/* sg-vkbd -- type into a Wayland compositor with a *stable* keymap.
 *
 *   sg-vkbd [ARG...]      ARG is TEXT, or -k KEYSYM (press and release),
 *                         or -M MOD / -m MOD (hold / release a modifier:
 *                         shift, ctrl, alt, logo)
 *
 * A test fixture, like wtype but with one difference that matters here: wtype
 * uploads a keymap made up for each invocation, assigning keycodes in the
 * order it meets keysyms, so its first key is keycode 9 -- which is Escape to
 * any client still using the previous keymap. Wine re-reads the X keymap only
 * after it notices the change, so a gate's first key could arrive as Escape
 * and decline a prompt nobody meant to decline. sg-vkbd uploads the ordinary
 * evdev "us" keymap -- the one Xwayland starts with -- and sends real evdev
 * keycodes, so there is no keymap change to race.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *g_seat;
static struct zwp_virtual_keyboard_manager_v1 *g_mgr;
static struct zwp_virtual_keyboard_v1 *g_kbd;
static struct wl_display *g_dpy;
static struct xkb_keymap *g_keymap;
static struct xkb_state *g_state;

static void global_add(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t ver)
{
    (void)data; (void)ver;
    if (!strcmp(iface, wl_seat_interface.name) && !g_seat)
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
        g_mgr = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void global_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener registry_listener = { global_add, global_remove };

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void send_mods(void)
{
    zwp_virtual_keyboard_v1_modifiers(g_kbd,
        xkb_state_serialize_mods(g_state, XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(g_state, XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(g_state, XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(g_state, XKB_STATE_LAYOUT_EFFECTIVE));
}

/* xkb keycode = evdev keycode + 8 */
static void key(xkb_keycode_t kc, int down)
{
    zwp_virtual_keyboard_v1_key(g_kbd, now_ms(), kc - 8, down ? 1 : 0);
    xkb_state_update_key(g_state, kc, down ? XKB_KEY_DOWN : XKB_KEY_UP);
    send_mods();
    wl_display_roundtrip(g_dpy);
    usleep(20000);
}

/* Find the keycode producing sym at level 0 or 1 (shift). */
static int lookup(xkb_keysym_t sym, xkb_keycode_t *kc, int *shift)
{
    xkb_keycode_t k;
    for (int level = 0; level < 2; level++)
        for (k = xkb_keymap_min_keycode(g_keymap); k <= xkb_keymap_max_keycode(g_keymap); k++) {
            const xkb_keysym_t *syms;
            int n = xkb_keymap_key_get_syms_by_level(g_keymap, k, 0, level, &syms);
            for (int i = 0; i < n; i++)
                if (syms[i] == sym) { *kc = k; *shift = level; return 1; }
        }
    return 0;
}

static xkb_keycode_t modifier_key(const char *name)
{
    static const struct { const char *name; xkb_keysym_t sym; } mods[] = {
        { "shift", XKB_KEY_Shift_L }, { "ctrl", XKB_KEY_Control_L },
        { "alt", XKB_KEY_Alt_L }, { "logo", XKB_KEY_Super_L },
    };
    xkb_keycode_t kc; int sh;
    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++)
        if (!strcasecmp(name, mods[i].name) && lookup(mods[i].sym, &kc, &sh)) return kc;
    fprintf(stderr, "sg-vkbd: unknown modifier %s\n", name);
    exit(2);
}

static void tap_sym(xkb_keysym_t sym, const char *what)
{
    xkb_keycode_t kc, shift_kc = 0; int shift, sh;
    if (!lookup(sym, &kc, &shift)) { fprintf(stderr, "sg-vkbd: no key for %s\n", what); exit(2); }
    if (shift) { lookup(XKB_KEY_Shift_L, &shift_kc, &sh); key(shift_kc, 1); }
    key(kc, 1);
    key(kc, 0);
    if (shift) key(shift_kc, 0);
}

int main(int argc, char **argv)
{
    struct xkb_context *ctx;
    struct xkb_rule_names names = { "evdev", "pc105", "us", "", "" };
    struct wl_registry *reg;
    char *km;
    size_t kmlen;
    int fd;

    if (!(g_dpy = wl_display_connect(NULL))) { fprintf(stderr, "sg-vkbd: no Wayland display\n"); return 1; }
    reg = wl_display_get_registry(g_dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(g_dpy);
    if (!g_seat || !g_mgr) { fprintf(stderr, "sg-vkbd: compositor lacks a seat or the virtual keyboard\n"); return 1; }

    ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx || !(g_keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS))) {
        fprintf(stderr, "sg-vkbd: cannot compile the evdev/us keymap\n");
        return 1;
    }
    g_state = xkb_state_new(g_keymap);
    km = xkb_keymap_get_as_string(g_keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    kmlen = strlen(km) + 1;
    if ((fd = memfd_create("sg-vkbd-keymap", MFD_CLOEXEC)) < 0 || write(fd, km, kmlen) != (ssize_t)kmlen) {
        perror("sg-vkbd: keymap");
        return 1;
    }
    g_kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(g_mgr, g_seat);
    zwp_virtual_keyboard_v1_keymap(g_kbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)kmlen);
    wl_display_roundtrip(g_dpy);
    close(fd);
    free(km);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-k") && i + 1 < argc) {
            xkb_keysym_t sym = xkb_keysym_from_name(argv[++i], XKB_KEYSYM_CASE_INSENSITIVE);
            if (sym == XKB_KEY_NoSymbol) { fprintf(stderr, "sg-vkbd: unknown key %s\n", argv[i]); return 2; }
            tap_sym(sym, argv[i]);
        } else if (!strcmp(argv[i], "-M") && i + 1 < argc) {
            key(modifier_key(argv[++i]), 1);
        } else if (!strcmp(argv[i], "-m") && i + 1 < argc) {
            key(modifier_key(argv[++i]), 0);
        } else {
            for (const unsigned char *p = (const unsigned char *)argv[i]; *p; p++) {
                char what[2] = { (char)*p, 0 };
                tap_sym(xkb_utf32_to_keysym(*p), what);
            }
        }
    }
    zwp_virtual_keyboard_v1_destroy(g_kbd);
    wl_display_roundtrip(g_dpy);
    wl_display_disconnect(g_dpy);
    return 0;
}
