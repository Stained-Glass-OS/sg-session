/* The elevation consent prompt (the permission prompt), ADR 0012.
 *
 * Runs on the compositor's secure surface: its own X server on the privileged
 * socket, while the compositor shows and sends input to nothing else (SECURE
 * mode). Programs in the user's session can neither see it, click it, nor type
 * into it. sg-brokerd starts it (through sg-consent-ui) and decides; this
 * program only asks.
 *
 *   sg-consent.exe /consent admin <requester> <program...>
 *       An administrator asked: Yes / No.
 *   sg-consent.exe /consent cred <requester> <program...>
 *       A standard user asked: an administrator's name and password.
 *   sg-consent.exe /consent shadow <requester> view|control
 *       Over Remote Desktop, <requester> (an administrator) asks to see --
 *       or see and control -- this session, which stays at the console
 *       (console shadow, E1 pattern A): Yes / No, answered by the person at
 *       the console.
 *
 * Protocol on the pipes it was started with, line-based:
 *
 *   -> ALLOW                      (admin mode) Yes
 *   -> CRED <user>\t<password>    (cred mode) credentials to check
 *   -> DENY                       No, Escape, or closed
 *   <- FAILURE <text>             (cred mode) rejected; ask again
 *   <- DONE                       finished; exit
 *
 * Keys: Escape denies; Enter presses the focused button (No, to start with, in
 * the Yes/No prompt) or, in a text field, submits; Tab, Left and Right move;
 * Alt+Y and Alt+N are the buttons' mnemonics. There is deliberately no bare-
 * letter shortcut: a stray key must never answer an elevation prompt. The keys
 * matter beyond convenience -- remote support drives this prompt with the
 * privileged virtual keyboard, and so does the gate.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wintrust.h>
#include <softpub.h>
#include <wincrypt.h>
#include <stdlib.h>
#include <shlwapi.h>
#include "sg-ease.h"

#define ID_YES    201
#define ID_NO     202
#define ID_USER   203
#define ID_PASS   204
#define ID_STATUS 205
#define ID_EASE   206

#define PANEL_W 560
#define PANEL_H_ADMIN 334
#define PANEL_H_CRED  444

static HANDLE g_in, g_out;
static HWND g_main, g_user, g_pass, g_status, g_yes, g_no;
static HFONT g_font_big, g_font, g_font_bold;
static HBRUSH g_bg, g_panel, g_accent_br;
static BOOL g_cred_mode, g_shadow_mode, g_done, g_waiting;
static char g_requester[128], g_program[1024];
static RECT g_panel_rc;
static WPARAM g_armed;       /* the answer key whose press we saw */
static DWORD g_shown_at;

/* The panel: white, with the project's purple along the top -- the prompt's banner. */
static const COLORREF COL_DIM    = RGB(0x10, 0x10, 0x18);
static const COLORREF COL_PANEL  = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_ACCENT = RGB(0x7B, 0x2F, 0xBE);
static const COLORREF COL_TEXT   = RGB(0x1A, 0x1A, 0x1A);
static const COLORREF COL_SUBTLE = RGB(0x60, 0x60, 0x60);
static const COLORREF COL_ERR    = RGB(0xC4, 0x2B, 0x1C);

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
    size_t n = 0;
    DWORD got;
    char c;

    while (n + 1 < max)
    {
        if (!ReadFile( g_in, &c, 1, &got, NULL ) || !got) return FALSE;
        if (c == '\n') break;
        if (c != '\r') buf[n++] = c;
    }
    buf[n] = 0;
    return TRUE;
}

static void finish_why( const char *verdict, const char *why )
{
    if (g_done) return;
    fprintf( stderr, "sg-consent: %s (%s)\n", verdict ? verdict : "done", why );
    g_done = TRUE;
    if (verdict) send_line( "%s", verdict );
    PostMessageA( g_main, WM_CLOSE, 0, 0 );
}
#define finish( v ) finish_why( v, __func__ )

static void set_status( const char *text, BOOL error )
{
    SetWindowLongPtrA( g_status, GWLP_USERDATA, error );
    SetWindowTextA( g_status, text );
    InvalidateRect( g_status, NULL, TRUE );
}

