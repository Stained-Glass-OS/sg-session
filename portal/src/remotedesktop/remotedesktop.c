/*
 * Stained Glass OS: the RemoteDesktop portal (org.freedesktop.impl.portal.RemoteDesktop).
 *
 * A program asks to see the screen and to use the keyboard and pointer --
 * remote support, a remote desktop server. The screen comes from the
 * ScreenCast half of the same session (its SelectSources, this Start). The
 * input goes through a connection the person allowed on the secure surface
 * (capture_grant.c): the compositor's virtual keyboard and pointer, which no
 * program in the session is offered by itself. While it lasts a frame shows
 * round the screen; Ctrl+Alt+Del ends it, and the session with it.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: MIT
 */
#include <errno.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>

#include "xdpw.h"
#include "remotedesktop.h"
#include "screencast.h"
#include "logger.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static const char object_path[] = "/org/freedesktop/portal/desktop";
static const char interface_name[] = "org.freedesktop.impl.portal.RemoteDesktop";

#define RD_MAX_KEYS 256

struct xdpw_rd_input {
	struct xdpw_session *sess;
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_seat *seat;
	struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
	struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
	struct zwlr_virtual_pointer_v1 *pointer;
	struct zwp_virtual_keyboard_v1 *keyboard;
	struct xkb_context *xkb;
	struct xkb_keymap *keymap;
	struct xkb_state *xkb_state;
	uint8_t keys_down[RD_MAX_KEYS];
	uint32_t buttons_down;
};

static struct xdpw_session *active;   /* the session whose input is live: one at a time (the compositor's one shadow) */

static uint32_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* ---- the input connection -------------------------------------------------- */

static void registry_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
	struct xdpw_rd_input *in = data;
	if (!strcmp(iface, wl_seat_interface.name) && !in->seat) {
		in->seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
	} else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) {
		in->pointer_manager = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
	} else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name)) {
		in->keyboard_manager = wl_registry_bind(r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	}
}
static void registry_remove(void *data, struct wl_registry *r, uint32_t name) {
}
static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

/* The ordinary evdev/us keymap, which Xwayland also starts with, so Wine sees
 * no keymap change to race (as sg-rdp-stream). */
static int upload_keymap(struct xdpw_rd_input *in) {
	struct xkb_rule_names names = { "evdev", "pc105", "us", "", "" };
	char *text;
	size_t len;
	int fd;

	if (!(in->xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS)) ||
	    !(in->keymap = xkb_keymap_new_from_names(in->xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS)) ||
	    !(in->xkb_state = xkb_state_new(in->keymap)) ||
	    !(text = xkb_keymap_get_as_string(in->keymap, XKB_KEYMAP_FORMAT_TEXT_V1))) {
		return -1;
	}
	len = strlen(text) + 1;
	fd = memfd_create("sg-portal-keymap", MFD_CLOEXEC);
	if (fd < 0 || write(fd, text, len) != (ssize_t)len) {
		free(text);
		if (fd >= 0) {
			close(fd);
		}
		return -1;
	}
	free(text);
	zwp_virtual_keyboard_v1_keymap(in->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len);
	close(fd);
	return 0;
}

static void input_free(struct xdpw_rd_input *in) {
	if (!in) {
		return;
	}
	if (in->pointer) {
		zwlr_virtual_pointer_v1_destroy(in->pointer);
	}
	if (in->keyboard) {
		zwp_virtual_keyboard_v1_destroy(in->keyboard);
	}
	if (in->pointer_manager) {
		zwlr_virtual_pointer_manager_v1_destroy(in->pointer_manager);
	}
	if (in->keyboard_manager) {
		zwp_virtual_keyboard_manager_v1_destroy(in->keyboard_manager);
	}
	if (in->seat) {
		wl_seat_destroy(in->seat);
	}
	if (in->registry) {
		wl_registry_destroy(in->registry);
	}
	if (in->display) {
		/* the compositor's shadow ends with the connection: the frame goes */
		wl_display_flush(in->display);
		wl_display_disconnect(in->display);
	}
	if (in->xkb_state) {
		xkb_state_unref(in->xkb_state);
	}
	if (in->keymap) {
		xkb_keymap_unref(in->keymap);
	}
	if (in->xkb) {
		xkb_context_unref(in->xkb);
	}
	free(in);
}

