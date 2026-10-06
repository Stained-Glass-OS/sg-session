/* sg-smooth.h: drawn art with soft edges (a copy of sg-shell's src/sg-smooth.h,
 * for the greeter, Setup and the first-run setup).
 *
 * GDI draws lines, ellipses and polygons without antialiasing, so glyphs
 * drawn with them (Start's rail, its power button, the user's round badge)
 * had stepped edges, worse at 150% (David 2026-10-05: "low quality"). The art
 * is drawn SG_SS times larger on black and averaged down to pixels: a pixel
 * is as opaque as the share of it drawn on, coloured by the average of what
 * was drawn there (art never draws pure black), then blended in.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef SG_SMOOTH_H
#define SG_SMOOTH_H

#include <windows.h>
#include <stdlib.h>
#include <string.h>

#define SG_SS 4

/* draw: the art at SG_SS times its size, into a w*SG_SS x h*SG_SS DC */
typedef void (*sg_art_fn)(HDC dc, int w, int h, const void *arg);

static inline void sg_smooth(HDC dc, int x, int y, int w, int h, sg_art_fn draw, const void *arg)
{
    BITMAPINFO bi = { { sizeof(BITMAPINFOHEADER), w * SG_SS, -h * SG_SS, 1, 32, BI_RGB, 0, 0, 0, 0, 0 }, { { 0, 0, 0, 0 } } };
    BLENDFUNCTION bf = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    HDC dcs[2] = { 0 };
    HBITMAP bmps[2] = { 0 }, olds[2] = { 0 };
    BYTE *bits[2] = { 0 };
    int i, px, py, sx, sy, n = SG_SS * SG_SS, W = w * SG_SS;

    if (w <= 0 || h <= 0) return;
    for (i = 0; i < 2; i++) {
        if (i == 1) { bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h; }
        dcs[i] = CreateCompatibleDC(dc);
        bmps[i] = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, (void **)&bits[i], NULL, 0);
        if (!dcs[i] || !bmps[i]) goto done;
        olds[i] = SelectObject(dcs[i], bmps[i]);
        memset(bits[i], 0, (size_t)bi.bmiHeader.biWidth * -bi.bmiHeader.biHeight * 4);
    }
    draw(dcs[0], w * SG_SS, h * SG_SS, arg);
    GdiFlush();
    for (py = 0; py < h; py++)
        for (px = 0; px < w; px++) {
            unsigned int c[3] = { 0, 0, 0 }, a = 0;
            BYTE *out = bits[1] + (py * w + px) * 4;
            for (sy = 0; sy < SG_SS; sy++)
                for (sx = 0; sx < SG_SS; sx++) {
                    const BYTE *p = bits[0] + ((py * SG_SS + sy) * W + px * SG_SS + sx) * 4;
                    c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
                    if (p[0] | p[1] | p[2]) a += 255;
                }
            a /= n;   /* premultiplied: what was drawn on black is its share already */
            out[0] = (BYTE)min(c[0] / n, a); out[1] = (BYTE)min(c[1] / n, a); out[2] = (BYTE)min(c[2] / n, a); out[3] = (BYTE)a;
        }
    GdiAlphaBlend(dc, x, y, w, h, dcs[1], 0, 0, w, h, bf);
done:
    for (i = 0; i < 2; i++) {
        if (olds[i]) SelectObject(dcs[i], olds[i]);
        if (bmps[i]) DeleteObject(bmps[i]);
        if (dcs[i]) DeleteDC(dcs[i]);
    }
}

/* art never draws pure black (it would read as nothing): the darkest it gives */
static inline COLORREF sg_smooth_colour(COLORREF c) { return c == RGB(0, 0, 0) ? RGB(1, 1, 1) : c; }

