/* A session for the RDP streaming gate to look at and type into.
 *
 * Fills the screen with one known colour, so the gate can tell from the RDP
 * client's own window that the session's frames arrived; logs every character
 * and every left click it receives to the file named on its command line, so
 * the gate can tell the client's keyboard and mouse arrived too.
 *
 * Below the colour: a band of vertical gradients (every red value, green
 * falling, blue in steps that wrap -- changes from one row to the next of
 * either sign, large and small, which a planar encoder must get exactly
 * right) and lines of text on white, which F5 scrolls up a line (a scrolling
 * text frame, for the bandwidth figures).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>

#define COLOUR RGB(0x12, 0x9A, 0x3C)

static FILE *g_log;
static int g_top;    /* the first text line shown */

#define BAND_Y 360
#define BAND_H 128
#define TEXT_Y (BAND_Y + BAND_H + 4)
#define LINE_H 16

static void paint( HWND hwnd, HDC dc )
{
    RECT rc, text;
    int y, i, w;
    char line[160];

    GetClientRect( hwnd, &rc );
    w = rc.right;
    for (y = 0; y < BAND_H; y++)
    {
        int x;
        for (x = 0; x < w; x += 128)
        {
            /* three different bands side by side */
            int k = (x / 128) % 3, r = y * 2, g = 255 - y * 2, b = (y * 37) & 255;
            HBRUSH br;
            RECT strip = { x, BAND_Y + y, x + 128 < w ? x + 128 : w, BAND_Y + y + 1 };
            br = CreateSolidBrush( k == 0 ? RGB( r, g, b ) : k == 1 ? RGB( b, r, g ) : RGB( g, b, (y & 1) ? 255 : 0 ) );
            FillRect( dc, &strip, br );
            DeleteObject( br );
        }
    }
    SetRect( &text, 0, TEXT_Y, w, rc.bottom );
    FillRect( dc, &text, GetStockObject( WHITE_BRUSH ) );
    SelectObject( dc, GetStockObject( ANSI_FIXED_FONT ) );
    SetTextColor( dc, RGB( 0x10, 0x10, 0x10 ) );
    SetBkMode( dc, TRANSPARENT );
    for (i = 0; TEXT_Y + 2 + i * LINE_H < rc.bottom; i++)
    {
        /* a different line every time, as prose is */
        static const char *words[] = { "glass", "window", "the", "of", "remote", "desktop", "a", "frame",
                                       "stained", "light", "colour", "and", "session", "pixel", "to", "lead" };
        int n = snprintf( line, sizeof(line), "%4d ", g_top + i ), j;
        unsigned k = (unsigned)(g_top + i) * 2654435761u;
        for (j = 0; j < 14 && n < 110; j++, k = k * 1103515245u + 12345u)
            n += snprintf( line + n, sizeof(line) - n, " %s", words[(k >> 16) % 16] );
        TextOutA( dc, 8, TEXT_Y + 2 + i * LINE_H, line, n );
    }
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint( hwnd, &ps );
        paint( hwnd, dc );
        EndPaint( hwnd, &ps );
        return 0;
    }
    case WM_KEYDOWN:
        if (wp == VK_F5)
        {
            RECT rc;
            GetClientRect( hwnd, &rc );
            rc.top = TEXT_Y;
            g_top++;
            InvalidateRect( hwnd, &rc, FALSE );
            UpdateWindow( hwnd );
            if (g_log) { fprintf( g_log, "scrolled %d\n", g_top ); fflush( g_log ); }
        }
        break;
    case WM_CHAR:
        if (g_log) { fprintf( g_log, "char %c\n", (char)wp ); fflush( g_log ); }
        return 0;
    case WM_LBUTTONDOWN:
        if (g_log) { fprintf( g_log, "click %d %d\n", (short)LOWORD(lp), (short)HIWORD(lp) ); fflush( g_log ); }
        SetFocus( hwnd );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show )
{
    WNDCLASSA wc = {0};
    MSG msg;
    HWND hwnd;

    (void)prev; (void)show;
    if (cmdline && *cmdline) g_log = fopen( cmdline, "a" );
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.hbrBackground = CreateSolidBrush( COLOUR );
    wc.lpszClassName = "SgRdpTarget";
    RegisterClassA( &wc );
    hwnd = CreateWindowExA( 0, "SgRdpTarget", "RDP target", WS_POPUP | WS_VISIBLE, 0, 0,
                            GetSystemMetrics( SM_CXSCREEN ), GetSystemMetrics( SM_CYSCREEN ), NULL, NULL, inst, NULL );
    SetForegroundWindow( hwnd );
    SetFocus( hwnd );
    if (g_log) { fprintf( g_log, "ready %dx%d\n", GetSystemMetrics( SM_CXSCREEN ), GetSystemMetrics( SM_CYSCREEN ) ); fflush( g_log ); }
    while (GetMessageA( &msg, NULL, 0, 0 ))
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
    return 0;
}
