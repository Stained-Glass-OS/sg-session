/* RDP 6.0 bitmap compression ("planar"): an encoder of our own, written from
 * the published specification (MS-RDPEGDI 2.2.2.5.1 RDP6_BITMAP_STREAM and
 * 3.1.9 its compression), lossless only.
 *
 * Every RDP client since 6.0 -- Windows' own and FreeRDP -- decodes this
 * format for a compressed 32 bpp bitmap update (MS-RDPBCGR 2.2.9.1.1.3.1.2.2).
 * We send it without the alpha plane (the NA bit), so it needs a client that
 * advertised DRAW_ALLOW_SKIP_ALPHA in its bitmap capability set; with any
 * other client the stream stays uncompressed.
 *
 * What the encoder does: split the pixels into red, green and blue planes; in
 * each plane replace every scanline after the first by its difference from the
 * scanline before (vertical delta, sign folded into the low bit); then
 * run-length code each scanline with the spec's control bytes. No colour loss
 * and no chroma subsampling: the decoded pixels are exactly the input. A plane
 * set that does not shrink is sent raw instead (still planar, 3 bytes a pixel
 * instead of 4).
 *
 * Pure C, no FreeRDP: the unit test decodes with FreeRDP's planar decoder,
 * which is how we know a stock client reads it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef SG_PLANAR_H
#define SG_PLANAR_H

#include <stddef.h>
#include <stdint.h>

/* The most bytes sg_planar_encode can write for a w x h bitmap. */
size_t sg_planar_bound( unsigned w, unsigned h );

/* Encode a w x h region of 32 bpp pixels, blue first in memory (B G R x, as
 * wl_shm XRGB8888 is), `stride` bytes per row, top row first. The stream is
 * written bottom-up, as bitmap updates are. `out` must hold
 * sg_planar_bound(w, h) bytes. Returns the stream's length, or 0 if w or h is
 * 0 or too large (over 8192). */
size_t sg_planar_encode( const uint8_t *pixels, size_t stride, unsigned w, unsigned h, uint8_t *out );

#endif
