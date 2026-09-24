/* One remote-desktop stream: see sg-rdp-stream.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/input-event-codes.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

#include <freerdp/freerdp.h>
#include <freerdp/update.h>
#include <freerdp/codec/color.h>

#include "sg-rdp-stream.h"

#define TILE 64
#define MAX_KEYS 256

struct sg_stream
{
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_output *output;
    uint32_t output_global;      /* its registry name: the newest output is taken */
    uint32_t pointer_manager_version;
    struct zwlr_screencopy_manager_v1 *screencopy;
    struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
    struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
    struct zwlr_virtual_pointer_v1 *pointer;
    struct zwp_virtual_keyboard_v1 *keyboard;
    struct xkb_context *xkb;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
    int32_t out_w, out_h;

    /* capture */
    struct zwlr_screencopy_frame_v1 *frame;
    uint32_t format, width, height, stride, flags;
    int buffer_offered;
    struct wl_buffer *buffer;
    void *data;
    size_t size;
    uint8_t *prev;               /* what the client has, same layout as data */
    int have_prev, reading, gone;

    rdpContext *context;
    uint8_t keys_down[MAX_KEYS];
    uint32_t buttons_down;       /* bit n: BTN_LEFT + n */
};

static uint32_t now_ms( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* ---- globals ------------------------------------------------------------- */

static void output_geometry( void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                             int32_t sub, const char *make, const char *model, int32_t transform )
{
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sub; (void)make; (void)model; (void)transform;
}
static void output_mode( void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh )
{
    struct sg_stream *s = d;
    (void)o; (void)refresh;
    if (flags & WL_OUTPUT_MODE_CURRENT) { s->out_w = w; s->out_h = h; }
}
static void output_done( void *d, struct wl_output *o ) { (void)d; (void)o; }
static void output_scale( void *d, struct wl_output *o, int32_t f ) { (void)d; (void)o; (void)f; }
static void output_name( void *d, struct wl_output *o, const char *n ) { (void)d; (void)o; (void)n; }
static void output_description( void *d, struct wl_output *o, const char *n ) { (void)d; (void)o; (void)n; }
static const struct wl_output_listener output_listener = {
    output_geometry, output_mode, output_done, output_scale, output_name, output_description,
};

static void registry_global( void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version )
{
    struct sg_stream *s = d;

    if (!strcmp( iface, wl_shm_interface.name ))
        s->shm = wl_registry_bind( r, name, &wl_shm_interface, 1 );
    else if (!strcmp( iface, wl_seat_interface.name ) && !s->seat)
        s->seat = wl_registry_bind( r, name, &wl_seat_interface, 1 );
    else if (!strcmp( iface, wl_output_interface.name ) && (!s->output || name > s->output_global))
    {
        /* The newest output: a Remote Desktop session's only one, or the one
         * a console session's compositor made for Remote Desktop when it was
         * taken over (sg-compositor's REMOTE). */
        if (s->output) wl_output_destroy( s->output );
        s->out_w = s->out_h = 0;
        s->output_global = name;
        s->output = wl_registry_bind( r, name, &wl_output_interface, version < 2 ? version : 2 );
        wl_output_add_listener( s->output, &output_listener, s );
    }
    else if (!strcmp( iface, zwlr_screencopy_manager_v1_interface.name ) && version >= 3)
        s->screencopy = wl_registry_bind( r, name, &zwlr_screencopy_manager_v1_interface, 3 );
    else if (!strcmp( iface, zwlr_virtual_pointer_manager_v1_interface.name ))
    {
        s->pointer_manager_version = version < 2 ? version : 2;
        s->pointer_manager = wl_registry_bind( r, name, &zwlr_virtual_pointer_manager_v1_interface,
                                               s->pointer_manager_version );
    }
    else if (!strcmp( iface, zwp_virtual_keyboard_manager_v1_interface.name ))
        s->keyboard_manager = wl_registry_bind( r, name, &zwp_virtual_keyboard_manager_v1_interface, 1 );
}
static void registry_remove( void *d, struct wl_registry *r, uint32_t name ) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

/* The ordinary evdev/us keymap, which Xwayland also starts with, so Wine sees
 * no keymap change to race (see sg-vkbd.c). */
static int upload_keymap( struct sg_stream *s )
{
    struct xkb_rule_names names = { "evdev", "pc105", "us", "", "" };
    char *text;
    size_t len;
    int fd;

    if (!(s->xkb = xkb_context_new( XKB_CONTEXT_NO_FLAGS ))) return -1;
    if (!(s->keymap = xkb_keymap_new_from_names( s->xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS ))) return -1;
    if (!(s->state = xkb_state_new( s->keymap ))) return -1;
    if (!(text = xkb_keymap_get_as_string( s->keymap, XKB_KEYMAP_FORMAT_TEXT_V1 ))) return -1;
    len = strlen( text ) + 1;
    fd = memfd_create( "sg-rdp-keymap", MFD_CLOEXEC );
    if (fd < 0 || write( fd, text, len ) != (ssize_t)len) { free( text ); if (fd >= 0) close( fd ); return -1; }
    free( text );
    zwp_virtual_keyboard_v1_keymap( s->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len );
    close( fd );
    return 0;
}

struct sg_stream *sg_stream_new( int fd, char *err, size_t errlen )
{
    struct sg_stream *s = calloc( 1, sizeof(*s) );

    if (!s) { close( fd ); snprintf( err, errlen, "out of memory" ); return NULL; }
    if (!(s->display = wl_display_connect_to_fd( fd )))
    {
        close( fd );
        snprintf( err, errlen, "not a Wayland connection" );
        free( s );
        return NULL;
    }
    s->registry = wl_display_get_registry( s->display );
    wl_registry_add_listener( s->registry, &registry_listener, s );
    if (wl_display_roundtrip( s->display ) < 0 || wl_display_roundtrip( s->display ) < 0)
    {
        snprintf( err, errlen, "the session's compositor closed the connection" );
        goto fail;
    }
    /* An ordinary connection is not offered these at all: sg-compositor hides
     * them from everything but privileged clients. */
    if (!s->screencopy || !s->pointer_manager || !s->keyboard_manager)
    {
        snprintf( err, errlen, "the compositor did not grant capture and input (not a privileged connection?)" );
        goto fail;
    }
    if (!s->shm || !s->seat || !s->output || s->out_w <= 0 || s->out_h <= 0)
    {
        snprintf( err, errlen, "the session has no screen" );
        goto fail;
    }
    /* Absolute positions are on the captured output, not the whole layout. */
    if (s->pointer_manager_version >= 2)
        s->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output( s->pointer_manager, s->seat,
                                                                                          s->output );
    else
        s->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer( s->pointer_manager, s->seat );
    s->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard( s->keyboard_manager, s->seat );
    if (!s->pointer || !s->keyboard || upload_keymap( s ) < 0)
    {
        snprintf( err, errlen, "cannot create the virtual keyboard and pointer" );
        goto fail;
    }
    if (wl_display_roundtrip( s->display ) < 0)
    {
        snprintf( err, errlen, "the session's compositor closed the connection" );
        goto fail;
    }
    return s;

fail:
    sg_stream_free( s );
    return NULL;
}

static void free_buffer( struct sg_stream *s )
{
    if (s->buffer) wl_buffer_destroy( s->buffer );
    if (s->data) munmap( s->data, s->size );
    free( s->prev );
    s->buffer = NULL; s->data = NULL; s->prev = NULL; s->size = 0; s->have_prev = 0;
}

void sg_stream_free( struct sg_stream *s )
{
    if (!s) return;
    if (s->display && !s->gone) sg_stream_release_all( s );
    if (s->frame) zwlr_screencopy_frame_v1_destroy( s->frame );
    free_buffer( s );
    if (s->pointer) zwlr_virtual_pointer_v1_destroy( s->pointer );
    if (s->keyboard) zwp_virtual_keyboard_v1_destroy( s->keyboard );
    if (s->pointer_manager) zwlr_virtual_pointer_manager_v1_destroy( s->pointer_manager );
    if (s->keyboard_manager) zwp_virtual_keyboard_manager_v1_destroy( s->keyboard_manager );
    if (s->screencopy) zwlr_screencopy_manager_v1_destroy( s->screencopy );
    if (s->output) wl_output_destroy( s->output );
    if (s->seat) wl_seat_destroy( s->seat );
    if (s->shm) wl_shm_destroy( s->shm );
    if (s->registry) wl_registry_destroy( s->registry );
    if (s->display)
    {
        if (s->reading) wl_display_cancel_read( s->display );
        wl_display_flush( s->display );
        wl_display_disconnect( s->display );
    }
    if (s->state) xkb_state_unref( s->state );
    if (s->keymap) xkb_keymap_unref( s->keymap );
    if (s->xkb) xkb_context_unref( s->xkb );
    free( s );
}

void sg_stream_size( struct sg_stream *s, uint32_t *width, uint32_t *height )
{
    *width = (uint32_t)s->out_w;
    *height = (uint32_t)s->out_h;
}

int sg_stream_fd( struct sg_stream *s ) { return wl_display_get_fd( s->display ); }

void sg_stream_prepare( struct sg_stream *s )
{
    if (s->gone || s->reading) return;
    while (wl_display_prepare_read( s->display ) != 0)
        if (wl_display_dispatch_pending( s->display ) < 0) { s->gone = 1; return; }
    s->reading = 1;
    wl_display_flush( s->display );
}

int sg_stream_after_wait( struct sg_stream *s )
{
    struct pollfd p = { wl_display_get_fd( s->display ), POLLIN, 0 };

    if (s->gone) return -1;
    if (s->reading)
    {
        s->reading = 0;
        if (poll( &p, 1, 0 ) > 0 && (p.revents & (POLLIN | POLLHUP | POLLERR)))
        {
            if (wl_display_read_events( s->display ) < 0) { s->gone = 1; return -1; }
        }
        else wl_display_cancel_read( s->display );
    }
    if (wl_display_dispatch_pending( s->display ) < 0) { s->gone = 1; return -1; }
    if (wl_display_flush( s->display ) < 0 && errno != EAGAIN) { s->gone = 1; return -1; }
    return s->gone ? -1 : 0;
}

/* ---- frames -------------------------------------------------------------- */

static void request_frame( struct sg_stream *s );

static int make_buffer( struct sg_stream *s )
{
    struct wl_shm_pool *pool;
    size_t size = (size_t)s->stride * s->height;
    int fd;

    if (s->buffer && s->size == size) return 0;
    free_buffer( s );
    if ((fd = memfd_create( "sg-rdp-frame", MFD_CLOEXEC )) < 0) return -1;
    if (ftruncate( fd, (off_t)size ) < 0) { close( fd ); return -1; }
    s->data = mmap( NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 );
    if (s->data == MAP_FAILED) { s->data = NULL; close( fd ); return -1; }
    pool = wl_shm_create_pool( s->shm, fd, (int32_t)size );
    s->buffer = wl_shm_pool_create_buffer( pool, 0, (int32_t)s->width, (int32_t)s->height,
                                           (int32_t)s->stride, s->format );
    wl_shm_pool_destroy( pool );
    close( fd );
    s->size = size;
    if (!(s->prev = malloc( size ))) return -1;
    s->have_prev = 0;
    return 0;
}

static void frame_buffer( void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t format, uint32_t w, uint32_t h,
                          uint32_t stride )
{
    struct sg_stream *s = d;
    (void)f;
    /* 32-bit, blue first in memory: what bitmap updates carry. */
    if (format != WL_SHM_FORMAT_XRGB8888 && format != WL_SHM_FORMAT_ARGB8888) return;
    s->format = format; s->width = w; s->height = h; s->stride = stride;
    s->buffer_offered = 1;
}
static void frame_flags( void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags )
{
    (void)f;
    ((struct sg_stream *)d)->flags = flags;
}
static void frame_damage( void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t x, uint32_t y, uint32_t w, uint32_t h )
{
    (void)d; (void)f; (void)x; (void)y; (void)w; (void)h;   /* tiles are compared instead */
}
static void frame_dmabuf( void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fmt, uint32_t w, uint32_t h )
{
    (void)d; (void)f; (void)fmt; (void)w; (void)h;
}
static void frame_buffer_done( void *d, struct zwlr_screencopy_frame_v1 *f )
{
    struct sg_stream *s = d;

    if (!s->buffer_offered || make_buffer( s ) < 0)
    {
        fprintf( stderr, "sg-rdp-stream: no usable frame buffer\n" );
        s->gone = 1;
        return;
    }
    /* After the first frame, wait for damage: the compositor answers only when
     * something changed, which is what paces the stream. */
    if (s->have_prev) zwlr_screencopy_frame_v1_copy_with_damage( f, s->buffer );
    else zwlr_screencopy_frame_v1_copy( f, s->buffer );
}

static void flip_rows( struct sg_stream *s )
{
    uint8_t *row = malloc( s->stride ), *a, *b;
    uint32_t y;
    if (!row) return;
    for (y = 0; y < s->height / 2; y++)
    {
        a = (uint8_t *)s->data + (size_t)y * s->stride;
        b = (uint8_t *)s->data + (size_t)(s->height - 1 - y) * s->stride;
        memcpy( row, a, s->stride ); memcpy( a, b, s->stride ); memcpy( b, row, s->stride );
    }
    free( row );
}

static int tile_changed( struct sg_stream *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h )
{
    uint32_t r;
    if (!s->have_prev) return 1;
    for (r = 0; r < h; r++)
    {
        size_t off = (size_t)(y + r) * s->stride + (size_t)x * 4;
        if (memcmp( (uint8_t *)s->data + off, s->prev + off, (size_t)w * 4 )) return 1;
    }
    return 0;
}

static void remember_tile( struct sg_stream *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h )
{
    uint32_t r;
    for (r = 0; r < h; r++)
    {
        size_t off = (size_t)(y + r) * s->stride + (size_t)x * 4;
        memcpy( s->prev + off, (uint8_t *)s->data + off, (size_t)w * 4 );
    }
}

static BOOL flush_update( struct sg_stream *s, BITMAP_DATA *tiles, UINT32 n )
{
    BITMAP_UPDATE update = { 0 };
    BOOL ok;
    UINT32 i;

    if (!n) return TRUE;
    update.number = n;
    update.rectangles = tiles;
    ok = s->context->update->BitmapUpdate( s->context, &update );
    for (i = 0; i < n; i++) free( tiles[i].bitmapDataStream );
    return ok;
}

/* Send every tile that differs from what the client has. */
static void send_frame( struct sg_stream *s )
{
    rdpSettings *settings = s->context->settings;
    UINT32 max = freerdp_settings_get_uint32( settings, FreeRDP_MultifragMaxRequestSize );
    uint32_t cols = (s->width + TILE - 1) / TILE, rows = (s->height + TILE - 1) / TILE, tx, ty;
    BITMAP_DATA *tiles = calloc( (size_t)cols * rows, sizeof(*tiles) );
    UINT32 n = 0, bytes = 0;

    if (!tiles) return;
    if (max < 16384) max = 16384;
    for (ty = 0; ty < rows; ty++)
    {
        for (tx = 0; tx < cols; tx++)
        {
            uint32_t x = tx * TILE, y = ty * TILE;
            uint32_t w = s->width - x < TILE ? s->width - x : TILE;
            uint32_t h = s->height - y < TILE ? s->height - y : TILE;
            UINT32 size = w * h * 4, r, c;
            BYTE *data;

            if (!tile_changed( s, x, y, w, h )) continue;
            /* Uncompressed 32bpp: rows bottom-up, B G R A, as bitmap updates
             * have been since RDP 4. The transport's bulk compression still
             * applies. */
            if (!(data = malloc( size ))) continue;
            for (r = 0; r < h; r++)
            {
                const uint8_t *src = (uint8_t *)s->data + (size_t)(y + r) * s->stride + (size_t)x * 4;
                uint8_t *dst = data + (size_t)(h - 1 - r) * w * 4;
                memcpy( dst, src, (size_t)w * 4 );
                for (c = 0; c < w; c++) dst[c * 4 + 3] = 0xff;
            }
            if (n && bytes + size + 64 > max - 1024)
            {
                if (!flush_update( s, tiles, n )) { s->gone = 1; free( data ); free( tiles ); return; }
                n = 0; bytes = 0;
            }
            tiles[n].destLeft = x;
            tiles[n].destTop = y;
            tiles[n].destRight = x + w - 1;
            tiles[n].destBottom = y + h - 1;
            tiles[n].width = w;
            tiles[n].height = h;
            tiles[n].bitsPerPixel = 32;
            tiles[n].compressed = FALSE;
            tiles[n].bitmapDataStream = data;
            tiles[n].bitmapLength = size;
            tiles[n].cbScanWidth = w * 4;
            tiles[n].cbUncompressedSize = w * h * 4;
            n++;
            bytes += size + 64;
            remember_tile( s, x, y, w, h );
        }
    }
    if (!flush_update( s, tiles, n )) s->gone = 1;
    free( tiles );
    s->have_prev = 1;
}

/* SG_RDP_FRAME_DUMP=file.ppm: each captured frame, as captured, for telling a
 * capture problem from an encoding one. Debugging only. */
static void dump_frame( struct sg_stream *s )
{
    const char *path = getenv( "SG_RDP_FRAME_DUMP" );
    FILE *f;
    uint32_t x, y;

    if (!path || !(f = fopen( path, "wb" ))) return;
    fprintf( f, "P6\n%u %u\n255\n", s->width, s->height );
    for (y = 0; y < s->height; y++)
        for (x = 0; x < s->width; x++)
        {
            const uint8_t *p = (uint8_t *)s->data + (size_t)y * s->stride + x * 4;
            fputc( p[2], f ); fputc( p[1], f ); fputc( p[0], f );
        }
    fclose( f );
}

static void frame_ready( void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t hi, uint32_t lo, uint32_t ns )
{
    struct sg_stream *s = d;
    (void)hi; (void)lo; (void)ns;
    zwlr_screencopy_frame_v1_destroy( f );
    s->frame = NULL;
    if (s->flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) flip_rows( s );
    dump_frame( s );
    if (s->context) send_frame( s );
    if (!s->gone) request_frame( s );
}

static void frame_failed( void *d, struct zwlr_screencopy_frame_v1 *f )
{
    struct sg_stream *s = d;
    zwlr_screencopy_frame_v1_destroy( f );
    s->frame = NULL;
    /* The output changed under us (a mode set, say): start over whole. */
    s->have_prev = 0;
    if (!s->gone) request_frame( s );
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    frame_buffer, frame_flags, frame_ready, frame_failed, frame_damage, frame_dmabuf, frame_buffer_done,
};

static void request_frame( struct sg_stream *s )
{
    if (s->frame) return;
    s->buffer_offered = 0;
    s->flags = 0;
    /* overlay_cursor = 1: the pointer is drawn into the frame, so the client's
     * view is the screen as it is. */
    s->frame = zwlr_screencopy_manager_v1_capture_output( s->screencopy, 1, s->output );
    zwlr_screencopy_frame_v1_add_listener( s->frame, &frame_listener, s );
}

void sg_stream_start( struct sg_stream *s, rdpContext *context )
{
    s->context = context;
    s->have_prev = 0;
    request_frame( s );
    wl_display_flush( s->display );
}

/* ---- input --------------------------------------------------------------- */

static void send_modifiers( struct sg_stream *s )
{
    zwp_virtual_keyboard_v1_modifiers( s->keyboard,
        xkb_state_serialize_mods( s->state, XKB_STATE_MODS_DEPRESSED ),
        xkb_state_serialize_mods( s->state, XKB_STATE_MODS_LATCHED ),
        xkb_state_serialize_mods( s->state, XKB_STATE_MODS_LOCKED ),
        xkb_state_serialize_layout( s->state, XKB_STATE_LAYOUT_EFFECTIVE ) );
}

void sg_stream_key( struct sg_stream *s, uint32_t evdev, int down )
{
    if (s->gone || !evdev || evdev >= MAX_KEYS) return;
    if (!down && !s->keys_down[evdev]) return;    /* never release what was not pressed */
    s->keys_down[evdev] = (uint8_t)down;
    xkb_state_update_key( s->state, evdev + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP );
    zwp_virtual_keyboard_v1_key( s->keyboard, now_ms(), evdev,
                                 down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED );
    send_modifiers( s );
    wl_display_flush( s->display );
}

/* A character the client sent as text rather than as a key: typed as the key
 * that makes it in the us layout, with Shift if that takes Shift. */
void sg_stream_unicode( struct sg_stream *s, uint32_t codepoint )
{
    xkb_keysym_t sym = xkb_utf32_to_keysym( codepoint );
    xkb_keycode_t kc;
    xkb_level_index_t level;

    if (s->gone || sym == XKB_KEY_NoSymbol) return;
    for (level = 0; level < 2; level++)
        for (kc = xkb_keymap_min_keycode( s->keymap ); kc <= xkb_keymap_max_keycode( s->keymap ); kc++)
        {
            const xkb_keysym_t *syms;
            if (xkb_keymap_key_get_syms_by_level( s->keymap, kc, 0, level, &syms ) >= 1 && syms[0] == sym)
            {
                if (level) sg_stream_key( s, KEY_LEFTSHIFT, 1 );
                sg_stream_key( s, kc - 8, 1 );
                sg_stream_key( s, kc - 8, 0 );
                if (level) sg_stream_key( s, KEY_LEFTSHIFT, 0 );
                return;
            }
        }
}

void sg_stream_motion( struct sg_stream *s, uint32_t x, uint32_t y )
{
    if (s->gone) return;
    if (x >= (uint32_t)s->out_w) x = (uint32_t)s->out_w - 1;
    if (y >= (uint32_t)s->out_h) y = (uint32_t)s->out_h - 1;
    zwlr_virtual_pointer_v1_motion_absolute( s->pointer, now_ms(), x, y, (uint32_t)s->out_w, (uint32_t)s->out_h );
    zwlr_virtual_pointer_v1_frame( s->pointer );
    wl_display_flush( s->display );
}

void sg_stream_button( struct sg_stream *s, uint32_t button, int down )
{
    uint32_t bit;
    if (s->gone || button < BTN_LEFT || button > BTN_TASK) return;
    bit = 1u << (button - BTN_LEFT);
    if (!down && !(s->buttons_down & bit)) return;
    if (down) s->buttons_down |= bit; else s->buttons_down &= ~bit;
    zwlr_virtual_pointer_v1_button( s->pointer, now_ms(), button,
                                    down ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED );
    zwlr_virtual_pointer_v1_frame( s->pointer );
    wl_display_flush( s->display );
}

void sg_stream_wheel( struct sg_stream *s, int horizontal, int steps )
{
    uint32_t axis = horizontal ? WL_POINTER_AXIS_HORIZONTAL_SCROLL : WL_POINTER_AXIS_VERTICAL_SCROLL;
    uint32_t t = now_ms();
    if (s->gone || !steps) return;
    zwlr_virtual_pointer_v1_axis_source( s->pointer, WL_POINTER_AXIS_SOURCE_WHEEL );
    zwlr_virtual_pointer_v1_axis_discrete( s->pointer, t, axis, wl_fixed_from_int( 15 * steps ), steps );
    zwlr_virtual_pointer_v1_frame( s->pointer );
    wl_display_flush( s->display );
}

void sg_stream_release_all( struct sg_stream *s )
{
    uint32_t k, b;
    for (k = 0; k < MAX_KEYS; k++)
        if (s->keys_down[k]) sg_stream_key( s, k, 0 );
    for (b = 0; b < 32; b++)
        if (s->buttons_down & (1u << b)) sg_stream_button( s, BTN_LEFT + b, 0 );
}
