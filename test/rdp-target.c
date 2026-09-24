/* A session for the RDP streaming gate to look at and type into.
 *
 * Fills the screen with one known colour, so the gate can tell from the RDP
 * client's own window that the session's frames arrived; logs every character
 * and every left click it receives to the file named on its command line, so
 * the gate can tell the client's keyboard and mouse arrived too.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>

#define COLOUR RGB(0x12, 0x9A, 0x3C)

static FILE *g_log;

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
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
