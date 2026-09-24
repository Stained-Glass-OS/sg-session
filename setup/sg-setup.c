/* Stained Glass Setup: the installation wizard.
 *
 * On a live boot (the installation media's "live" entry) this takes the
 * login screen's place. It is a Windows program for the same reason the login
 * screen is: remote-support tools can see and drive it. It decides nothing.
 * sg-setup-bridge passes what it asks for to sg-installd, the root service
 * that runs sg-install; both check every request again.
 *
 * Pages: Welcome -> Disk -> Account -> Ready -> Installing -> Done (or
 * Failed). Protocol, line-based, on the pipes it was started with:
 *
 *   -> HELLO                         the window is up
 *   -> LIST                          <- DISK <path>\t<bytes>\t<model> ... END
 *   -> INSTALL <disk>\t<account>\t<hostname>\t<full name>
 *   -> PASSWORD <password>           starts the installation
 *   <- PROGRESS <percent> <text>     <- DONE | FAILED <text>
 *   -> REBOOT | POWEROFF
 *
 * Keys: Tab moves; Enter presses the focused button, or in a field the page's
 * main button; Escape goes back. Enter and Escape act on release, and only for
 * a press seen on the same page, so a key held down on one page cannot answer
 * the next one -- the next one may be "erase this disk". The gate drives the
 * whole wizard from the keyboard, as remote support would.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum page { P_WELCOME, P_DISK, P_ACCOUNT, P_READY, P_INSTALLING, P_DONE, P_FAILED };

#define ID_NEXT    301
#define ID_BACK    302
#define ID_LEFT    303
#define ID_DISKS   304
#define ID_NAME    305
#define ID_ACCOUNT 306
#define ID_PASS    307
#define ID_PASS2   308
#define ID_HOST    309

#define PANEL_W 760
#define PANEL_H 520
#define BANNER_H 56
#define MAX_DISKS 32

#define WM_BRIDGE_LINE (WM_APP + 1)
#define WM_BRIDGE_EOF  (WM_APP + 2)

static const COLORREF COL_BG     = RGB(0x1E, 0x10, 0x2E);
static const COLORREF COL_PANEL  = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_ACCENT = RGB(0x7B, 0x2F, 0xBE);
static const COLORREF COL_TEXT   = RGB(0x1A, 0x1A, 0x1A);
static const COLORREF COL_SUBTLE = RGB(0x5A, 0x5A, 0x5A);
static const COLORREF COL_ERR    = RGB(0xC4, 0x2B, 0x1C);
static const COLORREF COL_TRACK  = RGB(0xE6, 0xE0, 0xEE);

static HANDLE g_in, g_out;
static HWND g_main, g_next, g_back, g_left, g_disks, g_name, g_account, g_pass, g_pass2, g_host;
static HWND g_lbl_disks, g_lbl_name, g_lbl_account, g_lbl_pass, g_lbl_pass2, g_lbl_host;
static HFONT g_font_title, g_font_head, g_font, g_font_bold;
static HBRUSH g_bg, g_panel;
static RECT g_rc;               /* the panel, in client coordinates */
static enum page g_page = P_WELCOME;
static WPARAM g_armed;          /* Enter or Escape, pressed on this page */
static BOOL g_listing;

static struct { char path[64]; unsigned long long bytes; char model[64]; } g_disk[MAX_DISKS];
static int g_ndisks, g_chosen = -1;
static char g_heading[128], g_body[512], g_status[256];
static BOOL g_status_err;
static int g_percent;

static void send_line( const char *fmt, ... )
{
    char buf[1024];
    va_list ap;
    DWORD written;
    int n;

    va_start( ap, fmt );
    n = vsnprintf( buf, sizeof(buf) - 1, fmt, ap );
    va_end( ap );
    if (n < 0 || n > (int)sizeof(buf) - 2) n = sizeof(buf) - 2;
    buf[n++] = '\n';
    WriteFile( g_out, buf, n, &written, NULL );
    SecureZeroMemory( buf, sizeof(buf) );
}

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

/* Blocking reads on a thread: PeekNamedPipe does not work on a Unix pipe
 * inherited through Wine (see sg-greeter.c). */
