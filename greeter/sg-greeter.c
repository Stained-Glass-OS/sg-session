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
/* Lock mode ("/lock <user>"): the session's user is fixed -- the lock service
 * got it from the kernel -- so the screen only asks for the password. */
static const char *g_lock_user;

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
    if (!g_awaiting_secret && g_lock_user) return;   /* waiting for the prompt */
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

/* One line from the bridge, on the UI thread. */
static void handle_bridge_line( HWND hwnd, char *line )
{
    if (!strncmp( line, "PROMPT_SECRET ", 14 ) || !strncmp( line, "PROMPT_VISIBLE ", 15 ))
    {
        const char *text = line + (line[7] == 'S' ? 14 : 15);
        g_awaiting_secret = TRUE;
        SetWindowTextA( g_prompt, text );
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
        /* At the lock screen the user is fixed and the service re-prompts;
         * at the login screen, start over from the user name. */
        g_awaiting_secret = FALSE;
        SetWindowTextA( g_secret, "" );
        if (!g_lock_user)
        {
            SetWindowTextA( g_prompt, "" );
            ShowWindow( g_secret, SW_HIDE );
            SetFocus( g_user );
        }
        EnableWindow( g_submit, TRUE );
        set_status( line + 8, TRUE );
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

#define WM_BRIDGE_LINE (WM_APP + 1)
#define WM_BRIDGE_EOF  (WM_APP + 2)

/* Reads the bridge on its own thread and posts each line to the window.
 *
 * Blocking reads, not polling: the first version polled with PeekNamedPipe
 * from a timer, and PeekNamedPipe fails with ERROR_NOT_SUPPORTED on a Unix
 * pipe inherited through Wine -- which is exactly what the bridge hands us --
 * so it never read a byte. A gate that stood a shell script in for this
 * program could not see that. A reader thread works with any handle, and the
 * UI thread still never blocks on I/O. */
static DWORD WINAPI reader_thread( void *arg )
{
    HWND hwnd = arg;
    char line[1024];

    while (read_line( line, sizeof(line) ))
    {
        char *copy = _strdup( line );
        SecureZeroMemory( line, sizeof(line) );
        if (copy) PostMessageA( hwnd, WM_BRIDGE_LINE, 0, (LPARAM)copy );
    }
    PostMessageA( hwnd, WM_BRIDGE_EOF, 0, 0 );
    return 0;
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
    case WM_BRIDGE_LINE:
    {
        char *line = (char *)lp;
        handle_bridge_line( hwnd, line );
        SecureZeroMemory( line, strlen( line ) );
        free( line );
        return 0;
    }
    case WM_BRIDGE_EOF:
        /* The bridge is gone; there is no one to authenticate with. */
        PostMessage( hwnd, WM_CLOSE, 0, 0 );
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

    (void)prev; (void)show;
    if (cmdline && !strncmp( cmdline, "/lock ", 6 ) && cmdline[6]) g_lock_user = cmdline + 6;
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

    g_title = CreateWindowExA( 0, "STATIC", g_lock_user ? "Locked" : "Stained Glass OS",
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

    if (g_lock_user)
    {
        SetWindowTextA( g_user, g_lock_user );
        EnableWindow( g_user, FALSE );
    }
    SetFocus( g_user );
    CloseHandle( CreateThread( NULL, 0, reader_thread, hwnd, 0, NULL ) );
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