static struct xdpw_rd_input *input_open(struct xdpw_session *sess) {
	struct xdpw_rd_input *in = calloc(1, sizeof(*in));
	int fd;

	if (!in) {
		return NULL;
	}
	in->sess = sess;
	if ((fd = xdpw_capture_grant(sess->remotedesktop_data.app_id, 1)) < 0) {
		free(in);
		return NULL;
	}
	if (!(in->display = wl_display_connect_to_fd(fd))) {
		close(fd);
		free(in);
		return NULL;
	}
	in->registry = wl_display_get_registry(in->display);
	wl_registry_add_listener(in->registry, &registry_listener, in);
	wl_display_roundtrip(in->display);
	if (!in->seat || !in->pointer_manager || !in->keyboard_manager) {
		/* a view-only shadow is not offered them */
		logprint(ERROR, "remotedesktop: the compositor offered no virtual keyboard and pointer");
		input_free(in);
		return NULL;
	}
	in->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(in->pointer_manager, in->seat);
	in->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(in->keyboard_manager, in->seat);
	if (!in->pointer || !in->keyboard || upload_keymap(in) < 0) {
		input_free(in);
		return NULL;
	}
	wl_display_roundtrip(in->display);
	return in;
}

static void release_all(struct xdpw_rd_input *in);

void xdpw_remotedesktop_session_end(struct xdpw_session *sess) {
	struct xdpw_rd_input *in = sess->remotedesktop_data.input;
	if (in) {
		release_all(in);
		input_free(in);
		sess->remotedesktop_data.input = NULL;
	}
	if (active == sess) {
		active = NULL;
	}
	free(sess->remotedesktop_data.app_id);
	sess->remotedesktop_data.app_id = NULL;
}

int xdpw_remotedesktop_poll_fd(struct xdpw_state *state) {
	return active && active->remotedesktop_data.input ? wl_display_get_fd(active->remotedesktop_data.input->display) : -1;
}

/* The person ended it (Ctrl+Alt+Del), or the compositor went: the session
 * closes, as the portal's Session.Closed tells the program. */
void xdpw_remotedesktop_dispatch(struct xdpw_state *state, short revents) {
	struct xdpw_session *sess = active;
	struct xdpw_rd_input *in;

	if (!sess || !(in = sess->remotedesktop_data.input)) {
		return;
	}
	if (!(revents & (POLLHUP | POLLERR)) && wl_display_dispatch(in->display) >= 0) {
		return;
	}
	logprint(INFO, "remotedesktop: control ended at the console; closing the session");
	sd_bus_emit_signal(state->bus, sess->session_handle, "org.freedesktop.impl.portal.Session", "Closed", "");
	xdpw_session_destroy(sess);
}

/* ---- input ------------------------------------------------------------------- */

static void send_modifiers(struct xdpw_rd_input *in) {
	zwp_virtual_keyboard_v1_modifiers(in->keyboard,
		xkb_state_serialize_mods(in->xkb_state, XKB_STATE_MODS_DEPRESSED),
		xkb_state_serialize_mods(in->xkb_state, XKB_STATE_MODS_LATCHED),
		xkb_state_serialize_mods(in->xkb_state, XKB_STATE_MODS_LOCKED),
		xkb_state_serialize_layout(in->xkb_state, XKB_STATE_LAYOUT_EFFECTIVE));
}