static DWORD WINAPI reader_thread( void *arg )
{
    char line[1024];

    while (read_line( line, sizeof(line) ))
    {
        char *copy = _strdup( line );
        if (copy) PostMessageA( (HWND)arg, WM_BRIDGE_LINE, 0, (LPARAM)copy );
    }
    PostMessageA( (HWND)arg, WM_BRIDGE_EOF, 0, 0 );
    return 0;
}

static void size_text( unsigned long long bytes, char *out, size_t len )
{
    double gb = (double)bytes / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 1024.0) snprintf( out, len, "%.1f TB", gb / 1024.0 );
    else snprintf( out, len, "%.1f GB", gb );
}

static void set_status( const char *text, BOOL err )
{
    snprintf( g_status, sizeof(g_status), "%s", text );
    g_status_err = err;
    InvalidateRect( g_main, NULL, FALSE );
}

static void show( HWND w, BOOL on ) { ShowWindow( w, on ? SW_SHOW : SW_HIDE ); }

/* Each page change goes to stderr, which reaches the journal: where Setup got
 * to, for whoever is supporting the machine, and a signal the gate waits on. */
static void log_page( enum page p )
{
    static const char *const names[] = { "welcome", "disk", "account", "ready", "installing", "done", "failed" };
    char buf[64];
    DWORD written;
    int n = snprintf( buf, sizeof(buf), "sg-setup: page %s\n", names[p] );
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), buf, n, &written, NULL );
}

static void set_page( enum page p )
{
    BOOL disk = p == P_DISK, acct = p == P_ACCOUNT;
    char size[32];

    g_page = p;
    g_armed = 0;
    log_page( p );
    g_status[0] = 0;
    g_status_err = FALSE;

    show( g_lbl_disks, disk ); show( g_disks, disk );
    show( g_lbl_name, acct ); show( g_name, acct );
    show( g_lbl_account, acct ); show( g_account, acct );
    show( g_lbl_pass, acct ); show( g_pass, acct );
    show( g_lbl_pass2, acct ); show( g_pass2, acct );
    show( g_lbl_host, acct ); show( g_host, acct );
    show( g_back, p == P_DISK || p == P_ACCOUNT || p == P_READY );
    show( g_left, p == P_WELCOME || p == P_FAILED );
    show( g_next, p != P_INSTALLING );
    EnableWindow( g_next, TRUE );

    switch (p)
    {
    case P_WELCOME:
        strcpy( g_heading, "Install Stained Glass OS" );
        strcpy( g_body, "Setup copies Stained Glass from this installation media onto a disk in this PC "
                "and makes you its administrator. It takes a few minutes." );
        SetWindowTextA( g_next, "&Install now" );
        SetWindowTextA( g_left, "&Shut down" );
        SetFocus( g_next );
        break;
    case P_DISK:
        strcpy( g_heading, "Where do you want to install Stained Glass?" );
        strcpy( g_body, "Everything on the disk you choose will be erased." );
        SetWindowTextA( g_next, "&Next" );
        SendMessageA( g_disks, LB_RESETCONTENT, 0, 0 );
        EnableWindow( g_next, FALSE );
        g_ndisks = 0;
        g_listing = TRUE;
        set_status( "Looking for disks...", FALSE );
        send_line( "LIST" );
        SetFocus( g_disks );
        break;
    case P_ACCOUNT:
        strcpy( g_heading, "Who's going to use this PC?" );
        strcpy( g_body, "This account will be the PC's administrator." );
        SetWindowTextA( g_next, "&Next" );
        SetFocus( g_name );
        break;
    case P_READY:
        size_text( g_disk[g_chosen].bytes, size, sizeof(size) );
        strcpy( g_heading, "Ready to install" );
        snprintf( g_body, sizeof(g_body),
                  "Stained Glass will be installed on %s (%s, %s).\n\n"
                  "EVERYTHING ON THIS DISK WILL BE ERASED.",
                  g_disk[g_chosen].path, g_disk[g_chosen].model, size );
        SetWindowTextA( g_next, "&Install" );
        /* Focus on Back: the destructive button is never the one a stray key
         * lands on. */
        SetFocus( g_back );
        break;
    case P_INSTALLING:
        strcpy( g_heading, "Installing Stained Glass" );
        strcpy( g_body, "Your PC will be ready soon. Do not turn it off." );
        g_percent = 0;
        SetFocus( g_main );
        break;
    case P_DONE:
        strcpy( g_heading, "Stained Glass is installed" );
        strcpy( g_body, "Remove the installation media, then restart. You will sign in with the "
                "account you just created." );
        SetWindowTextA( g_next, "&Restart now" );
        SetFocus( g_next );
        break;
    case P_FAILED:
        strcpy( g_heading, "Stained Glass could not be installed" );
        SetWindowTextA( g_next, "&Start over" );
        SetWindowTextA( g_left, "&Shut down" );
        SetFocus( g_next );
        break;
    }
    InvalidateRect( g_main, NULL, TRUE );
}

