/* RDP 6.0 bitmap compression ("planar"): see sg-planar.h.
 *
 * The stream (MS-RDPEGDI 2.2.2.5.1):
 *
 *   FormatHeader  1 byte: CLL (bits 0-2, colour loss level; 0 = none, plain
 *                 RGB), CS (bit 3, chroma subsampling), RLE (bit 4), NA
 *                 (bit 5, no alpha plane)
 *   planes        red, green, blue (an alpha plane first unless NA); each
 *                 width x height bytes when raw, or RLE-coded scanlines
 *   Pad           1 byte, raw planes only
 *
 * An RLE plane (3.1.9.2): the first scanline holds the values themselves,
 * every later one the difference from the scanline above it -- taken modulo
 * 256 and read as a signed byte d, then stored as 2d for d >= 0 and
 * 2|d| - 1 for d < 0, so small changes either way are small numbers. Each
 * scanline is then a sequence of segments, each a control byte and the raw
 * bytes it announces:
 *
 *   control byte  low nibble nRunLength, high nibble cRawBytes: cRawBytes
 *                 values follow, then the last value (0 at the start of a
 *                 scanline) repeats nRunLength more times. nRunLength 1 and 2
 *                 are escapes for long runs with no raw bytes: the run is
 *                 cRawBytes + 16 or cRawBytes + 32.
 *
 * A segment never crosses the end of a scanline.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <string.h>

#include "sg-planar.h"

#define HDR_RLE 0x10
#define HDR_NA 0x20
#define MAX_SIDE 8192

/* Bytes a worst-case RLE scanline of w values takes: every value raw, a
 * control byte per 15 of them. */
static size_t rle_line_bound( unsigned w )
{
    return (size_t)w + (w + 14) / 15;
}

size_t sg_planar_bound( unsigned w, unsigned h )
{
    size_t rle = 1 + 3 * (size_t)h * rle_line_bound( w );
    size_t raw = 1 + 3 * (size_t)w * h + 1;
    return rle > raw ? rle : raw;
}

static uint8_t control( unsigned run, unsigned raw )
{
    return (uint8_t)((run & 0x0f) | ((raw & 0x0f) << 4));
}

/* How many values from v[i] on equal `value`. */
static unsigned run_of( const uint8_t *v, unsigned i, unsigned w, uint8_t value )
{
    unsigned n = 0;
    while (i + n < w && v[i + n] == value) n++;
    return n;
}

/* RLE-code one scanline of w values; returns the bytes written. */
static size_t rle_line( const uint8_t *v, unsigned w, uint8_t *out )
{
    size_t n = 0;
    unsigned i = 0;
    uint8_t last = 0;   /* what a run repeats: the decoder starts each line at 0 */

    while (i < w)
    {
        unsigned run = run_of( v, i, w, last ), raw = 0, follow = 0, start = i;

        /* A run of the last value on its own: control bytes and nothing
         * else. Runs of one or two cost less as raw bytes (and cannot be
         * said without them). */
        if (run >= 3)
        {
            while (run >= 3)
            {
                unsigned c;
                if (run >= 32) { c = run > 47 ? 47 : run; out[n++] = control( 2, c - 32 ); }
                else if (run >= 16) { c = run; out[n++] = control( 1, c - 16 ); }
                else { c = run; out[n++] = control( c, 0 ); }
                run -= c;
                i += c;
            }
            continue;
        }
        /* Raw values, up to 15, until one is followed by a run worth
         * taking; that run (up to 15) rides on the same control byte. */
        while (i < w && raw < 15)
        {
            uint8_t b = v[i++];
            raw++;
            follow = run_of( v, i, w, b );
            if (follow >= 3) break;
            follow = 0;
        }
        if (follow > 15) follow = 15;
        out[n++] = control( follow, raw );
        memcpy( out + n, v + start, raw );
        n += raw;
        i += follow;
        last = v[i - 1];
    }
    return n;
}

/* The vertical delta of one value against the one above, as stored. */
static uint8_t fold_delta( uint8_t cur, uint8_t above )
{
    int d = (int8_t)(uint8_t)(cur - above);
#ifndef SG_MUTANT_PLANAR_DELTA
    return d >= 0 ? (uint8_t)(d << 1) : (uint8_t)(((-d) << 1) - 1);
#else
    /* the mistake FreeRDP 3.15's own encoder makes: no sign at all */
    return (uint8_t)(d << 1);
#endif
}

size_t sg_planar_encode( const uint8_t *pixels, size_t stride, unsigned w, unsigned h, uint8_t *out )
{
    uint8_t line[MAX_SIDE], above[MAX_SIDE], coded[MAX_SIDE];
    size_t n = 1, raw_size = 1 + 3 * (size_t)w * h + 1;
    unsigned plane, y, x;

    if (!w || !h || w > MAX_SIDE || h > MAX_SIDE) return 0;

    /* RLE first; if it does not beat raw planes, raw planes it is. */
    out[0] = HDR_NA | HDR_RLE;
    for (plane = 0; plane < 3; plane++)
    {
        /* red, green, blue: bytes 2, 1, 0 of each B G R x pixel */
        unsigned byte = 2 - plane;
        for (y = 0; y < h; y++)
        {
            /* bottom-up: the stream's first scanline is the bottom row */
            const uint8_t *row = pixels + (size_t)(h - 1 - y) * stride;
            for (x = 0; x < w; x++) line[x] = row[x * 4 + byte];
            if (y)
                for (x = 0; x < w; x++) coded[x] = fold_delta( line[x], above[x] );
            else
                memcpy( coded, line, w );
            memcpy( above, line, w );
            if (n + rle_line_bound( w ) > raw_size) goto raw;   /* not worth it */
            n += rle_line( coded, w, out + n );
        }
    }
    if (n < raw_size) return n;

raw:
    out[0] = HDR_NA;
    n = 1;
    for (plane = 0; plane < 3; plane++)
    {
        unsigned byte = 2 - plane;
        for (y = 0; y < h; y++)
        {
            const uint8_t *row = pixels + (size_t)(h - 1 - y) * stride;
            for (x = 0; x < w; x++) out[n++] = row[x * 4 + byte];
        }
    }
    out[n++] = 0;   /* Pad */
    return n;
}