static void key(struct xdpw_rd_input *in, uint32_t evdev, bool down) {
	if (!evdev || evdev >= RD_MAX_KEYS) {
		return;
	}
	if (!down && !in->keys_down[evdev]) {
		return; /* never release what was not pressed */
	}
	in->keys_down[evdev] = down;
	xkb_state_update_key(in->xkb_state, evdev + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
	zwp_virtual_keyboard_v1_key(in->keyboard, now_ms(), evdev,
		down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
	send_modifiers(in);
	wl_display_flush(in->display);
}

/* a keysym: the key that makes it in the us layout, with Shift if it takes Shift */
static void keysym(struct xdpw_rd_input *in, xkb_keysym_t sym, bool down) {
	xkb_keycode_t kc;
	xkb_level_index_t level;

	for (level = 0; level < 2; level++) {
		for (kc = xkb_keymap_min_keycode(in->keymap); kc <= xkb_keymap_max_keycode(in->keymap); kc++) {
			const xkb_keysym_t *syms;
			if (xkb_keymap_key_get_syms_by_level(in->keymap, kc, 0, level, &syms) >= 1 && syms[0] == sym) {
				if (level && down) {
					key(in, KEY_LEFTSHIFT, true);
				}
				key(in, kc - 8, down);
				if (level && !down) {
					key(in, KEY_LEFTSHIFT, false);
				}
				return;
			}
		}
	}
	logprint(DEBUG, "remotedesktop: keysym %#x has no key in the layout", sym);
}

static void button(struct xdpw_rd_input *in, uint32_t code, bool down) {
	uint32_t bit;
	if (code < BTN_LEFT || code > BTN_TASK) {
		return;
	}
	bit = 1u << (code - BTN_LEFT);
	if (!down && !(in->buttons_down & bit)) {
		return;
	}
	if (down) {
		in->buttons_down |= bit;
	} else {
		in->buttons_down &= ~bit;
	}
	zwlr_virtual_pointer_v1_button(in->pointer, now_ms(), code,
		down ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
	zwlr_virtual_pointer_v1_frame(in->pointer);
	wl_display_flush(in->display);
}

static void release_all(struct xdpw_rd_input *in) {
	uint32_t k, b;
	for (k = 0; k < RD_MAX_KEYS; k++) {
		if (in->keys_down[k]) {
			key(in, k, false);
		}
	}
	for (b = 0; b < 32; b++) {
		if (in->buttons_down & (1u << b)) {
			button(in, BTN_LEFT + b, false);
		}
	}
}

/* The whole desktop's extent in the outputs' logical layout, and a stream's
 * place in it: absolute motion is relative to a stream. */
static bool stream_box(struct xdpw_state *state, struct xdpw_session *sess, uint32_t stream,
		int *x, int *y, uint32_t *ext_w, uint32_t *ext_h) {
	struct xdpw_screencast_instance *cast = sess->screencast_data.screencast_instance;
	struct xdpw_wlr_output *out;
	int w = 0, h = 0;

	wl_list_for_each(out, &state->screencast.output_list, link) {
		if (out->x + out->width > w) {
			w = out->x + out->width;
		}
		if (out->y + out->height > h) {
			h = out->y + out->height;
		}
	}
	if (!cast || !cast->target || !cast->target->output || cast->node_id != stream || w <= 0 || h <= 0) {
		return false;
	}
	*x = cast->target->output->x;
	*y = cast->target->output->y;
	*ext_w = (uint32_t)w;
	*ext_h = (uint32_t)h;
	return true;
}

/* ---- D-Bus ----------------------------------------------------------------- */

static struct xdpw_session *find_session(struct xdpw_state *state, const char *handle) {
	struct xdpw_session *sess;
	wl_list_for_each(sess, &state->xdpw_sessions, link) {
		if (!strcmp(sess->session_handle, handle)) {
			return sess;
		}
	}
	return NULL;
}

/* the session a Notify* call names, if it may use what it is about to */
static struct xdpw_rd_input *notify_target(struct xdpw_state *state, sd_bus_message *msg, uint32_t need,
		struct xdpw_session **out) {
	const char *handle;
	struct xdpw_session *sess;

	if (sd_bus_message_read(msg, "o", &handle) < 0 || sd_bus_message_skip(msg, "a{sv}") < 0) {
		return NULL;
	}
	sess = find_session(state, handle);
	if (!sess || !sess->remotedesktop_data.is_remote || !sess->remotedesktop_data.started ||
	    !(sess->remotedesktop_data.devices & need)) {
		return NULL;
	}
	if (out) {
		*out = sess;
	}
	return sess->remotedesktop_data.input;
}

static int reply_empty(sd_bus_message *msg) {
	return sd_bus_reply_method_return(msg, "");
}

static int skip_options(sd_bus_message *msg) {
	return sd_bus_message_skip(msg, "a{sv}");
}

static int method_create_session(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_state *state = data;
	const char *request_handle, *session_handle, *app_id;
	int ret;

	if ((ret = sd_bus_message_read(msg, "oos", &request_handle, &session_handle, &app_id)) < 0 ||
	    (ret = skip_options(msg)) < 0) {
		return ret;
	}
	logprint(INFO, "remotedesktop: create session %s (app '%s')", session_handle, app_id);
	struct xdpw_session *sess = xdpw_session_create(state, sd_bus_message_get_bus(msg), strdup(session_handle));
	if (!sess) {
		return -ENOMEM;
	}
	sess->remotedesktop_data.is_remote = true;
	sess->remotedesktop_data.devices = XDPW_RD_KEYBOARD | XDPW_RD_POINTER;
	sess->remotedesktop_data.app_id = strdup(app_id);
	return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_SUCCESS, 0);
}

static int method_select_devices(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_state *state = data;
	const char *request_handle, *session_handle, *app_id, *k;
	uint32_t types = XDPW_RD_KEYBOARD | XDPW_RD_POINTER;
	int ret;

	if ((ret = sd_bus_message_read(msg, "oos", &request_handle, &session_handle, &app_id)) < 0 ||
	    (ret = sd_bus_message_enter_container(msg, 'a', "{sv}")) < 0) {
		return ret;
	}
	while ((ret = sd_bus_message_enter_container(msg, 'e', "sv")) > 0) {
		if ((ret = sd_bus_message_read(msg, "s", &k)) < 0) {
			return ret;
		}
		if (!strcmp(k, "types")) {
			if ((ret = sd_bus_message_read(msg, "v", "u", &types)) < 0) {
				return ret;
			}
		} else if ((ret = sd_bus_message_skip(msg, "v")) < 0) {
			return ret;
		}
		if ((ret = sd_bus_message_exit_container(msg)) < 0) {
			return ret;
		}
	}
	sd_bus_message_exit_container(msg);
	struct xdpw_session *sess = find_session(state, session_handle);
	if (!sess || !sess->remotedesktop_data.is_remote || sess->remotedesktop_data.started) {
		return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_CANCELLED, 0);
	}
	sess->remotedesktop_data.devices = types & (XDPW_RD_KEYBOARD | XDPW_RD_POINTER);
	logprint(INFO, "remotedesktop: %s selects devices %#x", session_handle, sess->remotedesktop_data.devices);
	return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_SUCCESS, 0);
}