static BOOL valid_account( const char *s )
{
    size_t i, n = strlen( s );
    if (!n || n > 32) return FALSE;
    if (!((s[0] >= 'a' && s[0] <= 'z') || s[0] == '_')) return FALSE;
    for (i = 1; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '_' || s[i] == '-'))
            return FALSE;
    return strcmp( s, "root" ) && strcmp( s, "sgsystem" ) && strcmp( s, "nobody" ) &&
           strcmp( s, "daemon" ) && strcmp( s, "sguser" );
}

static BOOL valid_host( const char *s )
{
    size_t i, n = strlen( s );
    if (!n || n > 63 || s[0] == '-' || s[n - 1] == '-') return FALSE;
    for (i = 0; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z') ||
              (s[i] >= '0' && s[i] <= '9') || s[i] == '-'))
            return FALSE;
    return TRUE;
}

/* The account name from the full name when it is left empty: the first word,
 * lower case, letters and digits only. */
static void derive_account( const char *name, char *out, size_t len )
{
    size_t o = 0;
    for (; *name == ' '; name++) ;
    for (; *name && *name != ' ' && o < len - 1; name++)
    {
        char c = *name;
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) out[o++] = c;
    }
    out[o] = 0;
}

static BOOL account_page_done( void )
{
    char name[128], account[64], pass[256], pass2[256], host[64];

    GetWindowTextA( g_name, name, sizeof(name) );
    GetWindowTextA( g_account, account, sizeof(account) );
    GetWindowTextA( g_host, host, sizeof(host) );
    if (!account[0])
    {
        derive_account( name, account, sizeof(account) );
        SetWindowTextA( g_account, account );
    }
    if (strchr( name, '\t' )) { set_status( "The name cannot contain a tab.", TRUE ); return FALSE; }
    if (!valid_account( account ))
    {
        set_status( "The account name must start with a letter and use only a-z, 0-9, - and _.", TRUE );
        SetFocus( g_account );
        return FALSE;
    }
    if (!valid_host( host ))
    {
        set_status( "The PC name may use only letters, digits and -, and not start or end with -.", TRUE );
        SetFocus( g_host );
        return FALSE;
    }
    GetWindowTextA( g_pass, pass, sizeof(pass) );
    GetWindowTextA( g_pass2, pass2, sizeof(pass2) );
    if (!pass[0] || strcmp( pass, pass2 ))
    {
        set_status( pass[0] ? "The passwords do not match." : "Choose a password.", TRUE );
        SetWindowTextA( g_pass2, "" );
        SetFocus( pass[0] ? g_pass2 : g_pass );
        SecureZeroMemory( pass, sizeof(pass) );
        SecureZeroMemory( pass2, sizeof(pass2) );
        return FALSE;
    }
    SecureZeroMemory( pass, sizeof(pass) );
    SecureZeroMemory( pass2, sizeof(pass2) );
    return TRUE;
}

static void start_install( void )
{
    char name[128], account[64], pass[256], host[64];

    GetWindowTextA( g_name, name, sizeof(name) );
    GetWindowTextA( g_account, account, sizeof(account) );
    GetWindowTextA( g_host, host, sizeof(host) );
    GetWindowTextA( g_pass, pass, sizeof(pass) );
    set_page( P_INSTALLING );
    set_status( "Starting...", FALSE );
    send_line( "INSTALL %s\t%s\t%s\t%s", g_disk[g_chosen].path, account, host, name );
    send_line( "PASSWORD %s", pass );
    /* Not kept here, and not in the controls either. */
    SecureZeroMemory( pass, sizeof(pass) );
    SetWindowTextA( g_pass, "" );
    SetWindowTextA( g_pass2, "" );
}