static void submit_yes( void )
{
    char user[256], pass[256];

    if (g_done || g_waiting) return;
    if (!g_cred_mode) { finish( "ALLOW" ); return; }

    GetWindowTextA( g_user, user, sizeof(user) );
    GetWindowTextA( g_pass, pass, sizeof(pass) );
    if (!user[0]) { set_status( "Enter an administrator's user name.", TRUE ); SetFocus( g_user ); return; }
    if (strchr( user, '\t' ) || strchr( pass, '\t' ) || strchr( pass, '\n' ))
    {
        set_status( "That password cannot be used here.", TRUE );
        return;
    }
    g_waiting = TRUE;
    EnableWindow( g_yes, FALSE );
    /* what is being checked stays as it was while it is checked */
    SendMessageA( g_user, EM_SETREADONLY, TRUE, 0 );
    SendMessageA( g_pass, EM_SETREADONLY, TRUE, 0 );
    set_status( "Checking...", FALSE );
    send_line( "CRED %s\t%s", user, pass );
    SetWindowTextA( g_pass, "" );
    SecureZeroMemory( pass, sizeof(pass) );
}

#define WM_BROKER_LINE (WM_APP + 1)
#define WM_BROKER_EOF  (WM_APP + 2)

static DWORD WINAPI reader_thread( void *arg )
{
    HWND hwnd = arg;
    char line[1024];

    while (read_line( line, sizeof(line) ))
    {
        char *copy = _strdup( line );
        if (copy) PostMessageA( hwnd, WM_BROKER_LINE, 0, (LPARAM)copy );
    }
    PostMessageA( hwnd, WM_BROKER_EOF, 0, 0 );
    return 0;
}

static void handle_broker_line( char *line )
{
    if (!strncmp( line, "FAILURE ", 8 ))
    {
        g_waiting = FALSE;
        EnableWindow( g_yes, TRUE );
        SendMessageA( g_user, EM_SETREADONLY, FALSE, 0 );
        SendMessageA( g_pass, EM_SETREADONLY, FALSE, 0 );
        set_status( line + 8, TRUE );
        SetFocus( g_pass );
    }
    else if (!strncmp( line, "DONE", 4 ))
        finish( NULL );
}