static int method_start(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_state *state = data;
	const char *request_handle, *session_handle, *app_id, *parent_window;
	sd_bus_message *reply = NULL;
	int ret;

	if ((ret = sd_bus_message_read(msg, "ooss", &request_handle, &session_handle, &app_id, &parent_window)) < 0 ||
	    (ret = skip_options(msg)) < 0) {
		return ret;
	}
	struct xdpw_session *sess = find_session(state, session_handle);
	if (!sess || !sess->remotedesktop_data.is_remote || sess->remotedesktop_data.started) {
		return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_CANCELLED, 0);
	}
	/* one controlled session at a time, as the compositor has one shadow */
	if (active && active != sess) {
		logprint(ERROR, "remotedesktop: another session already has control");
		return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_CANCELLED, 0);
	}
	/* the screen first: a cast that cannot start is no use to control */
	if (sess->screencast_data.screencast_instance && xdpw_screencast_session_start(state, sess) < 0) {
		return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_CANCELLED, 0);
	}
	if (sess->remotedesktop_data.devices) {
		/* the person decides, on the secure surface */
		if (!(sess->remotedesktop_data.input = input_open(sess))) {
			return sd_bus_reply_method_return(msg, "ua{sv}", PORTAL_RESPONSE_CANCELLED, 0);
		}
		active = sess;
	}
	sess->remotedesktop_data.started = true;

	if ((ret = sd_bus_message_new_method_return(msg, &reply)) < 0 ||
	    (ret = sd_bus_message_append(reply, "u", PORTAL_RESPONSE_SUCCESS)) < 0 ||
	    (ret = sd_bus_message_open_container(reply, 'a', "{sv}")) < 0 ||
	    (ret = sd_bus_message_append(reply, "{sv}", "devices", "u", sess->remotedesktop_data.devices)) < 0 ||
	    (ret = sd_bus_message_append(reply, "{sv}", "clipboard_enabled", "b", 0)) < 0 ||
	    (ret = sd_bus_message_append(reply, "{sv}", "persist_mode", "u", 0)) < 0) {
		goto out;
	}
	if (sess->screencast_data.screencast_instance && (ret = xdpw_screencast_append_streams(reply, sess)) < 0) {
		goto out;
	}
	if ((ret = sd_bus_message_close_container(reply)) < 0) {
		goto out;
	}
	ret = sd_bus_send(NULL, reply, NULL);