static void go_next( void )
{
    switch (g_page)
    {
    case P_WELCOME: set_page( P_DISK ); break;
    case P_DISK:
    {
        LRESULT sel = SendMessageA( g_disks, LB_GETCURSEL, 0, 0 );
        if (g_listing || sel == LB_ERR || sel >= g_ndisks) return;
        g_chosen = (int)sel;
        set_page( P_ACCOUNT );
        break;
    }
    case P_ACCOUNT: if (account_page_done()) set_page( P_READY ); break;
    case P_READY: start_install(); break;
    case P_INSTALLING: break;
    case P_DONE: set_status( "Restarting...", FALSE ); EnableWindow( g_next, FALSE ); send_line( "REBOOT" ); break;
    case P_FAILED: set_page( P_WELCOME ); break;
    }
}

static void go_back( void )
{
    switch (g_page)
    {
    case P_DISK: set_page( P_WELCOME ); break;
    case P_ACCOUNT: set_page( P_DISK ); break;
    case P_READY: set_page( P_ACCOUNT ); break;
    default: break;
    }
}

static void shut_down( void )
{
    set_status( "Shutting down...", FALSE );
    EnableWindow( g_left, FALSE );
    send_line( "POWEROFF" );
}

static void handle_line( char *line )
{
    if (!strncmp( line, "DISK ", 5 ) && g_listing && g_ndisks < MAX_DISKS)
    {
        char *path = line + 5, *bytes = strchr( path, '\t' ), *model = NULL, entry[192], size[32];
        if (!bytes) return;
        *bytes++ = 0;
        if ((model = strchr( bytes, '\t' ))) *model++ = 0;
        snprintf( g_disk[g_ndisks].path, sizeof(g_disk[0].path), "%s", path );
        g_disk[g_ndisks].bytes = _strtoui64( bytes, NULL, 10 );
        snprintf( g_disk[g_ndisks].model, sizeof(g_disk[0].model), "%s", model && *model ? model : "Disk" );
        size_text( g_disk[g_ndisks].bytes, size, sizeof(size) );
        snprintf( entry, sizeof(entry), "%s    %s    %s", g_disk[g_ndisks].path, size, g_disk[g_ndisks].model );
        SendMessageA( g_disks, LB_ADDSTRING, 0, (LPARAM)entry );
        g_ndisks++;
    }
    else if (!strcmp( line, "END" ) && g_listing)
    {
        g_listing = FALSE;
        if (g_ndisks)
        {
            SendMessageA( g_disks, LB_SETCURSEL, 0, 0 );
            EnableWindow( g_next, TRUE );
            set_status( "", FALSE );
        }
        else set_status( "No disk of at least 16 GB was found. Connect one, then go back and try again.", TRUE );
    }
    else if (!strncmp( line, "PROGRESS ", 9 ) && g_page == P_INSTALLING)
    {
        char *text = strchr( line + 9, ' ' );
        g_percent = atoi( line + 9 );
        if (g_percent < 0) g_percent = 0;
        if (g_percent > 100) g_percent = 100;
        set_status( text ? text + 1 : "", FALSE );
    }
    else if (!strcmp( line, "DONE" ) && g_page == P_INSTALLING)
    {
        set_page( P_DONE );
    }
    else if (!strncmp( line, "FAILED ", 7 ))
    {
        g_listing = FALSE;
        set_page( P_FAILED );
        snprintf( g_body, sizeof(g_body), "%s", line + 7 );
        InvalidateRect( g_main, NULL, TRUE );
    }
}

