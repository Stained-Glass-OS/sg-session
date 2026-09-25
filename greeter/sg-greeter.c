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
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

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

/* The lock-screen picture (Windows 10's "curtain"): the picture chosen in
 * Settings > Personalization > Lock screen, or the system's own, with the
 * time and date at the bottom left. A key, a click or the wheel lifts it and
 * shows the sign-in pane -- the same picture blurred and dimmed behind the
 * form (ShowOnSignIn), or the plain colour.
 *
 * The picture comes from the environment, never from a path the user names:
 * SG_LOCK_PICTURE is a private copy sg-lockd made after checking the user's
 * published file (owner, type, size); the login screen uses the system's
 * picture (SG_LOCK_DEFAULT_PICTURE, else the stained-glass wallpaper). */
static BOOL g_curtain;
static HBITMAP g_bmp_sharp, g_bmp_blur;   /* screen-sized, 32bpp */
static HBRUSH g_pattern;                  /* g_bmp_blur as a brush, for the statics */
static int g_sw, g_sh;
static HFONT g_font_clock, g_font_date, g_font_avatar;
static char g_clock_text[64];
static HWND g_focus_want;

/* Windows 10's sign-in screen is a flat blue field; matching it is the whole
 * point of this program existing. */
static const COLORREF COL_BG     = RGB(0x1F, 0x4E, 0x79);
static const COLORREF COL_TEXT   = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_ERR    = RGB(0xFF, 0xD1, 0x6A);


/* ---- the picture ------------------------------------------------------- */

/* Decode FILE (a Unix path) with WIC into top-down BGRX pixels. */
static BYTE *load_picture( const char *unix_path, UINT *w, UINT *h )
{
    IWICImagingFactory *factory = NULL;
    IWICBitmapDecoder *dec = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *conv = NULL;
    WCHAR path[MAX_PATH + 16];
    BYTE *bits = NULL;
    int n;

    n = MultiByteToWideChar( CP_UTF8, 0, unix_path, -1, path + 8, MAX_PATH );
    if (n <= 1) return NULL;
    memcpy( path, L"\\\\?\\unix", 8 * sizeof(WCHAR) );
    for (WCHAR *p = path + 8; *p; p++) if (*p == '/') *p = '\\';

    if (FAILED(CoCreateInstance( &CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                                 &IID_IWICImagingFactory, (void **)&factory ))) return NULL;
    if (SUCCEEDED(IWICImagingFactory_CreateDecoderFromFilename( factory, path, NULL, GENERIC_READ,
                                                                WICDecodeMetadataCacheOnDemand, &dec ))
        && SUCCEEDED(IWICBitmapDecoder_GetFrame( dec, 0, &frame ))
        && SUCCEEDED(IWICImagingFactory_CreateFormatConverter( factory, &conv ))
        && SUCCEEDED(IWICFormatConverter_Initialize( conv, (IWICBitmapSource *)frame, &GUID_WICPixelFormat32bppBGR,
                                                     WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom ))
        && SUCCEEDED(IWICFormatConverter_GetSize( conv, w, h ))
        && *w > 0 && *h > 0 && *w <= 16384 && *h <= 16384
        && (bits = malloc( (size_t)*w * *h * 4 )))
    {
        if (FAILED(IWICFormatConverter_CopyPixels( conv, NULL, *w * 4, *w * *h * 4, bits ))) { free( bits ); bits = NULL; }
    }
    if (conv) IWICFormatConverter_Release( conv );
    if (frame) IWICBitmapFrameDecode_Release( frame );
    if (dec) IWICBitmapDecoder_Release( dec );
    IWICImagingFactory_Release( factory );
    return bits;
}

/* Resample SRC (sw x sh) to fill DW x DH, cropping the overflow evenly (the
 * "Fill" wallpaper style): an area average when shrinking, bilinear when
 * growing. dim is 0-256 (256 = unchanged). */