/* ---- a supersampled region, and drop-in shapes ---------------------------------------------
 *
 * The callback above suits art drawn for it. For existing drawing code:
 *
 *   Drop-in shapes, with the pen and brush selected into dc, as GDI's own
 *   (same arguments, same pixels covered, soft edges):
 *       sg_ellipse, sg_round_rect, sg_pie, sg_chord   (bounding box: edges)
 *       sg_polygon, sg_polyline, sg_line, sg_arc      (points: pixel centres)
 *
 *   A region, for a glyph function drawing several shapes:
 *       struct sg_ss ss;
 *       HDC big = sg_ss_begin(&ss, dc, x, y, w, h, stroke);
 *       draw_the_glyph(big, ...);          its own coordinates, as on dc
 *       sg_ss_end(&ss);
 *     The big DC draws SG_SS times finer through a world transform; stroke
 *     is the width of the glyph's lines (level ones stay crisp); dc's pen, brush,
 *     colours and font are selected into it, and pens selected in it later
 *     are scaled too. A pen of width 0 is one pixel wide on dc but a quarter
 *     of one in the region: give glyphs real widths. No text or SetPixel.
 *
 * What is under the region is copied up first (each pixel SG_SS x SG_SS
 * times), so averaging it down gives it back unchanged where nothing was
 * drawn, and what was drawn blends into it -- any colour, black too.
 *
 * SG_MUTANT_JAGGED (a gate's mutant, defined before including this):
 * everything drawn by plain GDI, as before. */
struct sg_ss { HDC dc, big; HBITMAP bmp, old; HGDIOBJ opn, obr, ofn; HPEN own_pen; BYTE *bits; int x, y, w, h; };

/* the current pen of dc, as one for the big DC (SG_SS times wider; width 0 is 1) */
static inline HPEN sg__big_pen(HDC dc, BOOL inside)
{
    HPEN pen = GetCurrentObject(dc, OBJ_PEN);
    LOGBRUSH lb = { BS_SOLID, 0, 0 };
    DWORD style, width;
    EXTLOGPEN elp;
    LOGPEN lp;

    if (GetObjectType(pen) == OBJ_EXTPEN && GetObjectW(pen, sizeof(elp), &elp))
    {
        style = elp.elpPenStyle; width = elp.elpWidth; lb.lbColor = elp.elpColor;
        if (!(style & PS_GEOMETRIC)) width = 1;
    }
    else if (GetObjectW(pen, sizeof(lp), &lp))
    {
        style = lp.lopnStyle | PS_ENDCAP_ROUND | PS_JOIN_ROUND; width = lp.lopnWidth.x; lb.lbColor = lp.lopnColor;
    }
    else return NULL;
    if (pen == GetStockObject(DC_PEN)) lb.lbColor = GetDCPenColor(dc);
    if ((style & PS_STYLE_MASK) == PS_NULL) return NULL;
    if (!width) width = 1;
    style = (style & ~(PS_TYPE_MASK | PS_STYLE_MASK)) | PS_GEOMETRIC | (inside ? PS_INSIDEFRAME : (style & PS_STYLE_MASK) == PS_INSIDEFRAME ? PS_SOLID : (style & PS_STYLE_MASK));
    return ExtCreatePen(style, width * SG_SS, &lb, 0, NULL);
}

static inline int sg__pen_width(HDC dc)
{
    HPEN pen = GetCurrentObject(dc, OBJ_PEN);
    EXTLOGPEN elp;
    LOGPEN lp;
    if (GetObjectType(pen) == OBJ_EXTPEN && GetObjectW(pen, sizeof(elp), &elp))
        return (elp.elpPenStyle & PS_STYLE_MASK) == PS_NULL ? 0 : (elp.elpPenStyle & PS_GEOMETRIC) ? (int)elp.elpWidth : 1;
    if (GetObjectW(pen, sizeof(lp), &lp)) return (lp.lopnStyle & PS_STYLE_MASK) == PS_NULL ? 0 : max(1, lp.lopnWidth.x);
    return 1;
}

/* a big DC over x, y, w, h of dc, what is there copied up; xf: a world
 * transform from dc's coordinates (NULL: none, the caller works in big pixels) */