static HWND make_label( HWND parent, const char *text, int x, int y, int w, int h, HFONT font, int id )
{
    HWND wnd = CreateWindowExA( 0, "STATIC", text, WS_CHILD | WS_VISIBLE | SS_LEFT,
                                x, y, w, h, parent, (HMENU)(INT_PTR)id, NULL, NULL );
    SendMessageA( wnd, WM_SETFONT, (WPARAM)font, TRUE );
    return wnd;
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_ERASEBKGND:
    {
        HDC dc = (HDC)wp;
        RECT rc, band;
        GetClientRect( hwnd, &rc );
        FillRect( dc, &rc, g_bg );
        FillRect( dc, &g_panel_rc, g_panel );
        band = g_panel_rc;
        band.bottom = band.top + 6;
        FillRect( dc, &band, g_accent_br );
        return 1;
    }
    case WM_CTLCOLORSTATIC:
    {
        HDC dc = (HDC)wp;
        HWND ctl = (HWND)lp;
        SetBkColor( dc, COL_PANEL );
        if (ctl == g_status)
            SetTextColor( dc, GetWindowLongPtrA( ctl, GWLP_USERDATA ) ? COL_ERR : COL_SUBTLE );
        else if (GetDlgCtrlID( ctl ) == 0x7ff) SetTextColor( dc, COL_SUBTLE );
        else SetTextColor( dc, COL_TEXT );
        return (LRESULT)g_panel;
    }
    case WM_DRAWITEM:
        if (wp == ID_EASE)
        {
            sg_ease_draw( (const DRAWITEMSTRUCT *)lp, COL_PANEL, RGB(0xD8, 0xD8, 0xD8), COL_TEXT );
            return TRUE;
        }
        break;
    case WM_COMMAND:
        if (LOWORD( wp ) == ID_EASE) { sg_ease_menu( hwnd, (HWND)lp ); return 0; }
        if (LOWORD( wp ) == ID_YES) submit_yes();
        else if (LOWORD( wp ) == ID_NO) finish_why( "DENY", "No button" );
        return 0;
    case WM_BROKER_LINE:
        handle_broker_line( (char *)lp );
        free( (char *)lp );
        return 0;
    case WM_BROKER_EOF:
        /* The broker went away: nothing can be granted any more. */
        g_done = TRUE;
        PostMessageA( hwnd, WM_CLOSE, 0, 0 );
        return 0;
    case WM_CLOSE:
        if (!g_done) { finish_why( "DENY", "WM_CLOSE" ); return 0; }
        DestroyWindow( hwnd );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

/* The program's file name: the first word of the command (quoted or not),
 * without its folder */
static void program_name( char *out, size_t size )
{
    const char *p = g_program, *end, *base;
    size_t n;

    if (*p == '"') { p++; end = strchr( p, '"' ); }
    else end = strchr( p, ' ' );
    if (!end) end = p + strlen( p );
    for (base = p; p < end; p++) if (*p == '\\' || *p == '/') base = p + 1;
    n = (size_t)(end - base);
    if (!n) { snprintf( out, size, "%s", g_program ); return; }
    if (n >= size) n = size - 1;
    memcpy( out, base, n );
    out[n] = 0;
}

/* The file the request would run, from the command: a quoted first word, else
 * the shortest run of words that names a file (C:\Program Files\x.exe -a, as
 * CreateProcess reads it), else a bare name on the search path. For msiexec,
 * the package it installs: that is what the person is asked about. */
static BOOL program_file( WCHAR *out, DWORD cch )
{
    WCHAR cmd[1024], *p, *end, save, *base;
    DWORD attr;

    if (!MultiByteToWideChar( CP_ACP, 0, g_program, -1, cmd, ARRAYSIZE(cmd) )) return FALSE;
    p = cmd;
    if (*p == '"')
    {
        if (!(end = wcschr( ++p, '"' ))) return FALSE;
        *end++ = 0;
        lstrcpynW( out, p, cch );
    }
    else
    {
        for (end = p;; end++)
        {
            if (*end && *end != ' ') continue;
            save = *end; *end = 0;
            attr = GetFileAttributesW( p );
            if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) { lstrcpynW( out, p, cch ); *end = save; break; }
            *end = save;
            if (!*end)
            {
                /* no file by that name: a bare name on the search path */
                if ((end = wcschr( p, ' ' ))) *end++ = 0;
                else end = p + lstrlenW( p );
                if (!SearchPathW( NULL, p, L".exe", cch, out, NULL )) return FALSE;
                break;
            }
        }
        if (*end == ' ') end++;
    }
    for (base = out, p = out; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    if (!lstrcmpiW( base, L"msiexec.exe" ) || !lstrcmpiW( base, L"msiexec" ))
    {
        /* /i, /package (or -i), then the package, quoted or one word */
        for (p = end; *p; p++)
        {
            int n;
            if ((*p != '/' && *p != '-') || (p > end && p[-1] != ' ')) continue;
            n = !_wcsnicmp( p + 1, L"package ", 8 ) ? 9 : !_wcsnicmp( p + 1, L"i ", 2 ) ? 3 : 0;
            if (!n) continue;
            p += n;
            while (*p == ' ') p++;
            if (*p == '"') { if ((end = wcschr( ++p, '"' ))) *end = 0; }
            else if ((end = wcschr( p, ' ' ))) *end = 0;
            lstrcpynW( out, p, cch );
            break;
        }
    }
    attr = GetFileAttributesW( out );
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

/* Is the file one of the system's own programs: in the system folders, or
 * directly in the Windows folder (not in its Temp)? Only an administrator
 * can put a file there. */
static BOOL is_system_file( const WCHAR *path )
{
    WCHAR full[MAX_PATH], dir[MAX_PATH], *base = NULL;
    UINT n;

    if (!GetFullPathNameW( path, MAX_PATH, full, &base ) || !base) return FALSE;
    base[-1] = 0;   /* full is now the folder */
    if ((n = GetSystemDirectoryW( dir, MAX_PATH )) && !lstrcmpiW( full, dir )) return TRUE;
    if ((n = GetSystemWow64DirectoryW( dir, MAX_PATH )) && !lstrcmpiW( full, dir )) return TRUE;
    if ((n = GetWindowsDirectoryW( dir, MAX_PATH )) && !lstrcmpiW( full, dir )) return TRUE;
    return FALSE;
}

/* The file's own description (its version information's FileDescription). */
static BOOL file_description( const WCHAR *path, char *out, size_t size )
{
    DWORD handle, len = GetFileVersionInfoSizeW( path, &handle );
    WORD *lang;
    WCHAR key[64], *desc;
    UINT n;
    BYTE *info;
    BOOL ok = FALSE;

    if (!len || !(info = malloc( len ))) return FALSE;
    if (GetFileVersionInfoW( path, 0, len, info ))
    {
        if (VerQueryValueW( info, L"\\VarFileInfo\\Translation", (void **)&lang, &n ) && n >= 4)
            swprintf( key, ARRAYSIZE(key), L"\\StringFileInfo\\%04x%04x\\FileDescription", lang[0], lang[1] );
        else
            lstrcpyW( key, L"\\StringFileInfo\\040904b0\\FileDescription" );
        if (VerQueryValueW( info, key, (void **)&desc, &n ) && n > 1 && desc[0])
            ok = WideCharToMultiByte( CP_ACP, 0, desc, -1, out, (int)size, NULL, NULL ) > 1;
    }
    free( info );
    return ok;
}

/* Who signed the file, if its signature is valid and its chain ends in a
 * root trusted for code signing (WinVerifyTrust, as Windows asks it). No
 * revocation or download: the prompt must not wait on the network. */
static BOOL verified_publisher( const WCHAR *path, char *out, size_t size )
{
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    WINTRUST_FILE_INFO file = { sizeof(file) };
    WINTRUST_DATA data = { sizeof(data) };
    CRYPT_PROVIDER_DATA *prov;
    CRYPT_PROVIDER_SGNR *signer;
    CRYPT_PROVIDER_CERT *cert;
    BOOL ok = FALSE;

    file.pcwszFilePath = path;
    data.dwUIChoice = WTD_UI_NONE;
    data.fdwRevocationChecks = WTD_REVOKE_NONE;
    data.dwUnionChoice = WTD_CHOICE_FILE;
    data.pFile = &file;
    data.dwStateAction = WTD_STATEACTION_VERIFY;
    data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_NONE;
    if (!WinVerifyTrust( (HWND)INVALID_HANDLE_VALUE, &action, &data ) &&
        (prov = WTHelperProvDataFromStateData( data.hWVTStateData )) &&
        (signer = WTHelperGetProvSignerFromChain( prov, 0, FALSE, 0 )) &&
        (cert = WTHelperGetProvCertFromChain( signer, 0 )))
        ok = CertGetNameStringA( cert->pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, out, (DWORD)size ) > 1;
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust( (HWND)INVALID_HANDLE_VALUE, &action, &data );
    return ok;
}

/* The name in bold and the publisher line, as Windows' prompt shows them: a
 * signed program by its own description and its verified publisher; an
 * unsigned one by its file name -- what it says about itself is not
 * trusted -- and "Publisher: Unknown"; the system's own programs as the
 * system's. A Linux program (pkexec) has no publisher line. */
struct description { char name[260], publisher[300]; };
static struct description g_desc;

/* fills its own copy: one that times out keeps writing only there */
static DWORD WINAPI describe_thread( void *arg )
{
    struct description *d = arg;
    WCHAR path[MAX_PATH];
    char who[256];

    if (!program_file( path, MAX_PATH )) return 0;
    WideCharToMultiByte( CP_ACP, 0, PathFindFileNameW( path ), -1, d->name, sizeof(d->name), NULL, NULL );
    if (is_system_file( path ))
        snprintf( d->publisher, sizeof(d->publisher), "Publisher: Stained Glass (part of the system)" );
#ifndef SG_MUTANT_CONSENT_TRUSTS_UNSIGNED
    else if (verified_publisher( path, who, sizeof(who) ))
#else
    else if (lstrcpyA( who, "anyone" ))
#endif
    {
        snprintf( d->publisher, sizeof(d->publisher), "Verified publisher: %s", who );
        file_description( path, d->name, sizeof(d->name) );
    }
    else
        snprintf( d->publisher, sizeof(d->publisher), "Publisher: Unknown" );
    return 0;
}

static void describe_program( void )
{
    struct description *d;
    HANDLE thread;

    program_name( g_desc.name, sizeof(g_desc.name) );
    g_desc.publisher[0] = 0;
    if (g_program[0] == '/') return;   /* a Linux program */
    if (!(d = calloc( 1, sizeof(*d) ))) return;
    lstrcpyA( d->name, g_desc.name );
    /* a few seconds at most: the prompt shows either way */
    if ((thread = CreateThread( NULL, 0, describe_thread, d, 0, NULL )))
    {
        if (WaitForSingleObject( thread, 4000 ) == WAIT_OBJECT_0) { g_desc = *d; free( d ); }
        else snprintf( g_desc.publisher, sizeof(g_desc.publisher), "Publisher: Unknown" );   /* d stays the thread's */
        CloseHandle( thread );
    }
    else free( d );
}

/* Parse "/consent admin|cred <requester> <program...>". */
static BOOL parse_cmdline( const char *cmd )
{
    const char *p;
    size_t n;

    if (!cmd || strncmp( cmd, "/consent ", 9 )) return FALSE;
    p = cmd + 9;
    if (!strncmp( p, "admin ", 6 )) { g_cred_mode = FALSE; p += 6; }
    else if (!strncmp( p, "cred ", 5 )) { g_cred_mode = TRUE; p += 5; }
    else if (!strncmp( p, "shadow ", 7 )) { g_cred_mode = FALSE; g_shadow_mode = TRUE; p += 7; }
    else return FALSE;
    n = strcspn( p, " " );
    if (!n || n >= sizeof(g_requester)) return FALSE;
    memcpy( g_requester, p, n );
    g_requester[n] = 0;
    p += n;
    while (*p == ' ') p++;
    snprintf( g_program, sizeof(g_program), "%s", *p ? p : "(unknown program)" );
    /* Wine quotes an argument that has spaces in it. */
    n = strlen( g_program );
    if (n >= 2 && g_program[0] == '"' && g_program[n - 1] == '"')
    {
        memmove( g_program, g_program + 1, n - 2 );
        g_program[n - 2] = 0;
    }
    return TRUE;
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show )
{
    WNDCLASSA wc = {0};
    MSG msg;
    int sw, sh;
    int ph, px, py, y;
    char line[1200];
    HWND first, wnd;
    HDESK desk;

    (void)prev; (void)show;
    g_in = GetStdHandle( STD_INPUT_HANDLE );
    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    /* "/describe <program...>": what the prompt would say about it (the gate) */
    if (cmdline && !strncmp( cmdline, "/describe ", 10 ))
    {
        size_t n;
        snprintf( g_program, sizeof(g_program), "%s", cmdline + 10 );
        n = strlen( g_program );
        if (n >= 2 && g_program[0] == '"' && g_program[n - 1] == '"')   /* as parse_cmdline */
        {
            memmove( g_program, g_program + 1, n - 2 );
            g_program[n - 2] = 0;
        }
        describe_program();
        send_line( "name %s", g_desc.name );
        send_line( "publisher %s", g_desc.publisher );
        return 0;
    }
    if (!parse_cmdline( cmdline ))
    {
        send_line( "DENY" );
        return 2;
    }

    /* A desktop of our own. Wine binds a desktop to the X server of the
     * explorer that first served it; the shared "Default" desktop would still
     * belong to the previous prompt's X server, already torn down, and its
     * death closed the next prompt a moment after it opened. A fresh desktop
     * gets an explorer on this prompt's own X server. */
    snprintf( line, sizeof(line), "sg-consent-%lu", GetCurrentProcessId() );
    if ((desk = CreateDesktopA( line, NULL, NULL, 0, GENERIC_ALL, NULL ))) SetThreadDesktop( desk );
    sw = GetSystemMetrics( SM_CXSCREEN );
    sh = GetSystemMetrics( SM_CYSCREEN );

    g_bg = CreateSolidBrush( COL_DIM );
    g_panel = CreateSolidBrush( COL_PANEL );
    g_accent_br = CreateSolidBrush( COL_ACCENT );
    g_font_big = CreateFontA( -22, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, "Segoe UI" );
    g_font = CreateFontA( -15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, "Segoe UI" );
    g_font_bold = CreateFontA( -16, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, "Segoe UI" );

    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.lpszClassName = "SgConsent";
    RegisterClassA( &wc );

    ph = g_cred_mode ? PANEL_H_CRED : PANEL_H_ADMIN;
    px = (sw - PANEL_W) / 2;
    py = (sh - ph) / 2;
    SetRect( &g_panel_rc, px, py, px + PANEL_W, py + ph );

    g_main = CreateWindowExA( WS_EX_TOPMOST, "SgConsent", g_shadow_mode ? "Remote Desktop request" : "Permission required",
                              WS_POPUP | WS_VISIBLE, 0, 0, sw, sh, NULL, NULL, inst, NULL );

    y = py + 22;
    if (g_shadow_mode)
    {
        /* Someone asks, over Remote Desktop, to watch (or work in) this
         * session while its user stays here. The requester's name is the
         * account Remote Desktop signed in, not anything they typed. */
        BOOL control = !strcmp( g_program, "control" );
        make_label( g_main, "Remote Desktop", px + 24, y, PANEL_W - 48, 20, g_font, 0x7ff );
        y += 28;
        snprintf( line, sizeof(line), control ? "%s wants to view and control your session remotely. Do you accept?"
                                              : "%s wants to view your session remotely. Do you accept?", g_requester );
        make_label( g_main, line, px + 24, y, PANEL_W - 48, 84, g_font_big, 0 );
        y += 90;
        make_label( g_main, control ? "They will see your screen and can use the keyboard and mouse along with you."
                                    : "They will see everything on your screen, but cannot type or click.",
                    px + 24, y, PANEL_W - 48, 40, g_font, 0x7ff );
        y += 44;
        make_label( g_main, "A coloured frame shows while it lasts. Ctrl+Alt+Del ends it.",
                    px + 24, y, PANEL_W - 48, 20, g_font, 0x7ff );
        y += 30;
    }
    else
    {
        make_label( g_main, "Stained Glass needs your permission", px + 24, y, PANEL_W - 48, 20, g_font, 0x7ff );
        y += 28;
        make_label( g_main, "Do you want to allow this app to make changes to your device?",
                    px + 24, y, PANEL_W - 48, 56, g_font_big, 0 );
        y += 62;
        /* the program's name in bold, and the whole command below it, as
         * Windows' "Program location": a long one ("msiexec.exe /i C:\...\x.msi")
         * was cut to its first words */
        describe_program();
        make_label( g_main, g_desc.name, px + 24, y, PANEL_W - 48, 22, g_font_bold, 0 );
        y += 26;
        if (g_desc.publisher[0])
        {
            make_label( g_main, g_desc.publisher, px + 24, y, PANEL_W - 48, 20, g_font, 0x7ff );
            y += 24;
        }
        snprintf( line, sizeof(line), "Program location: %s", g_program );
        wnd = make_label( g_main, line, px + 24, y, PANEL_W - 48, 56, g_font, 0x7ff );
        SetWindowLongA( wnd, GWL_STYLE, GetWindowLongA( wnd, GWL_STYLE ) | SS_EDITCONTROL );
        y += 60;
        snprintf( line, sizeof(line), "Requested by %s. It will run as an administrator.", g_requester );
        make_label( g_main, line, px + 24, y, PANEL_W - 48, 20, g_font, 0x7ff );
        y += 30;
    }

    if (g_cred_mode)
    {
        make_label( g_main, "To continue, enter an administrator user name and password.",
                    px + 24, y, PANEL_W - 48, 20, g_font, 0 );
        y += 28;
        g_user = CreateWindowExA( WS_EX_CLIENTEDGE, "EDIT", "", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                                  px + 24, y, PANEL_W - 48, 28, g_main, (HMENU)ID_USER, inst, NULL );
        SendMessageA( g_user, WM_SETFONT, (WPARAM)g_font, TRUE );
        y += 34;
        g_pass = CreateWindowExA( WS_EX_CLIENTEDGE, "EDIT", "",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
                                  px + 24, y, PANEL_W - 48, 28, g_main, (HMENU)ID_PASS, inst, NULL );
        SendMessageA( g_pass, WM_SETFONT, (WPARAM)g_font, TRUE );
        y += 36;
    }

    g_status = make_label( g_main, "", px + 24, py + ph - 76, PANEL_W - 48, 20, g_font, ID_STATUS );
    g_yes = CreateWindowExA( 0, "BUTTON", "&Yes", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                             px + PANEL_W - 24 - 2 * 120 - 10, py + ph - 48, 120, 32, g_main, (HMENU)ID_YES, inst, NULL );
    g_no = CreateWindowExA( 0, "BUTTON", "&No", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                            px + PANEL_W - 24 - 120, py + ph - 48, 120, 32, g_main, (HMENU)ID_NO, inst, NULL );
    SendMessageA( g_yes, WM_SETFONT, (WPARAM)g_font, TRUE );
    SendMessageA( g_no, WM_SETFONT, (WPARAM)g_font, TRUE );
    /* Ease of Access, bottom left of the panel: a keyboard for a computer
     * without one -- in this prompt's own X server and desktop (sg-ease.h) */
    if (g_cred_mode) sg_ease_button( g_main, px + 20, py + ph - 52, 40, ID_EASE, inst );

    CreateThread( NULL, 0, reader_thread, g_main, 0, NULL );
    if (g_cred_mode) sg_ease_start();
    g_shown_at = GetTickCount();
    SetForegroundWindow( g_main );
    /* Safe default: in the Yes/No prompt focus rests on No, so a stray Enter
     * denies; with credentials it starts in the user name. */
    first = g_cred_mode ? g_user : g_no;
    SetFocus( first );

    while (GetMessageA( &msg, NULL, 0, 0 ) > 0)
    {
        /* Answers act on a key's release, and only for a key whose press
         * this prompt saw: a key already held when the prompt appeared --
         * which the compositor re-delivers as a press when the prompt's X
         * server gains focus -- must not answer it. That is how the previous
         * prompt's Escape used to decline the next one. Repeats never arm. */
        if ((msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN) && !g_done)
        {
            BOOL repeat = (msg.lParam >> 30) & 1;
            switch (msg.wParam)
            {
            case VK_ESCAPE: case VK_RETURN: case 'Y': case 'N':
                if (msg.wParam >= 'A' && msg.message != WM_SYSKEYDOWN) break;   /* only Alt+Y / Alt+N */
                if (!repeat && GetTickCount() - g_shown_at > 250) g_armed = msg.wParam;
                continue;
            case VK_TAB: case VK_LEFT: case VK_RIGHT:
            {
                HWND focus = GetFocus();
                BOOL back;
                if (msg.wParam != VK_TAB && focus != g_yes && focus != g_no) break;
                back = msg.wParam == VK_LEFT || (msg.wParam == VK_TAB && GetKeyState( VK_SHIFT ) < 0);
                if ((focus = GetNextDlgTabItem( g_main, focus, back ))) SetFocus( focus );
                continue;
            }
            }
        }
        if ((msg.message == WM_KEYUP || msg.message == WM_SYSKEYUP) && !g_done && msg.wParam == g_armed)
        {
            HWND focus = GetFocus();
            g_armed = 0;
            switch (msg.wParam)
            {
            case VK_ESCAPE: finish_why( "DENY", "Escape" ); break;
            case 'N':       finish_why( "DENY", "Alt+N" ); break;
            case 'Y':       submit_yes(); break;
            case VK_RETURN:
                if (focus == g_no) finish_why( "DENY", "Enter on No" );
                else if (focus == g_yes || g_cred_mode) submit_yes();
                break;
            }
            continue;
        }
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
    return 0;
}