out:
	sd_bus_message_unref(reply);
	return ret;
}

static int method_pointer_motion(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_POINTER, NULL);
	double dx, dy;
	if (in && sd_bus_message_read(msg, "dd", &dx, &dy) >= 0) {
		zwlr_virtual_pointer_v1_motion(in->pointer, now_ms(), wl_fixed_from_double(dx), wl_fixed_from_double(dy));
		zwlr_virtual_pointer_v1_frame(in->pointer);
		wl_display_flush(in->display);
	}
	return reply_empty(msg);
}

static int method_pointer_motion_absolute(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_session *sess = NULL;
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_POINTER, &sess);
	uint32_t stream, ew, eh;
	double x, y;
	int ox, oy;
	if (in && sd_bus_message_read(msg, "udd", &stream, &x, &y) >= 0 &&
	    stream_box(data, sess, stream, &ox, &oy, &ew, &eh)) {
		double gx = x + ox, gy = y + oy;
		if (gx < 0) {
			gx = 0;
		}
		if (gy < 0) {
			gy = 0;
		}
		if (gx > ew - 1) {
			gx = ew - 1;
		}
		if (gy > eh - 1) {
			gy = eh - 1;
		}
		zwlr_virtual_pointer_v1_motion_absolute(in->pointer, now_ms(), (uint32_t)gx, (uint32_t)gy, ew, eh);
		zwlr_virtual_pointer_v1_frame(in->pointer);
		wl_display_flush(in->display);
	}
	return reply_empty(msg);
}

static int method_pointer_button(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_POINTER, NULL);
	int32_t code;
	uint32_t st;
	if (in && sd_bus_message_read(msg, "iu", &code, &st) >= 0) {
		button(in, (uint32_t)code, st != 0);
	}
	return reply_empty(msg);
}