static inline HDC sg__open(struct sg_ss *s, HDC dc, int x, int y, int w, int h)
{
    BITMAPINFO bi = { { sizeof(BITMAPINFOHEADER), w * SG_SS, -h * SG_SS, 1, 32, BI_RGB, 0, 0, 0, 0, 0 }, { { 0, 0, 0, 0 } } };
    memset(s, 0, sizeof(*s));
    s->dc = dc; s->x = x; s->y = y; s->w = w; s->h = h;
    /* a DC already in GM_ADVANCED is a region's (or transformed): drawn as it is */
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || GetGraphicsMode(dc) == GM_ADVANCED) return NULL;
    if (!(s->big = CreateCompatibleDC(dc))) return NULL;
    if (!(s->bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, (void **)&s->bits, NULL, 0)))
    {
        DeleteDC(s->big); s->big = NULL;
        return NULL;
    }
    s->old = SelectObject(s->big, s->bmp);
    SetStretchBltMode(s->big, COLORONCOLOR);
    StretchBlt(s->big, 0, 0, w * SG_SS, h * SG_SS, dc, x, y, w, h, SRCCOPY);
    SetBkMode(s->big, GetBkMode(dc));
    SetBkColor(s->big, GetBkColor(dc));
    SetTextColor(s->big, GetTextColor(dc));
    SetPolyFillMode(s->big, GetPolyFillMode(dc));
    SetArcDirection(s->big, GetArcDirection(dc));
    SetDCBrushColor(s->big, GetDCBrushColor(dc));
    SetDCPenColor(s->big, GetDCPenColor(dc));
    s->obr = SelectObject(s->big, GetCurrentObject(dc, OBJ_BRUSH));
    s->ofn = SelectObject(s->big, GetCurrentObject(dc, OBJ_FONT));
    return s->big;
}

static inline void sg_ss_end(struct sg_ss *s)
{
    BITMAPINFO bi = { { sizeof(BITMAPINFOHEADER), s->w, -s->h, 1, 32, BI_RGB, 0, 0, 0, 0, 0 }, { { 0, 0, 0, 0 } } };
    HDC sdc;
    HBITMAP sbmp, sold;
    BYTE *sbits;
    int px, py, sx, sy, n = SG_SS * SG_SS, W = s->w * SG_SS;

    if (!s->big) return;
    GdiFlush();
    sdc = CreateCompatibleDC(s->dc);
    sbmp = CreateDIBSection(s->dc, &bi, DIB_RGB_COLORS, (void **)&sbits, NULL, 0);
    if (sdc && sbmp)
    {
        sold = SelectObject(sdc, sbmp);
        for (py = 0; py < s->h; py++)
            for (px = 0; px < s->w; px++)
            {
                unsigned int c[3] = { 0, 0, 0 };
                BYTE *out = sbits + (py * s->w + px) * 4;
                for (sy = 0; sy < SG_SS; sy++)
                    for (sx = 0; sx < SG_SS; sx++)
                    {
                        const BYTE *p = s->bits + ((py * SG_SS + sy) * W + px * SG_SS + sx) * 4;
                        c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
                    }
                out[0] = (BYTE)((c[0] + n / 2) / n); out[1] = (BYTE)((c[1] + n / 2) / n); out[2] = (BYTE)((c[2] + n / 2) / n); out[3] = 255;
            }
        BitBlt(s->dc, s->x, s->y, s->w, s->h, sdc, 0, 0, SRCCOPY);
        SelectObject(sdc, sold);
    }
    if (sbmp) DeleteObject(sbmp);
    if (sdc) DeleteDC(sdc);
    SelectObject(s->big, GetStockObject(BLACK_PEN));
    SelectObject(s->big, GetStockObject(WHITE_BRUSH));
    SelectObject(s->big, GetStockObject(SYSTEM_FONT));
    if (s->own_pen) DeleteObject(s->own_pen);
    SelectObject(s->big, s->old);
    DeleteObject(s->bmp);
    DeleteDC(s->big);
    s->big = NULL;
}

static inline HDC sg_ss_begin(struct sg_ss *s, HDC dc, int x, int y, int w, int h, int stroke)
{
#ifndef SG_MUTANT_JAGGED
    /* dc's pixel (px, py) is big's square at SG_SS * (px - x, py - y). A
     * line of odd width is centred on a pixel's centre (SG_SS / 2 further),
     * one of even width on its edge, as are fills: stroke, the width of the
     * glyph's lines (0: fills only), says which keeps its level lines crisp. */
    int o = stroke % 2 ? SG_SS / 2 : 0;
    XFORM xf = { (FLOAT)SG_SS, 0, 0, (FLOAT)SG_SS, (FLOAT)(-x * SG_SS + o), (FLOAT)(-y * SG_SS + o) };
    HDC big = sg__open(s, dc, x, y, w, h);
    if (!big) { s->big = NULL; return dc; }
    SetGraphicsMode(big, GM_ADVANCED);
    SetWorldTransform(big, &xf);
    s->opn = SelectObject(big, GetCurrentObject(dc, OBJ_PEN));   /* scaled when selected: after the transform */
    return big;
#else
    memset(s, 0, sizeof(*s));
    (void)x; (void)y; (void)w; (void)h; (void)stroke;
    return dc;
#endif
}

