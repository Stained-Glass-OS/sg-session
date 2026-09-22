/* The Stained Glass login screen.
 *
 * A Windows program, deliberately. RMM and remote-desktop tools are Windows
 * programs that attach to the console session and expect to find a Windows
 * login screen there; a Linux greeter is invisible to all of them, and a fleet
 * machine that cannot be reached when logged out is not supportable. See
 * ADR 0008.
 *
 * It does not decide anything. It collects what the user types and passes it
 * to sg-greet-bridge over the pipes it was started with; PAM, on the Linux
 * side, remains the only authority on whether a login succeeds.
 *
 * Protocol, line-based, greeter -> bridge and back:
 *
 *   <- READY                      bridge is up
 *   -> USER <name>                begin a session for this account
 *   <- PROMPT_SECRET <text>       ask for something, echo off
 *   <- PROMPT_VISIBLE <text>      ask for something, echo on
 *   -> REPLY <text>               the answer
 *   <- INFO <text> | ERROR <text> show this to the user
 *   <- SUCCESS                    authenticated; the session is starting
 *   <- FAILURE <text>             rejected; start again
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define ID_USER   101
#define ID_SECRET 102
#define ID_SUBMIT 103
#define ID_STATUS 104
#define ID_PROMPT 105

static HANDLE g_in, g_out;
static HWND g_user, g_secret, g_submit, g_status, g_prompt;
static HFONT g_font_big, g_font, g_font_small;
static HBRUSH g_bg;
static HWND g_title;
static BOOL g_awaiting_secret = FALSE;
static BOOL g_done = FALSE;

/* Windows 10's sign-in screen is a flat blue field; matching it is the whole
 * point of this program existing. */
static const COLORREF COL_BG     = RGB(0x1F, 0x4E, 0x79);
static const COLORREF COL_TEXT   = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_ERR    = RGB(0xFF, 0xD1, 0x6A);

static void send_line( const char *fmt, ... )
{
    char buf[1024];
    va_list ap;
    DWORD written;
    int n;

    va_start( ap, fmt );
    n = vsnprintf( buf, sizeof(buf) - 2, fmt, ap );
    va_end( ap );
    if (n < 0) return;
    buf[n++] = '\n';
    WriteFile( g_out, buf, (DWORD)n, &written, NULL );
    FlushFileBuffers( g_out );
}

/* One line from the bridge. Reads a byte at a time: these are short control
 * lines, and buffering across messages would mean holding a reply we have not
 * acted on yet. */
static BOOL read_line( char *buf, size_t max )
{
    size_t i = 0;
    DWORD got;

    while (i < max - 1)
    {
        if (!ReadFile( g_in, buf + i, 1, &got, NULL ) || !got) return FALSE;
        if (buf[i] == '\n') break;
        if (buf[i] != '\r') i++;
    }
    buf[i] = 0;
    return TRUE;
}

static void set_status( const char *text, BOOL is_error )
{
    SetWindowTextA( g_status, text );
    SetWindowLongPtrA( g_status, GWLP_USERDATA, is_error );
    InvalidateRect( g_status, NULL, TRUE );
}

static void submit( void )
{
    char buf[512];

    if (g_done) return;
    if (!g_awaiting_secret)
    {
        GetWindowTextA( g_user, buf, sizeof(buf) );
        if (!buf[0]) { set_status( "Enter a user name.", TRUE ); return; }
        set_status( "Signing in...", FALSE );
        EnableWindow( g_submit, FALSE );
        send_line( "USER %s", buf );
    }
    else
    {
        GetWindowTextA( g_secret, buf, sizeof(buf) );
        set_status( "Signing in...", FALSE );
        EnableWindow( g_submit, FALSE );
        send_line( "REPLY %s", buf );
        /* Do not keep it in the control, and do not keep it here either. */
        SetWindowTextA( g_secret, "" );
        SecureZeroMemory( buf, sizeof(buf) );
    }
}

/* Drain whatever the bridge has said. Called from a timer so the UI thread
 * never blocks on a read: a greeter that stops repainting while PAM thinks is
 * indistinguishable from a hung machine. */