static int method_pointer_axis(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_POINTER, NULL);
	double dx, dy;
	uint32_t t = now_ms();
	if (in && sd_bus_message_read(msg, "dd", &dx, &dy) >= 0) {
		zwlr_virtual_pointer_v1_axis_source(in->pointer, WL_POINTER_AXIS_SOURCE_FINGER);
		if (dx) {
			zwlr_virtual_pointer_v1_axis(in->pointer, t, WL_POINTER_AXIS_HORIZONTAL_SCROLL, wl_fixed_from_double(dx));
		}
		if (dy) {
			zwlr_virtual_pointer_v1_axis(in->pointer, t, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(dy));
		}
		zwlr_virtual_pointer_v1_frame(in->pointer);
		wl_display_flush(in->display);
	}
	return reply_empty(msg);
}

static int method_pointer_axis_discrete(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_POINTER, NULL);
	uint32_t axis;
	int32_t steps;
	if (in && sd_bus_message_read(msg, "ui", &axis, &steps) >= 0 && steps && axis <= 1) {
		uint32_t wl_axis = axis ? WL_POINTER_AXIS_HORIZONTAL_SCROLL : WL_POINTER_AXIS_VERTICAL_SCROLL;
		zwlr_virtual_pointer_v1_axis_source(in->pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
		zwlr_virtual_pointer_v1_axis_discrete(in->pointer, now_ms(), wl_axis, wl_fixed_from_int(15 * steps), steps);
		zwlr_virtual_pointer_v1_frame(in->pointer);
		wl_display_flush(in->display);
	}
	return reply_empty(msg);
}

static int method_keyboard_keycode(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_KEYBOARD, NULL);
	int32_t code;
	uint32_t st;
	if (in && sd_bus_message_read(msg, "iu", &code, &st) >= 0 && code > 0) {
		key(in, (uint32_t)code, st != 0);
	}
	return reply_empty(msg);
}

static int method_keyboard_keysym(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	struct xdpw_rd_input *in = notify_target(data, msg, XDPW_RD_KEYBOARD, NULL);
	int32_t sym;
	uint32_t st;
	if (in && sd_bus_message_read(msg, "iu", &sym, &st) >= 0) {
		keysym(in, (xkb_keysym_t)sym, st != 0);
	}
	return reply_empty(msg);
}

/* no touchscreen is offered (AvailableDeviceTypes): accepted, and nothing done */
static int method_touch(sd_bus_message *msg, void *data, sd_bus_error *ret_error) {
	return reply_empty(msg);
}

static const sd_bus_vtable remotedesktop_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("CreateSession", "oosa{sv}", "ua{sv}", method_create_session, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("SelectDevices", "oosa{sv}", "ua{sv}", method_select_devices, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Start", "oossa{sv}", "ua{sv}", method_start, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyPointerMotion", "oa{sv}dd", "", method_pointer_motion, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyPointerMotionAbsolute", "oa{sv}udd", "", method_pointer_motion_absolute, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyPointerButton", "oa{sv}iu", "", method_pointer_button, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyPointerAxis", "oa{sv}dd", "", method_pointer_axis, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyPointerAxisDiscrete", "oa{sv}ui", "", method_pointer_axis_discrete, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyKeyboardKeycode", "oa{sv}iu", "", method_keyboard_keycode, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyKeyboardKeysym", "oa{sv}iu", "", method_keyboard_keysym, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyTouchDown", "oa{sv}uudd", "", method_touch, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyTouchMotion", "oa{sv}uudd", "", method_touch, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("NotifyTouchUp", "oa{sv}u", "", method_touch, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_PROPERTY("AvailableDeviceTypes", "u", NULL, offsetof(struct xdpw_state, remotedesktop_device_types),
		SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("version", "u", NULL, offsetof(struct xdpw_state, remotedesktop_version),
		SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END
};

int xdpw_remotedesktop_init(struct xdpw_state *state) {
	sd_bus_slot *slot = NULL;
	state->remotedesktop_device_types = XDPW_RD_KEYBOARD | XDPW_RD_POINTER;
	state->remotedesktop_version = 1;
	return sd_bus_add_object_vtable(state->bus, &slot, object_path, interface_name, remotedesktop_vtable, state);
}