/* the drop-in shapes' common part: a region round the box (with the pen's
 * width), the pen made big, draw(), back down */
#define SG__SHAPE(dc, l, t, r, b, inside, DRAW) \
    do { \
        struct sg_ss s_; \
        int m_ = sg__pen_width(dc) + 2, ox_, oy_; \
        int x_ = min(l, r) - m_, y_ = min(t, b) - m_; \
        HDC big_ = sg__open(&s_, dc, x_, y_, abs((r) - (l)) + 2 * m_ + 1, abs((b) - (t)) + 2 * m_ + 1); \
        if (!big_) { ok_ = FALSE; break; } \
        s_.own_pen = sg__big_pen(dc, inside); \
        SelectObject(big_, s_.own_pen ? (HGDIOBJ)s_.own_pen : GetStockObject(NULL_PEN)); \
        ox_ = x_; oy_ = y_; \
        DRAW; \
        sg_ss_end(&s_); \
        ok_ = TRUE; \
    } while (0)
/* a bounding box coordinate (edges) and a point (pixel centre) in big pixels */
#define SG__E(v, o) (((v) - (o)) * SG_SS)
#define SG__P(v, o) (((v) - (o)) * SG_SS + SG_SS / 2)

static inline BOOL sg_ellipse(HDC dc, int l, int t, int r, int b)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    SG__SHAPE(dc, l, t, r, b, TRUE, Ellipse(big_, SG__E(l, ox_), SG__E(t, oy_), SG__E(r, ox_), SG__E(b, oy_)));
#endif
    return ok_ ? TRUE : Ellipse(dc, l, t, r, b);
}

static inline BOOL sg_round_rect(HDC dc, int l, int t, int r, int b, int rw, int rh)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    int cw = min(abs(r - l), rw / 2 + sg__pen_width(dc) + 2), ch = min(abs(b - t), rh / 2 + sg__pen_width(dc) + 2);
    /* a big one: GDI draws all but the corners (straight edges are not stepped), the corners are drawn smooth */
    if (abs(r - l) > 2 * cw + 8 && abs(b - t) > 2 * ch + 8 && r > l && b > t)
    {
        int i, cx[4] = { l, r - cw, l, r - cw }, cy[4] = { t, t, b - ch, b - ch };
        int sv = SaveDC(dc);
        for (i = 0; i < 4; i++) ExcludeClipRect(dc, cx[i], cy[i], cx[i] + cw, cy[i] + ch);
        RoundRect(dc, l, t, r, b, rw, rh);
        RestoreDC(dc, sv);
        for (i = 0; i < 4; i++)
        {
            struct sg_ss s_;
            HDC big_ = sg__open(&s_, dc, cx[i], cy[i], cw, ch);
            if (!big_) continue;
            s_.own_pen = sg__big_pen(dc, TRUE);
            SelectObject(big_, s_.own_pen ? (HGDIOBJ)s_.own_pen : GetStockObject(NULL_PEN));
            RoundRect(big_, SG__E(l, cx[i]), SG__E(t, cy[i]), SG__E(r, cx[i]), SG__E(b, cy[i]), rw * SG_SS, rh * SG_SS);
            sg_ss_end(&s_);
        }
        return TRUE;
    }
    SG__SHAPE(dc, l, t, r, b, TRUE, RoundRect(big_, SG__E(l, ox_), SG__E(t, oy_), SG__E(r, ox_), SG__E(b, oy_), rw * SG_SS, rh * SG_SS));
#endif
    return ok_ ? TRUE : RoundRect(dc, l, t, r, b, rw, rh);
}