static void paint( HWND hwnd )
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint( hwnd, &ps );
    RECT r, client;
    HBRUSH br;
    int x = g_rc.left + 40, w = PANEL_W - 80;

    GetClientRect( hwnd, &client );
    FillRect( dc, &client, g_bg );
    FillRect( dc, &g_rc, g_panel );
    r = g_rc; r.bottom = r.top + BANNER_H;
    br = CreateSolidBrush( COL_ACCENT ); FillRect( dc, &r, br ); DeleteObject( br );

    SetBkMode( dc, TRANSPARENT );
    SelectObject( dc, g_font_title );
    SetTextColor( dc, RGB(0xFF, 0xFF, 0xFF) );
    r.left += 24;
    DrawTextA( dc, "Stained Glass Setup", -1, &r, DT_SINGLELINE | DT_VCENTER | DT_LEFT );

    SelectObject( dc, g_font_head );
    SetTextColor( dc, COL_TEXT );
    SetRect( &r, x, g_rc.top + BANNER_H + 28, x + w, g_rc.top + BANNER_H + 72 );
    DrawTextA( dc, g_heading, -1, &r, DT_SINGLELINE | DT_LEFT | DT_END_ELLIPSIS );

    SelectObject( dc, g_page == P_READY ? g_font_bold : g_font );
    SetTextColor( dc, g_page == P_FAILED ? COL_ERR : COL_SUBTLE );
    SetRect( &r, x, g_rc.top + BANNER_H + 80, x + w, g_rc.top + BANNER_H + 170 );
    DrawTextA( dc, g_body, -1, &r, DT_WORDBREAK | DT_LEFT );

    if (g_page == P_INSTALLING)
    {
        RECT track = { x, g_rc.top + 260, x + w, g_rc.top + 272 }, fill = track;
        br = CreateSolidBrush( COL_TRACK ); FillRect( dc, &track, br ); DeleteObject( br );
        fill.right = fill.left + (w * g_percent) / 100;
        br = CreateSolidBrush( COL_ACCENT ); FillRect( dc, &fill, br ); DeleteObject( br );
    }

    SelectObject( dc, g_font );
    SetTextColor( dc, g_status_err ? COL_ERR : COL_SUBTLE );
    SetRect( &r, x, g_rc.bottom - 110, x + w, g_rc.bottom - 66 );
    if (g_page == P_INSTALLING) SetRect( &r, x, g_rc.top + 284, x + w, g_rc.top + 330 );
    DrawTextA( dc, g_status, -1, &r, DT_WORDBREAK | DT_LEFT );
    EndPaint( hwnd, &ps );
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_PAINT: paint( hwnd ); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_CTLCOLORSTATIC:
        SetBkColor( (HDC)wp, COL_PANEL );
        SetTextColor( (HDC)wp, COL_TEXT );
        return (LRESULT)g_panel;
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case ID_NEXT: go_next(); break;
        case ID_BACK: go_back(); break;
        case ID_LEFT: if (g_page == P_WELCOME || g_page == P_FAILED) shut_down(); break;
        case ID_DISKS: if (HIWORD(wp) == LBN_DBLCLK) go_next(); break;
        }
        return 0;
    case WM_BRIDGE_LINE:
        handle_line( (char *)lp );
        SecureZeroMemory( (char *)lp, strlen( (char *)lp ) );
        free( (char *)lp );
        return 0;
    case WM_BRIDGE_EOF:
        if (g_page == P_INSTALLING)
        {
            set_page( P_FAILED );
            strcpy( g_body, "Setup lost contact with the installer service." );
        }
        else PostMessageA( hwnd, WM_CLOSE, 0, 0 );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static HFONT make_font( int height, int weight )
{
    return CreateFontA( height, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI" );
}

static HWND child( const char *cls, const char *text, DWORD style, DWORD ex, int x, int y, int w, int h, int id )
{
    HWND c = CreateWindowExA( ex, cls, text, WS_CHILD | style, g_rc.left + x, g_rc.top + y, w, h,
                              g_main, (HMENU)(INT_PTR)id, GetModuleHandleA( NULL ), NULL );
    SendMessageA( c, WM_SETFONT, (WPARAM)g_font, TRUE );
    return c;
}

/* Enter and Escape: act on release, for a press seen on this page. */
static BOOL handle_key( MSG *m )
{
    HWND focus;

    if (m->wParam != VK_RETURN && m->wParam != VK_ESCAPE) return FALSE;
    if (m->message == WM_KEYDOWN || m->message == WM_SYSKEYDOWN)
    {
        if (!(m->lParam & (1 << 30))) g_armed = m->wParam;   /* not auto-repeat */
        return TRUE;
    }
    if (m->message != WM_KEYUP && m->message != WM_SYSKEYUP) return FALSE;
    if (g_armed != m->wParam) return TRUE;
    g_armed = 0;
    if (m->wParam == VK_ESCAPE) { go_back(); return TRUE; }
    focus = GetFocus();
    if (focus == g_back) go_back();
    else if (focus == g_left) { if (IsWindowVisible( g_left )) shut_down(); }
    else if (IsWindowVisible( g_next ) && IsWindowEnabled( g_next )) go_next();
    return TRUE;
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show_cmd )
{
    WNDCLASSA wc = {0};
    MSG msg;
    int sw, sh, fx = 40, fw = 330, fx2 = 400;

    (void)prev; (void)cmdline; (void)show_cmd;
    g_in  = GetStdHandle( STD_INPUT_HANDLE );
    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    g_font_title = make_font( 22, FW_SEMIBOLD );
    g_font_head  = make_font( 30, FW_LIGHT );
    g_font       = make_font( 18, FW_NORMAL );
    g_font_bold  = make_font( 18, FW_BOLD );
    g_bg    = CreateSolidBrush( COL_BG );
    g_panel = CreateSolidBrush( COL_PANEL );

    wc.lpfnWndProc   = wndproc;
    wc.hInstance     = inst;
    wc.hCursor       = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.lpszClassName = "SgSetup";
    RegisterClassA( &wc );

    sw = GetSystemMetrics( SM_CXSCREEN );
    sh = GetSystemMetrics( SM_CYSCREEN );
    SetRect( &g_rc, (sw - PANEL_W) / 2, (sh - PANEL_H) / 2, (sw + PANEL_W) / 2, (sh + PANEL_H) / 2 );
    if (g_rc.top < 0) OffsetRect( &g_rc, 0, -g_rc.top );
    if (g_rc.left < 0) OffsetRect( &g_rc, -g_rc.left, 0 );

    g_main = CreateWindowExA( 0, "SgSetup", "Stained Glass Setup", WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN,
                              0, 0, sw, sh, NULL, NULL, inst, NULL );

    /* Creation order is tab order. */
    g_lbl_disks = child( "STATIC", "Disks in this PC", 0, 0, fx, 230, 500, 22, 0 );
    g_disks = child( "LISTBOX", "", WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT,
                     WS_EX_CLIENTEDGE, fx, 256, PANEL_W - 80, 150, ID_DISKS );
    g_lbl_name = child( "STATIC", "Your name", 0, 0, fx, 200, fw, 22, 0 );
    g_name = child( "EDIT", "", WS_TABSTOP | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, fx, 224, fw, 30, ID_NAME );
    g_lbl_account = child( "STATIC", "Account name", 0, 0, fx2, 200, fw, 22, 0 );
    g_account = child( "EDIT", "", WS_TABSTOP | ES_AUTOHSCROLL | ES_LOWERCASE, WS_EX_CLIENTEDGE,
                       fx2, 224, fw, 30, ID_ACCOUNT );
    g_lbl_pass = child( "STATIC", "Password", 0, 0, fx, 266, fw, 22, 0 );
    g_pass = child( "EDIT", "", WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE,
                    fx, 290, fw, 30, ID_PASS );
    g_lbl_pass2 = child( "STATIC", "Confirm password", 0, 0, fx2, 266, fw, 22, 0 );
    g_pass2 = child( "EDIT", "", WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE,
                     fx2, 290, fw, 30, ID_PASS2 );
    g_lbl_host = child( "STATIC", "PC name", 0, 0, fx, 332, fw, 22, 0 );
    g_host = child( "EDIT", "stained-glass", WS_TABSTOP | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE,
                    fx, 356, fw, 30, ID_HOST );
    g_left = child( "BUTTON", "", WS_TABSTOP | BS_PUSHBUTTON, 0, 40, PANEL_H - 58, 130, 36, ID_LEFT );
    g_back = child( "BUTTON", "&Back", WS_TABSTOP | BS_PUSHBUTTON, 0, PANEL_W - 300, PANEL_H - 58, 120, 36, ID_BACK );
    g_next = child( "BUTTON", "", WS_TABSTOP | BS_PUSHBUTTON, 0, PANEL_W - 160, PANEL_H - 58, 120, 36, ID_NEXT );

    set_page( P_WELCOME );
    CloseHandle( CreateThread( NULL, 0, reader_thread, g_main, 0, NULL ) );
    send_line( "HELLO" );

    while (GetMessageA( &msg, NULL, 0, 0 ))
    {
        if (msg.message >= WM_KEYFIRST && msg.message <= WM_KEYLAST && handle_key( &msg )) continue;
        if (!IsDialogMessageA( g_main, &msg ))
        {
            TranslateMessage( &msg );
            DispatchMessageA( &msg );
        }
    }
    return 0;
}
