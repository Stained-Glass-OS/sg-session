#ifndef REMOTEDESKTOP_H
#define REMOTEDESKTOP_H

#include <stdbool.h>
#include <stdint.h>

struct xdpw_state;
struct xdpw_session;
struct xdpw_rd_input;

/* the device types a remote desktop session may ask for */
enum xdpw_rd_device {
	XDPW_RD_KEYBOARD = 1,
	XDPW_RD_POINTER = 2,
	XDPW_RD_TOUCHSCREEN = 4,
};

struct xdpw_remotedesktop_session_data {
	bool is_remote;          /* made by RemoteDesktop.CreateSession */
	bool started;
	uint32_t devices;        /* what SelectDevices asked for */
	char *app_id;
	struct xdpw_rd_input *input;
};

int xdpw_remotedesktop_init(struct xdpw_state *state);
void xdpw_remotedesktop_session_end(struct xdpw_session *sess);
/* the input connection's fd (-1: none), polled by the main loop: a hangup
 * means the person ended remote control (Ctrl+Alt+Del) */
int xdpw_remotedesktop_poll_fd(struct xdpw_state *state);
void xdpw_remotedesktop_dispatch(struct xdpw_state *state, short revents);

/* sg-brokerd's "@capture": a privileged connection to the session's
 * compositor once the person allowed it on the secure surface; -1 if not */
int xdpw_capture_grant(const char *app_id, int control);

#endif