static inline BOOL sg_pie(HDC dc, int l, int t, int r, int b, int x1, int y1, int x2, int y2)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    SG__SHAPE(dc, l, t, r, b, TRUE, Pie(big_, SG__E(l, ox_), SG__E(t, oy_), SG__E(r, ox_), SG__E(b, oy_),
                                           SG__P(x1, ox_), SG__P(y1, oy_), SG__P(x2, ox_), SG__P(y2, oy_)));
#endif
    return ok_ ? TRUE : Pie(dc, l, t, r, b, x1, y1, x2, y2);
}

static inline BOOL sg_chord(HDC dc, int l, int t, int r, int b, int x1, int y1, int x2, int y2)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    SG__SHAPE(dc, l, t, r, b, TRUE, Chord(big_, SG__E(l, ox_), SG__E(t, oy_), SG__E(r, ox_), SG__E(b, oy_),
                                             SG__P(x1, ox_), SG__P(y1, oy_), SG__P(x2, ox_), SG__P(y2, oy_)));
#endif
    return ok_ ? TRUE : Chord(dc, l, t, r, b, x1, y1, x2, y2);
}

/* an arc: GDI's pen runs along the pixels just inside the box */
static inline BOOL sg_arc(HDC dc, int l, int t, int r, int b, int x1, int y1, int x2, int y2)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    SG__SHAPE(dc, l, t, r, b, FALSE, Arc(big_, SG__E(l, ox_) + SG_SS / 2, SG__E(t, oy_) + SG_SS / 2, SG__E(r, ox_) - SG_SS / 2,
                                            SG__E(b, oy_) - SG_SS / 2, SG__P(x1, ox_), SG__P(y1, oy_), SG__P(x2, ox_), SG__P(y2, oy_)));
#endif
    return ok_ ? TRUE : Arc(dc, l, t, r, b, x1, y1, x2, y2);
}

static inline BOOL sg__points(HDC dc, const POINT *p, int n, BOOL fill)
{
    BOOL ok_ = FALSE;
#ifndef SG_MUTANT_JAGGED
    POINT few[64], *q = n <= 64 ? few : (POINT *)malloc(n * sizeof(POINT));
    int i, l, t, r, b;
    if (n <= 0 || !q) return FALSE;
    l = r = p[0].x; t = b = p[0].y;
    for (i = 1; i < n; i++) { l = min(l, p[i].x); r = max(r, p[i].x); t = min(t, p[i].y); b = max(b, p[i].y); }
    SG__SHAPE(dc, l, t, r, b, FALSE,
              { for (i = 0; i < n; i++) { q[i].x = SG__P(p[i].x, ox_); q[i].y = SG__P(p[i].y, oy_); }
                if (fill) Polygon(big_, q, n); else Polyline(big_, q, n); });
    if (q != few) free(q);
#endif
    return ok_ ? TRUE : fill ? Polygon(dc, p, n) : Polyline(dc, p, n);
}
static inline BOOL sg_polygon(HDC dc, const POINT *p, int n) { return sg__points(dc, p, n, TRUE); }
static inline BOOL sg_polyline(HDC dc, const POINT *p, int n) { return sg__points(dc, p, n, FALSE); }

/* a line from (x0, y0) to (x1, y1), the last point not drawn, as LineTo; the
 * current position is left at (x1, y1). Level and upright lines are not
 * stepped: GDI draws those. */
static inline void sg_line(HDC dc, int x0, int y0, int x1, int y1)
{
    if (x0 == x1 || y0 == y1) { MoveToEx(dc, x0, y0, NULL); LineTo(dc, x1, y1); return; }
    {
        POINT p[2] = { { x0, y0 }, { x1, y1 } };
        if (!sg__points(dc, p, 2, FALSE)) { MoveToEx(dc, x0, y0, NULL); LineTo(dc, x1, y1); }
        MoveToEx(dc, x1, y1, NULL);
    }
}

/* the display scale of what dc draws on, 1.0 at 96 DPI */
static inline double sg_dc_scale(HDC dc)
{
    int dpi = GetDeviceCaps(dc, LOGPIXELSY);
    return dpi > 0 ? dpi / 96.0 : 1.0;
}

#endif