static void resample( const BYTE *src, int sw, int sh, BYTE *dst, int dw, int dh, int dim )
{
    double scale = (double)dw / sw > (double)dh / sh ? (double)dw / sw : (double)dh / sh;
    double ox = (sw * scale - dw) / 2, oy = (sh * scale - dh) / 2;
    for (int y = 0; y < dh; y++)
    {
        double sy0 = (y + oy) / scale, sy1 = (y + 1 + oy) / scale;
        for (int x = 0; x < dw; x++)
        {
            double sx0 = (x + ox) / scale, sx1 = (x + 1 + ox) / scale;
            unsigned acc[3] = { 0, 0, 0 }, cnt = 0;
            BYTE *d = dst + ((size_t)y * dw + x) * 4;
            if (scale < 1.0)
            {
                int ax = (int)sx0, bx = (int)sx1, ay = (int)sy0, by = (int)sy1;
                if (bx <= ax) bx = ax + 1;
                if (by <= ay) by = ay + 1;
                if (bx > sw) bx = sw;
                if (by > sh) by = sh;
                for (int yy = ay; yy < by; yy++)
                    for (int xx = ax; xx < bx; xx++)
                    {
                        const BYTE *s = src + ((size_t)yy * sw + xx) * 4;
                        acc[0] += s[0]; acc[1] += s[1]; acc[2] += s[2]; cnt++;
                    }
                if (!cnt) cnt = 1;
                for (int c = 0; c < 3; c++) d[c] = (BYTE)(acc[c] / cnt * dim / 256);
            }
            else
            {
                double fx = (sx0 + sx1) / 2 - 0.5, fy = (sy0 + sy1) / 2 - 0.5;
                int x0, y0, x1, y1;
                double tx, ty;
                if (fx < 0) fx = 0;
                if (fy < 0) fy = 0;
                x0 = (int)fx; y0 = (int)fy; tx = fx - x0; ty = fy - y0;
                x1 = x0 + 1 < sw ? x0 + 1 : x0; y1 = y0 + 1 < sh ? y0 + 1 : y0;
                if (x0 >= sw) x0 = x1 = sw - 1;
                if (y0 >= sh) y0 = y1 = sh - 1;
                for (int c = 0; c < 3; c++)
                {
                    double a = src[((size_t)y0 * sw + x0) * 4 + c] * (1 - tx) + src[((size_t)y0 * sw + x1) * 4 + c] * tx;
                    double b = src[((size_t)y1 * sw + x0) * 4 + c] * (1 - tx) + src[((size_t)y1 * sw + x1) * 4 + c] * tx;
                    d[c] = (BYTE)((a * (1 - ty) + b * ty) * dim / 256);
                }
            }
            d[3] = 0;
        }
    }
}

static HBITMAP make_dib( int w, int h, BYTE **bits )
{
    BITMAPINFO bi = {{ sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB }};
    return CreateDIBSection( NULL, &bi, DIB_RGB_COLORS, (void **)bits, NULL, 0 );
}

/* Build the sharp and the blurred screens from the picture, if there is one.
 * The blur is the picture shrunk to 1/24 and grown back, dimmed: Windows 10's
 * acrylic sign-in background, near enough, at no cost. */
static void prepare_picture( void )
{
    const char *path = getenv( "SG_LOCK_PICTURE" ), *signin = getenv( "SG_LOCK_SIGNIN" );
    BYTE *src, *sharp, *blur, *tiny;
    UINT w, h;
    int tw = g_sw / 24 > 8 ? g_sw / 24 : 8, th = g_sh / 24 > 8 ? g_sh / 24 : 8;

#ifdef SG_MUTANT_NOPIC
    path = NULL;
#endif
    if (!path || !*path) path = getenv( "SG_LOCK_DEFAULT_PICTURE" );
    if (!path || !*path) path = "/usr/share/stained-glass/wallpapers/stained-glass.jpg";
    if (!(src = load_picture( path, &w, &h ))) return;
    if ((g_bmp_sharp = make_dib( g_sw, g_sh, &sharp ))) resample( src, w, h, sharp, g_sw, g_sh, 256 );
    if (!(signin && !strcmp( signin, "0" )) && (tiny = malloc( (size_t)tw * th * 4 )))
    {
        resample( src, w, h, tiny, tw, th, 150 );
        if ((g_bmp_blur = make_dib( g_sw, g_sh, &blur ))) resample( tiny, tw, th, blur, g_sw, g_sh, 256 );
        free( tiny );
        if (g_bmp_blur) g_pattern = CreatePatternBrush( g_bmp_blur );
    }
    free( src );
}

