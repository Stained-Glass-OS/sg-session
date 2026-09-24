/* One remote-desktop stream: a user's session, seen and driven over RDP.
 *
 * The session side is a Wayland connection to the session's compositor on its
 * privileged socket (the fd comes from sg-rdp-authd's root monitor, only after
 * PAM accepted that user). Frames come from wlr-screencopy; input goes in
 * through virtual-keyboard and virtual-pointer -- the capabilities sg-compositor
 * grants privileged clients and nobody else (ADR 0010, ADR 0011).
 *
 * The RDP side is a FreeRDP peer context: changed 64x64 tiles are sent as
 * planar bitmap updates (raw planes), which every RDP client since 6.0
 * decodes.
 *
 * Single-threaded: everything runs on the peer's thread, which polls the
 * Wayland fd beside FreeRDP's own handles.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef SG_RDP_STREAM_H
#define SG_RDP_STREAM_H

#include <stdint.h>
#include <freerdp/freerdp.h>

struct sg_stream;

/* Takes ownership of fd. NULL on failure, with the reason in err. */
struct sg_stream *sg_stream_new( int fd, char *err, size_t errlen );
void sg_stream_free( struct sg_stream *s );

/* The session's screen size, known once sg_stream_new returns. */
void sg_stream_size( struct sg_stream *s, uint32_t *width, uint32_t *height );

/* The fd to wait on. Call sg_stream_prepare before waiting and
 * sg_stream_after_wait after; the latter returns -1 once the session is gone. */
int sg_stream_fd( struct sg_stream *s );
void sg_stream_prepare( struct sg_stream *s );
int sg_stream_after_wait( struct sg_stream *s );

/* Start sending frames to the peer: the first is the whole screen. */
void sg_stream_start( struct sg_stream *s, rdpContext *context );

/* Input from the client. Keys are evdev codes. */
void sg_stream_key( struct sg_stream *s, uint32_t evdev, int down );
void sg_stream_unicode( struct sg_stream *s, uint32_t codepoint );
void sg_stream_motion( struct sg_stream *s, uint32_t x, uint32_t y );
void sg_stream_button( struct sg_stream *s, uint32_t button, int down );
void sg_stream_wheel( struct sg_stream *s, int horizontal, int steps );
/* Releases every key and button still down: a client that vanishes mid-press
 * must not leave the session with a stuck key. */
void sg_stream_release_all( struct sg_stream *s );

#endif
