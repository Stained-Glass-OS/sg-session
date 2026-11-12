#ifndef SCREENCAST_H
#define SCREENCAST_H

#include "screencast_common.h"
#include "xdpw.h"

void xdpw_screencast_instance_destroy(struct xdpw_screencast_instance *cast);
void xdpw_screencast_instance_teardown(struct xdpw_screencast_instance *cast);

struct xdpw_state;
struct xdpw_session;
int xdpw_screencast_session_start(struct xdpw_state *state, struct xdpw_session *sess);
int xdpw_screencast_append_streams(sd_bus_message *reply, struct xdpw_session *sess);

#endif