static void format_clock( char *time_text, int tcch, char *date_text, int dcch )
{
    SYSTEMTIME st;
    GetLocalTime( &st );
    if (!GetTimeFormatA( LOCALE_USER_DEFAULT, TIME_NOSECONDS | TIME_NOTIMEMARKER, &st, NULL, time_text, tcch ))
        snprintf( time_text, tcch, "%d:%02d", st.wHour, st.wMinute );
    if (!GetDateFormatA( LOCALE_USER_DEFAULT, 0, &st, "dddd, MMMM d", date_text, dcch ))
        snprintf( date_text, dcch, "%04d-%02d-%02d", st.wYear, st.wMonth, st.wDay );
}

static void shadow_text( HDC dc, int x, int y, const char *text )
{
    SetTextColor( dc, RGB(0x20, 0x20, 0x20) );
    TextOutA( dc, x + 2, y + 2, text, (int)strlen( text ) );
    SetTextColor( dc, COL_TEXT );
    TextOutA( dc, x, y, text, (int)strlen( text ) );
}

static void paint( HWND hwnd )
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint( hwnd, &ps ), mem = CreateCompatibleDC( dc ), pic = CreateCompatibleDC( dc );
    HBITMAP buf = CreateCompatibleBitmap( dc, g_sw, g_sh ), oldbuf = SelectObject( mem, buf );
    HBITMAP back = g_curtain ? g_bmp_sharp : g_bmp_blur;

    if (back)
    {
        HGDIOBJ old = SelectObject( pic, back );
        BitBlt( mem, 0, 0, g_sw, g_sh, pic, 0, 0, SRCCOPY );
        SelectObject( pic, old );
    }
    else FillRect( mem, &(RECT){ 0, 0, g_sw, g_sh }, g_bg );

    SetBkMode( mem, TRANSPARENT );
    if (g_curtain)
    {
        char date[128];
        int m = g_sh / 16;
        format_clock( g_clock_text, sizeof(g_clock_text), date, sizeof(date) );
        SelectObject( mem, g_font_clock );
        shadow_text( mem, m, g_sh - m - g_sh * 22 / 100, g_clock_text );
        SelectObject( mem, g_font_date );
        shadow_text( mem, m + 4, g_sh - m - g_sh * 7 / 100, date );
    }
    else if (g_lock_user)
    {
        /* The account picture: a circle with the user's initial. */
        int r = g_sh / 13, cx = g_sw / 2, cy = g_sh / 2 - 60 - 130 - r - 16;
        char initial[2] = { (char)toupper( (unsigned char)g_lock_user[0] ), 0 };
        HBRUSH b = CreateSolidBrush( RGB(0x7B, 0x2F, 0xBE) );
        HGDIOBJ ob = SelectObject( mem, b ), op = SelectObject( mem, GetStockObject( NULL_PEN ) );
        SIZE sz;
        if (cy - r > 8)
        {
            Ellipse( mem, cx - r, cy - r, cx + r, cy + r );
            SelectObject( mem, g_font_avatar );
            GetTextExtentPoint32A( mem, initial, 1, &sz );
            SetTextColor( mem, COL_TEXT );
            TextOutA( mem, cx - sz.cx / 2, cy - sz.cy / 2, initial, 1 );
        }
        SelectObject( mem, ob ); SelectObject( mem, op );
        DeleteObject( b );
    }
    BitBlt( dc, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right - ps.rcPaint.left,
            ps.rcPaint.bottom - ps.rcPaint.top, mem, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY );
    SelectObject( mem, oldbuf );
    DeleteObject( buf );
    DeleteDC( pic ); DeleteDC( mem );
    EndPaint( hwnd, &ps );
}

static void show_form( HWND hwnd, BOOL show )
{
    for (HWND c = GetWindow( hwnd, GW_CHILD ); c; c = GetWindow( c, GW_HWNDNEXT ))
    {
        /* The password box appears only once the service asks for it. */
        if (c == g_secret && !g_awaiting_secret) continue;
        ShowWindow( c, show ? SW_SHOWNA : SW_HIDE );
    }
}

