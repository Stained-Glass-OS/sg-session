/* The planar encoder (rdp/sg-planar.c) against a stock client's decoder.
 *
 *   planar-test                 round trips: our encoder, FreeRDP's planar
 *                               decoder (what xfreerdp runs), pixel for pixel
 *   planar-test bench A.ppm [B.ppm]
 *                               bytes for frame A as 64x64 tiles, planar vs
 *                               uncompressed; with B, for the tiles that
 *                               differ between A and B (a frame update)
 *
 * The round trips cover what breaks a planar encoder: vertical changes of
 * more than 127 either way (the sign folding and its modulo), runs of every
 * length across the 15/16/31/32/47 boundaries, odd sizes, noise that does
 * not compress (raw planes), and flat colour that compresses to almost
 * nothing.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/codec/color.h>
#include <freerdp/codec/planar.h>

#include "sg-planar.h"

#define TILE 64

static unsigned g_seed = 12345;
static unsigned rnd( void )
{
    g_seed = g_seed * 1103515245u + 12345u;
    return (g_seed >> 16) & 0x7fff;
}

static int round_trip( const char *name, const uint8_t *px, unsigned w, unsigned h, size_t stride, int quiet )
{
    BITMAP_PLANAR_CONTEXT *ctx = freerdp_bitmap_planar_context_new( 0, w, h );
    uint8_t *enc = malloc( sg_planar_bound( w, h ) ), *dec = calloc( (size_t)w * h, 4 );
    size_t n = sg_planar_encode( px, stride, w, h, enc );
    unsigned x, y, bad = 0;
    int ok;

    freerdp_planar_switch_bgr( ctx, FALSE );
    ok = n && planar_decompress( ctx, enc, (UINT32)n, w, h, dec, PIXEL_FORMAT_BGRX32, w * 4, 0, 0, w, h, TRUE );
    for (y = 0; ok && y < h; y++)
        for (x = 0; x < w; x++)
            if (memcmp( px + (size_t)y * stride + x * 4, dec + ((size_t)y * w + x) * 4, 3 )) bad++;
    if (!ok || bad) printf( "FAIL  %s %ux%u: %s, %u pixels differ\n", name, w, h, ok ? "decoded" : "not decoded", bad );
    else if (!quiet) printf( "PASS  %s %ux%u: %zu bytes (%s; uncompressed %u)\n", name, w, h, n,
                             enc[0] & 0x10 ? "RLE" : "raw planes", w * h * 4 );
    free( enc ); free( dec );
    freerdp_bitmap_planar_context_free( ctx );
    return ok && !bad;
}

typedef void (*fill_fn)( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h );

static void f_flat( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{ (void)x; (void)y; (void)w; (void)h; p[0] = 0x3c; p[1] = 0x9a; p[2] = 0x12; p[3] = 0; }
static void f_noise( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{ (void)x; (void)y; (void)w; (void)h; p[0] = (uint8_t)rnd(); p[1] = (uint8_t)rnd(); p[2] = (uint8_t)rnd(); p[3] = (uint8_t)rnd(); }
/* rows alternating 0 and 255, and 255 and 1: every delta is +-255 or +-254 */
static void f_stripes( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{ (void)x; (void)w; (void)h; p[0] = y & 1 ? 0xff : 0x00; p[1] = y & 1 ? 0x01 : 0xff; p[2] = (uint8_t)(y * 129); p[3] = 0; }
static void f_gradient( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{ p[0] = (uint8_t)(x * 255 / (w > 1 ? w - 1 : 1)); p[1] = (uint8_t)(y * 255 / (h > 1 ? h - 1 : 1)); p[2] = (uint8_t)(x ^ y); p[3] = 0xff; }
/* runs of length 1..50 of alternating colours: every control-byte case */
static void f_runs( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{
    unsigned k = 0, len = 1 + y % 50, pos = x;
    (void)w; (void)h;
    while (pos >= len) { pos -= len; k++; len = 1 + (len + 7 * y) % 50; }
    p[0] = (uint8_t)(k * 77); p[1] = (uint8_t)(k & 1 ? 200 : 10); p[2] = (uint8_t)(y & 4 ? 255 - k : k); p[3] = 0;
}
/* black text-like strokes on white: what a document or a terminal is */
static void f_text( uint8_t *p, unsigned x, unsigned y, unsigned w, unsigned h )
{
    unsigned line = y % 16, col = x % 8;
    int ink = line >= 3 && line < 13 && col < 6 && ((x / 8 * 7 + y / 16 * 13 + line * col) % 5 < 2);
    (void)w; (void)h;
    p[0] = p[1] = p[2] = ink ? 0x10 : 0xff; p[3] = 0;
}

static int run_tests( void )
{
    static const struct { const char *name; fill_fn fill; } fills[] = {
        { "flat", f_flat }, { "noise", f_noise }, { "stripes", f_stripes }, { "gradient", f_gradient },
        { "runs", f_runs }, { "text", f_text },
    };
    static const unsigned sizes[][2] = { { 64, 64 }, { 1, 1 }, { 3, 7 }, { 17, 64 }, { 64, 5 }, { 60, 33 },
                                         { 200, 100 }, { 16, 1 }, { 47, 2 }, { 48, 3 } };
    unsigned f, s, x, y;
    int ok = 1;

    for (f = 0; f < sizeof(fills) / sizeof(fills[0]); f++)
        for (s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++)
        {
            unsigned w = sizes[s][0], h = sizes[s][1];
            size_t stride = (size_t)w * 4 + 12;   /* a stride wider than the region */
            uint8_t *px = calloc( stride, h );
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++) fills[f].fill( px + y * stride + x * 4, x, y, w, h );
            ok &= round_trip( fills[f].name, px, w, h, stride, s != 0 );
            free( px );
        }
    /* many random images with random runs: the fuzz part */
    for (s = 0; s < 300; s++)
    {
        unsigned w = 1 + rnd() % 64, h = 1 + rnd() % 64, i;
        uint8_t *px = malloc( (size_t)w * h * 4 );
        uint8_t c[4] = { 0 };
        char name[32];
        for (i = 0; i < w * h; i++)
        {
            if (rnd() % 8 == 0) { c[0] = (uint8_t)rnd(); c[1] = (uint8_t)rnd(); c[2] = (uint8_t)rnd(); }
            memcpy( px + i * 4, c, 4 );
        }
        snprintf( name, sizeof(name), "fuzz%u", s );
        ok &= round_trip( name, px, w, h, (size_t)w * 4, 1 );
        free( px );
    }
    printf( "%s  300 random images with runs\n", ok ? "PASS" : "(see above)" );
    return ok;
}

/* ---- bench: bytes for real frames ---------------------------------------- */

static uint8_t *read_ppm( const char *path, unsigned *w, unsigned *h )
{
    FILE *f = fopen( path, "rb" );
    uint8_t *rgb, *px;
    unsigned max, i;

    if (!f || fscanf( f, "P6 %u %u %u", w, h, &max ) != 3 || max != 255 || fgetc( f ) == EOF) { if (f) fclose( f ); return NULL; }
    rgb = malloc( (size_t)*w * *h * 3 );
    px = malloc( (size_t)*w * *h * 4 );
    if (fread( rgb, 3, (size_t)*w * *h, f ) != (size_t)*w * *h) { fclose( f ); free( rgb ); free( px ); return NULL; }
    fclose( f );
    for (i = 0; i < *w * *h; i++)
    {
        px[i * 4] = rgb[i * 3 + 2]; px[i * 4 + 1] = rgb[i * 3 + 1]; px[i * 4 + 2] = rgb[i * 3]; px[i * 4 + 3] = 0;
    }
    free( rgb );
    return px;
}

static int bench( const char *a_path, const char *b_path )
{
    unsigned w, h, w2, h2, tx, ty, tiles = 0, r;
    uint8_t *a = read_ppm( a_path, &w, &h ), *b = b_path ? read_ppm( b_path, &w2, &h2 ) : NULL, *frame, *enc;
    size_t planar = 0, raw = 0;
    int ok = 1;

    if (!a || (b_path && (!b || w2 != w || h2 != h))) { fprintf( stderr, "cannot read the frames\n" ); return 2; }
    frame = b ? b : a;
    enc = malloc( sg_planar_bound( TILE, TILE ) );
    for (ty = 0; ty < (h + TILE - 1) / TILE; ty++)
        for (tx = 0; tx < (w + TILE - 1) / TILE; tx++)
        {
            unsigned x = tx * TILE, y = ty * TILE, tw = w - x < TILE ? w - x : TILE, th = h - y < TILE ? h - y : TILE;
            const uint8_t *p = frame + ((size_t)y * w + x) * 4;
            int changed = !b;
            for (r = 0; !changed && r < th; r++)
                changed = memcmp( a + ((size_t)(y + r) * w + x) * 4, p + (size_t)r * w * 4, (size_t)tw * 4 ) != 0;
            if (!changed) continue;
            tiles++;
            raw += (size_t)tw * th * 4;
            planar += sg_planar_encode( p, (size_t)w * 4, tw, th, enc );
            ok &= round_trip( "tile", p, tw, th, (size_t)w * 4, 1 );
        }
    printf( "%ux%u, %u tile(s) sent: uncompressed %zu bytes, planar %zu bytes (%.1f%%, %.1fx smaller)%s\n",
            w, h, tiles, raw, planar, raw ? 100.0 * planar / raw : 0, planar ? (double)raw / planar : 0,
            ok ? "" : " -- ROUND TRIP FAILED" );
    free( enc ); free( a ); free( b );
    return ok ? 0 : 1;
}

int main( int argc, char **argv )
{
    if (argc >= 3 && !strcmp( argv[1], "bench" )) return bench( argv[2], argc > 3 ? argv[3] : NULL );
    if (run_tests()) { printf( "RESULT: PASS\n" ); return 0; }
    printf( "RESULT: FAIL\n" );
    return 1;
}