static void pump_bridge( HWND hwnd )
{
    char line[1024];
    DWORD avail = 0;

    while (PeekNamedPipe( g_in, NULL, 0, NULL, &avail, NULL ) && avail)
    {
        if (!read_line( line, sizeof(line) )) return;

        if (!strncmp( line, "PROMPT_SECRET ", 14 ))
        {
            g_awaiting_secret = TRUE;
            SetWindowTextA( g_prompt, line + 14 );
            ShowWindow( g_secret, SW_SHOW );
            EnableWindow( g_submit, TRUE );
            SetFocus( g_secret );
            set_status( "", FALSE );
        }
        else if (!strncmp( line, "PROMPT_VISIBLE ", 15 ))
        {
            g_awaiting_secret = TRUE;
            SetWindowTextA( g_prompt, line + 15 );
            ShowWindow( g_secret, SW_SHOW );
            EnableWindow( g_submit, TRUE );
            SetFocus( g_secret );
        }
        else if (!strncmp( line, "SUCCESS", 7 ))
        {
            g_done = TRUE;
            set_status( "Welcome", FALSE );
            PostMessage( hwnd, WM_CLOSE, 0, 0 );
        }
        else if (!strncmp( line, "FAILURE ", 8 ))
        {
            g_awaiting_secret = FALSE;
            SetWindowTextA( g_prompt, "" );
            ShowWindow( g_secret, SW_HIDE );
            SetWindowTextA( g_secret, "" );
            EnableWindow( g_submit, TRUE );
            set_status( line + 8, TRUE );
            SetFocus( g_user );
        }
        else if (!strncmp( line, "ERROR ", 6 ))
        {
            EnableWindow( g_submit, TRUE );
            set_status( line + 6, TRUE );
        }
        else if (!strncmp( line, "INFO ", 5 ))
        {
            set_status( line + 5, FALSE );
        }
    }
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_CTLCOLORSTATIC:
    {
        HDC dc = (HDC)wp;
        /* A real brush, not NULL_BRUSH. A transparent static never erases what
         * it drew last time, so any change of text or font leaves the previous
         * one underneath -- two overlapping titles in different sizes, which
         * looks like a font bug and is really a painting one. */
        SetBkColor( dc, COL_BG );
        SetTextColor( dc, GetWindowLongPtrA( (HWND)lp, GWLP_USERDATA ) ? COL_ERR : COL_TEXT );
        return (LRESULT)g_bg;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == ID_SUBMIT) submit();
        return 0;
    case WM_TIMER:
        pump_bridge( hwnd );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static HFONT make_font( int height, int weight )
{
    return CreateFontA( height, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI" );
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show )
{
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;
    int sw, sh, cx, cy;

    (void)prev; (void)cmdline; (void)show;
    g_in  = GetStdHandle( STD_INPUT_HANDLE );
    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    g_font_big   = make_font( 42, FW_LIGHT );
    g_font       = make_font( 20, FW_NORMAL );
    g_font_small = make_font( 16, FW_NORMAL );

    wc.lpfnWndProc   = wndproc;
    wc.hInstance     = inst;
    wc.hCursor       = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    g_bg = CreateSolidBrush( COL_BG );
    wc.hbrBackground = g_bg;
    wc.lpszClassName = "SgGreeter";
    RegisterClassA( &wc );

    sw = GetSystemMetrics( SM_CXSCREEN );
    sh = GetSystemMetrics( SM_CYSCREEN );

    /* Fills the desktop: this is the login screen, not a dialog on top of
     * something. WS_POPUP so it carries no caption or border. */
    hwnd = CreateWindowExA( 0, "SgGreeter", "Sign in", WS_POPUP | WS_VISIBLE,
                            0, 0, sw, sh, NULL, NULL, inst, NULL );

    cx = sw / 2;
    cy = sh / 2 - 60;

    g_title = CreateWindowExA( 0, "STATIC", "Stained Glass OS",
                     WS_CHILD | WS_VISIBLE | SS_CENTER,
                     cx - 300, cy - 130, 600, 52, hwnd, NULL, inst, NULL );

    CreateWindowExA( 0, "STATIC", "User name", WS_CHILD | WS_VISIBLE,
                     cx - 150, cy - 40, 300, 22, hwnd, NULL, inst, NULL );
    g_user = CreateWindowExA( WS_EX_CLIENTEDGE, "EDIT", "",
                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                     cx - 150, cy - 16, 300, 30, hwnd, (HMENU)ID_USER, inst, NULL );

    g_prompt = CreateWindowExA( 0, "STATIC", "", WS_CHILD | WS_VISIBLE,
                     cx - 150, cy + 26, 300, 22, hwnd, (HMENU)ID_PROMPT, inst, NULL );
    g_secret = CreateWindowExA( WS_EX_CLIENTEDGE, "EDIT", "",
                     WS_CHILD | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
                     cx - 150, cy + 50, 300, 30, hwnd, (HMENU)ID_SECRET, inst, NULL );

    g_submit = CreateWindowExA( 0, "BUTTON", "Sign in",
                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                     cx - 150, cy + 94, 300, 32, hwnd, (HMENU)ID_SUBMIT, inst, NULL );

    g_status = CreateWindowExA( 0, "STATIC", "", WS_CHILD | WS_VISIBLE | SS_CENTER,
                     cx - 300, cy + 140, 600, 44, hwnd, (HMENU)ID_STATUS, inst, NULL );

    /* Set once, at creation. Sweeping every child afterwards is how the title
     * ended up with two fonts painted on top of each other. */
    {
        HWND c;
        for (c = GetWindow( hwnd, GW_CHILD ); c; c = GetWindow( c, GW_HWNDNEXT ))
        {
            HFONT f = g_font;
            if (c == g_title)  f = g_font_big;
            if (c == g_status) f = g_font_small;
            SendMessageA( c, WM_SETFONT, (WPARAM)f, TRUE );
        }
    }

    SetFocus( g_user );
    SetTimer( hwnd, 1, 50, NULL );
    send_line( "HELLO" );

    while (GetMessageA( &msg, NULL, 0, 0 ))
    {
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_RETURN) { submit(); continue; }
        if (!IsDialogMessageA( hwnd, &msg ))
        {
            TranslateMessage( &msg );
            DispatchMessageA( &msg );
        }
    }
    return 0;
}