/* Lift the curtain: the sign-in pane, with the focus where it belongs. */
static void lift_curtain( HWND hwnd )
{
    if (!g_curtain) return;
    g_curtain = FALSE;
    show_form( hwnd, TRUE );
    InvalidateRect( hwnd, NULL, TRUE );
    SetFocus( g_focus_want ? g_focus_want : g_user );
    UpdateWindow( hwnd );
}

/* SetFocus, or remember it for when the curtain lifts. */
static void want_focus( HWND c )
{
    g_focus_want = c;
    if (!g_curtain) SetFocus( c );
}

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
        if (!g_curtain) ShowWindow( g_secret, SW_SHOW );
        EnableWindow( g_submit, TRUE );
        want_focus( g_secret );
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
            want_focus( g_user );
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
         * looks like a font bug and is really a painting one. Over a picture
         * the brush is the blurred picture itself, aligned to where the
         * control sits, so the erase is still real. */
        SetTextColor( dc, GetWindowLongPtrA( (HWND)lp, GWLP_USERDATA ) ? COL_ERR : COL_TEXT );
        if (g_pattern)
        {
            POINT o = { 0, 0 };
            MapWindowPoints( (HWND)lp, hwnd, &o, 1 );
            SetBrushOrgEx( dc, -o.x, -o.y, NULL );
            SetBkMode( dc, TRANSPARENT );
            return (LRESULT)g_pattern;
        }
        SetBkColor( dc, COL_BG );
        return (LRESULT)g_bg;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        paint( hwnd );
        return 0;
    case WM_TIMER:
        if (g_curtain)
        {
            char t[64], d[128];
            format_clock( t, sizeof(t), d, sizeof(d) );
            if (strcmp( t, g_clock_text )) InvalidateRect( hwnd, NULL, FALSE );
        }
        return 0;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MOUSEWHEEL:
        lift_curtain( hwnd );
        return 0;
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
    const char *curtain = getenv( "SG_GREETER_CURTAIN" );

    (void)prev; (void)show;
    CoInitializeEx( NULL, COINIT_APARTMENTTHREADED );
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

    sw = g_sw = GetSystemMetrics( SM_CXSCREEN );
    sh = g_sh = GetSystemMetrics( SM_CYSCREEN );
    g_font_clock  = make_font( sh * 16 / 100, FW_LIGHT );
    g_font_date   = make_font( sh * 6 / 100, FW_LIGHT );
    g_font_avatar = make_font( sh / 13, FW_LIGHT );
    prepare_picture();
    g_curtain = !(curtain && !strcmp( curtain, "0" ));

    /* Fills the desktop: this is the login screen, not a dialog on top of
     * something. WS_POPUP so it carries no caption or border. */
    hwnd = CreateWindowExA( 0, "SgGreeter", "Sign in", WS_POPUP | WS_CLIPCHILDREN,
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
    if (g_curtain) show_form( hwnd, FALSE );
    ShowWindow( hwnd, SW_SHOW );
    UpdateWindow( hwnd );
    SetTimer( hwnd, 1, 1000, NULL );
    want_focus( g_user );
    if (g_curtain) SetFocus( hwnd );
    CloseHandle( CreateThread( NULL, 0, reader_thread, hwnd, 0, NULL ) );
    send_line( "HELLO" );

    while (GetMessageA( &msg, NULL, 0, 0 ))
    {
        /* A key lifts the curtain, and -- unlike Enter or Escape, which only
         * lift it -- goes on to the box that now has the focus, so a person
         * (or remote-support tool) who just starts typing loses nothing. */
        if (g_curtain && (msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN))
        {
            WPARAM k = msg.wParam;
            lift_curtain( hwnd );
            if (k == VK_RETURN || k == VK_ESCAPE || k == VK_SPACE || k == VK_SHIFT || k == VK_CONTROL
                || k == VK_MENU || k == VK_LWIN || k == VK_RWIN || !GetFocus()) continue;
            msg.hwnd = GetFocus();
        }
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_RETURN) { submit(); continue; }
        if (!IsDialogMessageA( hwnd, &msg ))
        {
            TranslateMessage( &msg );
            DispatchMessageA( &msg );
        }
    }
    return 0;
}
