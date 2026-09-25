/* Stained Glass OS Setup: the installation wizard.
 *
 * On a live boot (the installation media's "live" entry) this takes the
 * login screen's place, full screen, as Windows Setup does; from the live
 * desktop ("Try Stained Glass OS") the same wizard runs in a window
 * (--windowed). It is a Windows program for the same reason the login screen
 * is: remote-support tools can see and drive it. It decides nothing.
 * sg-setup-bridge passes what it asks for to sg-installd, the root service
 * that runs sg-install; both check every request again.
 *
 * Pages: Welcome (language, keyboard) -> Start (Install now / Try) ->
 * License -> Type -> Account -> Disk (where, with a partitioner) -> Ready ->
 * Installing -> Done (or Failed). Protocol, line-based, on the pipes it was
 * started with (see sg-installd for the other end):
 *
 *   -> HELLO                  the window is up
 *   -> TRY                    sign in to the live system instead (the bridge)
 *   -> LAYOUT                 <- DISK/PART/FREE lines, END
 *   -> NEW / DELETE / FORMAT  <- OK | FAILED <text>
 *   -> DRIVERS                <- DEVICE lines (sg-drivers --list), END
 *   -> INSTALL <target>\t<account>\t<hostname>\t<full name>\t<keyboard>\t<drivers>
 *   -> PASSWORD <password>    starts the installation
 *   <- PROGRESS <percent> <text>     <- MOKPASSWORD <password>
 *   <- DONE | FAILED <text>
 *   -> REBOOT | POWEROFF
 *
 * Started by hand (a desktop shortcut) rather than by its bridge, it starts
 * the bridge, which starts it again, windowed.
 *
 * Keys: Tab moves; Enter presses the focused button, or elsewhere the page's
 * main button; Escape goes back. Enter and Escape act on release, and only
 * for a press seen on the same page, so a key held down on one page cannot
 * answer the next one -- the next one may be "erase this". The gates drive
 * the whole wizard from the keyboard, as remote support would. Each page
 * change is logged to stderr ("sg-setup: page <name>"), which reaches the
 * journal; the gates wait on it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum page { P_WELCOME, P_START, P_LICENSE, P_TYPE, P_ACCOUNT, P_DISK, P_READY, P_INSTALLING, P_DONE, P_FAILED };
static const char *const page_names[] = { "welcome", "start", "license", "type", "account", "disk", "ready",
                                          "installing", "done", "failed" };

#define ID_NEXT     301
#define ID_BACK     302
#define ID_LEFT     303
#define ID_DISKS    304
#define ID_NAME     305
#define ID_ACCOUNT  306
#define ID_PASS     307
#define ID_PASS2    308
#define ID_HOST     309
#define ID_LANG     310
#define ID_LOCALE   311
#define ID_KBD      312
#define ID_INSTALL  313
#define ID_TRY      314
#define ID_LICTEXT  315
#define ID_ACCEPT   316
#define ID_UPGRADE  317
#define ID_CUSTOM   318
#define ID_REFRESH  319
#define ID_DELETE   320
#define ID_FORMAT   321
#define ID_NEW      322
#define ID_SIZE     323
#define ID_APPLY    324
#define ID_CANCEL   325
#define ID_CLOSE    326
#define ID_POWER    327
#define ID_DRIVERS  328

#define WIN_W 800
#define WIN_H 600
#define CAP_H 32
#define CW WIN_W
#define CH (WIN_H - CAP_H)
#define MAX_ROWS 64

#define WM_BRIDGE_LINE (WM_APP + 1)
#define WM_BRIDGE_EOF  (WM_APP + 2)
#define TIMER_RESTART  1

static const COLORREF COL_WIN     = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_TEXT    = RGB(0x1A, 0x1A, 0x1A);
static const COLORREF COL_SUBTLE  = RGB(0x5C, 0x5C, 0x5C);
static const COLORREF COL_LINK    = RGB(0x00, 0x5F, 0xB8);
static const COLORREF COL_DIS     = RGB(0xA0, 0xA0, 0xA0);
static const COLORREF COL_ERR     = RGB(0xC4, 0x2B, 0x1C);
static const COLORREF COL_TRACK   = RGB(0xE3, 0xE3, 0xE8);
static const COLORREF COL_BAR     = RGB(0x5B, 0x2A, 0xA8);
static const COLORREF COL_CAPLINE = RGB(0xD8, 0xD8, 0xDE);
static const COLORREF COL_OPTION  = RGB(0xF3, 0xF1, 0xF8);

static HANDLE g_in, g_out;
static BOOL g_windowed;
static HWND g_main, g_next, g_back, g_left;
static HWND g_lang, g_locale, g_kbd, g_install, g_try, g_lictext, g_accept, g_upgrade, g_custom;
static HWND g_name, g_account, g_pass, g_pass2, g_host;
static HWND g_disks, g_refresh, g_delete, g_format, g_new, g_size, g_apply, g_cancel;
static HWND g_close, g_power, g_drivers;
static HFONT g_font_title, g_font_head, g_font, g_font_bold, g_font_small, g_font_big, g_font_logo;
static HBRUSH g_win_brush;
static HBITMAP g_backdrop;
static RECT g_rc;               /* the setup window, in client coordinates */
static enum page g_page = P_WELCOME;
static WPARAM g_armed;          /* Enter or Escape, pressed on this page */

/* The disk page. */
enum row_kind { R_FREE, R_PART, R_MBR };
struct row
{
    enum row_kind kind;
    int drive, number;
    char disk[64], path[64], type[16], fstype[16], label[64];
    unsigned long long bytes, free_bytes, start, sectors;
    BOOL free_known, disk_has_esp;
};
static struct row g_row[MAX_ROWS], g_chosen_row;
static int g_nrows, g_sel = -1, g_ndrives;
static BOOL g_listing, g_busy, g_new_mode, g_after_new;
static char g_old_paths[MAX_ROWS][64];
static int g_nold;

static char g_heading[160], g_body[1024], g_status[256];
static BOOL g_status_err;
static int g_percent, g_countdown;
static char g_kbd_code[8] = "us";
static BOOL g_drivers_listing, g_drivers_listed;
static char g_found[512];       /* what the drivers survey found, for the type page */
static char g_mok[32];          /* Secure Boot: the enrollment password, for the last page */

static const struct { const char *code, *name; } g_layouts[] = {
    { "us", "US" }, { "gb", "United Kingdom" }, { "de", "German" }, { "fr", "French" },
    { "es", "Spanish" }, { "it", "Italian" }, { "pt", "Portuguese" }, { "br", "Portuguese (Brazil)" },
    { "nl", "Dutch" }, { "be", "Belgian" }, { "ch", "Swiss" }, { "se", "Swedish" }, { "no", "Norwegian" },
    { "dk", "Danish" }, { "fi", "Finnish" }, { "pl", "Polish" }, { "cz", "Czech" }, { "hu", "Hungarian" },
    { "jp", "Japanese" }, { "ca", "Canadian Multilingual" },
};

static const char g_license[] =
    "STAINED GLASS OS\r\n"
    "Notices and license terms\r\n\r\n"
    "Stained Glass OS is free software. It is made of many programs, each under its own license, "
    "and every one of them gives you the right to run it for any purpose, to study and change it, "
    "and to share it, with or without your changes.\r\n\r\n"
    "1. Stained Glass OS's own components (the session, the shell, the compositor, Setup) are "
    "licensed under the GNU Affero General Public License, version 3 or later.\r\n\r\n"
    "2. Its Windows compatibility layer, wine-sg, is Wine with Stained Glass OS's changes, licensed "
    "under the GNU Lesser General Public License, version 2.1 or later.\r\n\r\n"
    "3. The rest of the system comes from Debian. Each package's terms are in "
    "/usr/share/doc/<package>/copyright on the installed system.\r\n\r\n"
    "4. Windows programs you install yourself are licensed to you by their publishers, under their "
    "own terms. Stained Glass OS does not include any Microsoft software.\r\n\r\n"
    "5. No warranty. Stained Glass OS is provided \"as is\", without warranty of any kind, to the "
    "extent permitted by law. See each license for the full terms.\r\n\r\n"
    "The source code of every component is available from the Stained Glass OS project and from "
    "Debian.";

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

static void log_line( const char *fmt, ... )
{
    char buf[256];
    va_list ap;
    DWORD written;
    int n;

    va_start( ap, fmt );
    n = vsnprintf( buf, sizeof(buf) - 1, fmt, ap );
    va_end( ap );
    if (n < 0 || n > (int)sizeof(buf) - 2) n = sizeof(buf) - 2;
    buf[n++] = '\n';
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), buf, n, &written, NULL );
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

/* Sizes as Windows Setup shows them. */
static void size_text( unsigned long long bytes, char *out, size_t len )
{
    double mb = (double)bytes / (1024.0 * 1024.0);
    if (mb >= 1024.0 * 1024.0) snprintf( out, len, "%.1f TB", mb / (1024.0 * 1024.0) );
    else if (mb >= 1024.0) snprintf( out, len, "%.1f GB", mb / 1024.0 );
    else snprintf( out, len, "%.0f MB", mb );
}

static void set_status( const char *text, BOOL err )
{
    snprintf( g_status, sizeof(g_status), "%s", text );
    g_status_err = err;
    InvalidateRect( g_main, NULL, FALSE );
}

static void show( HWND w, BOOL on ) { ShowWindow( w, on ? SW_SHOW : SW_HIDE ); }

/* --- the disk page ---------------------------------------------------------- */

#define GIB (1024ULL * 1024 * 1024)
#define MIN_ROOT (10 * GIB)

static void row_name( const struct row *r, char *out, size_t len )
{
    if (r->kind == R_FREE) snprintf( out, len, "Drive %d Unallocated Space", r->drive );
    else if (r->kind == R_MBR) snprintf( out, len, "Drive %d (MBR partition table)", r->drive );
    else if (strcmp( r->label, "-" )) snprintf( out, len, "Drive %d Partition %d: %s", r->drive, r->number, r->label );
    else snprintf( out, len, "Drive %d Partition %d", r->drive, r->number );
}

static const char *row_type( const struct row *r )
{
    if (r->kind == R_FREE) return "";
    if (r->kind == R_MBR) return "MBR disk";
    if (!strcmp( r->type, "system" )) return "System";
    if (!strcmp( r->type, "msr" )) return "MSR (Reserved)";
    if (!strcmp( r->type, "recovery" )) return "Recovery";
    if (!strcmp( r->type, "boot" )) return "Boot";
    return "Primary";
}

/* Why the selected row cannot take Stained Glass OS, or NULL if it can. The
 * installer checks again; this is so the page can say so first. */
static const char *row_problem( const struct row *r, char *buf, size_t len )
{
    if (r->kind == R_MBR)
        return "This disk has an MBR partition table. On UEFI PCs Stained Glass OS installs to GPT disks only.";
    if (r->kind == R_FREE)
    {
        unsigned long long need = MIN_ROOT + (r->disk_has_esp ? GIB : 512ULL * 1024 * 1024);
        if (r->bytes < need)
        {
            snprintf( buf, len, "This space is too small. Stained Glass OS needs %llu GB.", need / GIB + 1 );
            return buf;
        }
        return NULL;
    }
    if (strcmp( r->type, "primary" ))
        return "This partition is used by the system to start the PC. Choose another place.";
    if (r->bytes < MIN_ROOT)
    {
        snprintf( buf, len, "This partition is too small. Stained Glass OS needs %llu GB.", MIN_ROOT / GIB );
        return buf;
    }
    if (!r->disk_has_esp)
        return "Setup was unable to create a new system partition or locate an existing system partition.";
    return NULL;
}

static void update_disk_buttons( void )
{
    const struct row *r = g_sel >= 0 && g_sel < g_nrows ? &g_row[g_sel] : NULL;
    char buf[160];
    const char *problem = r ? row_problem( r, buf, sizeof(buf) ) : NULL;
    BOOL idle = !g_busy && !g_listing;

    EnableWindow( g_refresh, idle );
    EnableWindow( g_delete, idle && r && r->kind == R_PART );
    EnableWindow( g_format, idle && r && r->kind == R_PART && !strcmp( r->type, "primary" ) );
    EnableWindow( g_new, idle && r && r->kind == R_FREE );
    EnableWindow( g_next, idle && r && !problem && !g_new_mode );
    if (g_busy || g_listing) set_status( "Please wait...", FALSE );
    else if (problem) set_status( problem, TRUE );
    else if (!g_nrows) set_status( "No drives were found. Connect a drive, then select Refresh.", TRUE );
    else set_status( "", FALSE );
}

static void set_new_mode( BOOL on )
{
    g_new_mode = on;
    show( g_size, on ); show( g_apply, on ); show( g_cancel, on );
    if (on && g_sel >= 0)
    {
        char mb[32];
        snprintf( mb, sizeof(mb), "%llu", g_row[g_sel].bytes / (1024 * 1024) );
        SetWindowTextA( g_size, mb );
        SetFocus( g_size );
        SendMessageA( g_size, EM_SETSEL, 0, -1 );
    }
    else if (g_page == P_DISK) SetFocus( g_disks );
    update_disk_buttons();
    InvalidateRect( g_main, NULL, FALSE );
}

static void request_layout( void )
{
    int i;

    g_nold = 0;
    for (i = 0; i < g_nrows && g_nold < MAX_ROWS; i++)
        if (g_row[i].kind == R_PART) strcpy( g_old_paths[g_nold++], g_row[i].path );
    SendMessageA( g_disks, LVM_DELETEALLITEMS, 0, 0 );
    g_nrows = 0;
    g_ndrives = 0;
    g_sel = -1;
    g_listing = TRUE;
    update_disk_buttons();
    send_line( "LAYOUT" );
}

static void select_row( int i )
{
    LVITEMA it = {0};
    if (i < 0 || i >= g_nrows) return;
    it.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
    it.state = LVIS_SELECTED | LVIS_FOCUSED;
    SendMessageA( g_disks, LVM_SETITEMSTATE, i, (LPARAM)&it );
    SendMessageA( g_disks, LVM_ENSUREVISIBLE, i, FALSE );
    g_sel = i;
}

static void add_row_item( int i )
{
    const struct row *r = &g_row[i];
    char name[128], total[32], freeb[32];
    LVITEMA it = {0};

    row_name( r, name, sizeof(name) );
    size_text( r->bytes, total, sizeof(total) );
    if (r->kind == R_FREE) strcpy( freeb, total );
    else if (r->free_known) size_text( r->free_bytes, freeb, sizeof(freeb) );
    else if (r->kind == R_PART && !strcmp( r->fstype, "-" )) strcpy( freeb, total );
    else freeb[0] = 0;
    if (r->kind == R_MBR) total[0] = freeb[0] = 0;

    it.mask = LVIF_TEXT | LVIF_IMAGE;
    it.iItem = i;
    it.iImage = 0;
    it.pszText = name;
    SendMessageA( g_disks, LVM_INSERTITEMA, 0, (LPARAM)&it );
    it.mask = LVIF_TEXT;
    it.iSubItem = 1; it.pszText = total; SendMessageA( g_disks, LVM_SETITEMTEXTA, i, (LPARAM)&it );
    it.iSubItem = 2; it.pszText = freeb; SendMessageA( g_disks, LVM_SETITEMTEXTA, i, (LPARAM)&it );
    it.iSubItem = 3; it.pszText = (char *)row_type( r ); SendMessageA( g_disks, LVM_SETITEMTEXTA, i, (LPARAM)&it );
}

/* Splits a tab-separated line in place. */
static int split_tabs( char *s, char **field, int max )
{
    int n = 0;
    while (n < max)
    {
        field[n++] = s;
        if (!(s = strchr( s, '\t' ))) break;
        *s++ = 0;
    }
    return n;
}

static void layout_line( char *line )
{
    char *f[10];
    struct row *r;
    int n;

    if (!strncmp( line, "DISK ", 5 ))
    {
        n = split_tabs( line + 5, f, 4 );
        g_ndrives++;
        if (n >= 4 && !strcmp( f[3], "dos" ) && g_nrows < MAX_ROWS)
        {
            r = &g_row[g_nrows++];
            memset( r, 0, sizeof(*r) );
            r->kind = R_MBR;
            r->drive = g_ndrives - 1;
            snprintf( r->disk, sizeof(r->disk), "%s", f[0] );
        }
        return;
    }
    if (g_nrows >= MAX_ROWS) return;
    r = &g_row[g_nrows];
    memset( r, 0, sizeof(*r) );
    r->drive = g_ndrives - 1;
    if (!strncmp( line, "PART ", 5 ) && split_tabs( line + 5, f, 8 ) >= 8)
    {
        r->kind = R_PART;
        snprintf( r->path, sizeof(r->path), "%s", f[0] );
        snprintf( r->disk, sizeof(r->disk), "%s", f[1] );
        r->number = atoi( f[2] );
        r->bytes = _strtoui64( f[3], NULL, 10 );
        r->free_known = strcmp( f[4], "-" ) != 0;
        r->free_bytes = r->free_known ? _strtoui64( f[4], NULL, 10 ) : 0;
        snprintf( r->type, sizeof(r->type), "%s", f[5] );
        snprintf( r->fstype, sizeof(r->fstype), "%s", f[6] );
        snprintf( r->label, sizeof(r->label), "%s", f[7] );
        g_nrows++;
    }
    else if (!strncmp( line, "FREE ", 5 ) && split_tabs( line + 5, f, 4 ) >= 4)
    {
        r->kind = R_FREE;
        snprintf( r->disk, sizeof(r->disk), "%s", f[0] );
        r->start = _strtoui64( f[1], NULL, 10 );
        r->sectors = _strtoui64( f[2], NULL, 10 );
        r->bytes = _strtoui64( f[3], NULL, 10 );
        g_nrows++;
    }
}

static void layout_done( void )
{
    int i, j, pick = -1, largest = -1;
    char buf[160], name[128];

    g_listing = FALSE;
    /* Which disks have a system partition: the page says so before Next. */
    for (i = 0; i < g_nrows; i++)
        for (j = 0; j < g_nrows; j++)
            if (g_row[j].kind == R_PART && !strcmp( g_row[j].type, "system" ) && !strcmp( g_row[j].disk, g_row[i].disk ))
                g_row[i].disk_has_esp = TRUE;
    for (i = 0; i < g_nrows; i++) add_row_item( i );
    log_line( "sg-setup: layout %d rows", g_nrows );

    /* After New, the partition it made; otherwise the largest place Stained
     * Glass OS fits, as Windows Setup preselects. */
    if (g_after_new)
        for (i = 0; i < g_nrows && pick < 0; i++)
        {
            if (g_row[i].kind != R_PART || strcmp( g_row[i].type, "primary" )) continue;
            for (j = 0; j < g_nold && strcmp( g_old_paths[j], g_row[i].path ); j++) ;
            if (j == g_nold) pick = i;
        }
    g_after_new = FALSE;
    if (pick < 0)
        for (i = 0; i < g_nrows; i++)
            if (!row_problem( &g_row[i], buf, sizeof(buf) ) && (largest < 0 || g_row[i].bytes > g_row[largest].bytes))
                largest = i;
    if (pick < 0) pick = largest >= 0 ? largest : (g_nrows ? 0 : -1);
    if (pick >= 0)
    {
        select_row( pick );
        row_name( &g_row[pick], name, sizeof(name) );
        log_line( "sg-setup: selected %s", name );
    }
    update_disk_buttons();
}

/* A partition operation; the answer (OK or FAILED) refreshes the list. */
static void operate( const char *fmt, ... )
{
    char buf[512];
    va_list ap;

    va_start( ap, fmt );
    vsnprintf( buf, sizeof(buf), fmt, ap );
    va_end( ap );
    g_busy = TRUE;
    update_disk_buttons();
    send_line( "%s", buf );
}

static void do_delete( void )
{
    const struct row *r = &g_row[g_sel];
    const char *text = !strcmp( r->type, "primary" )
        ? "If you delete this partition, all data stored on it will be lost.\n\nDelete it?"
        : "This partition might contain files another operating system or the PC's manufacturer needs "
          "to start the PC or to recover it. If you delete it, all data stored on it will be lost.\n\nDelete it?";
    if (MessageBoxA( g_main, text, "Stained Glass OS Setup", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 ) != IDOK) return;
    operate( "DELETE %s", r->path );
}

static void do_format( void )
{
    if (MessageBoxA( g_main, "If you format this partition, all data stored on it will be lost.\n\nFormat it?",
                     "Stained Glass OS Setup", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 ) != IDOK) return;
    operate( "FORMAT %s", g_row[g_sel].path );
}

static void do_apply_new( void )
{
    const struct row *r = &g_row[g_sel];
    char mb[32];
    unsigned long long bytes;

    GetWindowTextA( g_size, mb, sizeof(mb) );
    bytes = _strtoui64( mb, NULL, 10 ) * 1024 * 1024;
    if (!bytes) { set_status( "Enter a size in MB.", TRUE ); return; }
    if (!r->disk_has_esp &&
        MessageBoxA( g_main, "To ensure that all of its features work correctly, Stained Glass OS might create "
                     "additional partitions for system files.", "Stained Glass OS Setup",
                     MB_OKCANCEL | MB_ICONINFORMATION ) != IDOK)
        return;
    g_after_new = TRUE;
    set_new_mode( FALSE );
    operate( "NEW %s\t%llu\t%llu", r->disk, r->start, bytes );
}

static void op_answer( const char *line )
{
    g_busy = FALSE;
    if (!strncmp( line, "FAILED ", 7 ))
    {
        g_after_new = FALSE;
        MessageBoxA( g_main, line + 7, "Stained Glass OS Setup", MB_OK | MB_ICONERROR );
    }
    request_layout();
}

/* --- pages ------------------------------------------------------------------- */

static void set_page( enum page p )
{
    BOOL disk = p == P_DISK, acct = p == P_ACCOUNT, welcome = p == P_WELCOME;
    char size[32], name[128];

    g_page = p;
    g_armed = 0;
    log_line( "sg-setup: page %s", page_names[p] );
    g_status[0] = 0;
    g_status_err = FALSE;
    g_body[0] = 0;
    KillTimer( g_main, TIMER_RESTART );

    show( g_lang, welcome ); show( g_locale, welcome ); show( g_kbd, welcome );
    show( g_install, p == P_START ); show( g_try, p == P_START && !g_windowed );
    show( g_lictext, p == P_LICENSE ); show( g_accept, p == P_LICENSE );
    show( g_upgrade, p == P_TYPE ); show( g_custom, p == P_TYPE ); show( g_drivers, p == P_TYPE );
    show( g_name, acct ); show( g_account, acct ); show( g_pass, acct ); show( g_pass2, acct ); show( g_host, acct );
    show( g_disks, disk ); show( g_refresh, disk ); show( g_delete, disk ); show( g_format, disk ); show( g_new, disk );
    if (!disk) { g_new_mode = FALSE; }
    show( g_size, disk && g_new_mode ); show( g_apply, disk && g_new_mode ); show( g_cancel, disk && g_new_mode );
    show( g_back, p >= P_LICENSE && p <= P_READY );
    show( g_left, p == P_FAILED );
    show( g_next, p == P_WELCOME || p == P_LICENSE || p == P_ACCOUNT || p == P_DISK || p == P_READY ||
                  p == P_DONE || p == P_FAILED );
    EnableWindow( g_next, TRUE );
    EnableWindow( g_back, TRUE );
    EnableWindow( g_close, p != P_INSTALLING && p != P_DONE );

    switch (p)
    {
    case P_WELCOME:
        g_heading[0] = 0;
        strcpy( g_body, "Enter your language and other preferences and select \"Next\" to continue." );
        SetWindowTextA( g_next, "&Next" );
        SetFocus( g_next );
        break;
    case P_START:
        g_heading[0] = 0;
        SetFocus( g_install );
        break;
    case P_LICENSE:
        strcpy( g_heading, "Applicable notices and license terms" );
        SetWindowTextA( g_next, "&Next" );
        EnableWindow( g_next, SendMessageA( g_accept, BM_GETCHECK, 0, 0 ) == BST_CHECKED );
        SetFocus( g_accept );
        break;
    case P_TYPE:
        strcpy( g_heading, "Which type of installation do you want?" );
        if (!g_drivers_listed && !g_listing)
        {
            g_drivers_listing = TRUE;
            g_found[0] = 0;
            send_line( "DRIVERS" );
        }
        SetFocus( g_custom );
        break;
    case P_ACCOUNT:
        strcpy( g_heading, "Who's going to use this PC?" );
        strcpy( g_body, "This account will be the PC's administrator. You'll sign in with it after Setup restarts the PC." );
        SetWindowTextA( g_next, "&Next" );
        SetFocus( g_name );
        break;
    case P_DISK:
        strcpy( g_heading, "Where do you want to install Stained Glass OS?" );
        SetWindowTextA( g_next, "&Next" );
        set_new_mode( FALSE );
        request_layout();
        SetFocus( g_disks );
        break;
    case P_READY:
        g_chosen_row = g_row[g_sel];
        row_name( &g_chosen_row, name, sizeof(name) );
        size_text( g_chosen_row.bytes, size, sizeof(size) );
        strcpy( g_heading, "Ready to install" );
        if (g_chosen_row.kind == R_FREE)
            snprintf( g_body, sizeof(g_body),
                      "Stained Glass OS will be installed to %s (%s). Setup will create the partitions it needs "
                      "there%s.\n\nNothing else on this PC's drives will change.",
                      name, size, g_chosen_row.disk_has_esp ? "" : ", including a system partition" );
        else
            snprintf( g_body, sizeof(g_body),
                      "Stained Glass OS will be installed to %s (%s).\n\n"
                      "THIS PARTITION WILL BE FORMATTED. EVERYTHING ON IT WILL BE ERASED.\n\n"
                      "Nothing else on this PC's drives will change.", name, size );
        {
            size_t n = strlen( g_body );
            snprintf( g_body + n, sizeof(g_body) - n, "\n\nThird-party drivers: %s",
                      SendMessageA( g_drivers, BM_GETCHECK, 0, 0 ) == BST_CHECKED
                      ? "what this PC needs is installed from Debian's non-free archive when it first starts."
                      : "not installed. The open-source drivers are used." );
        }
        SetWindowTextA( g_next, "&Install" );
        /* Focus on Back: the destructive button is never the one a stray key
         * lands on. */
        SetFocus( g_back );
        break;
    case P_INSTALLING:
        strcpy( g_heading, "Installing Stained Glass OS" );
        g_percent = 0;
        SetFocus( g_main );
        break;
    case P_DONE:
        strcpy( g_heading, "Stained Glass OS needs to restart to continue" );
        g_countdown = 15;
        SetWindowTextA( g_next, "&Restart now" );
        /* With a key to enroll, the owner must have time to note the password:
         * no countdown. */
        if (!g_mok[0]) SetTimer( g_main, TIMER_RESTART, 1000, NULL );
        SetFocus( g_next );
        break;
    case P_FAILED:
        strcpy( g_heading, "Stained Glass OS couldn't be installed" );
        SetWindowTextA( g_next, "&Start over" );
        SetWindowTextA( g_left, g_windowed ? "&Close" : "S&hut down" );
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
           strcmp( s, "daemon" ) && strcmp( s, "sguser" ) && strcmp( s, "live" ) &&
           strcmp( s, "sggreet" ) && strcmp( s, "sgrdp" );
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
    if (strchr( name, '\t' ) || strchr( name, ':' )) { set_status( "The name cannot contain a tab or ':'.", TRUE ); return FALSE; }
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
        set_status( pass[0] ? "The passwords don't match." : "Choose a password.", TRUE );
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
    char name[128], account[64], pass[256], host[64], target[128];

    GetWindowTextA( g_name, name, sizeof(name) );
    GetWindowTextA( g_account, account, sizeof(account) );
    GetWindowTextA( g_host, host, sizeof(host) );
    GetWindowTextA( g_pass, pass, sizeof(pass) );
    if (g_chosen_row.kind == R_FREE)
        snprintf( target, sizeof(target), "free:%s:%llu:%llu", g_chosen_row.disk, g_chosen_row.start, g_chosen_row.sectors );
    else
        snprintf( target, sizeof(target), "part:%s", g_chosen_row.path );
    set_page( P_INSTALLING );
    send_line( "INSTALL %s\t%s\t%s\t%s\t%s\t%d", target, account, host, name, g_kbd_code,
               SendMessageA( g_drivers, BM_GETCHECK, 0, 0 ) == BST_CHECKED );
    send_line( "PASSWORD %s", pass );
    /* Not kept here, and not in the controls either. */
    SecureZeroMemory( pass, sizeof(pass) );
    SetWindowTextA( g_pass, "" );
    SetWindowTextA( g_pass2, "" );
}

static void go_next( void )
{
    LRESULT k;

    switch (g_page)
    {
    case P_WELCOME:
        k = SendMessageA( g_kbd, CB_GETCURSEL, 0, 0 );
        if (k >= 0 && k < (LRESULT)(sizeof(g_layouts) / sizeof(g_layouts[0])))
            snprintf( g_kbd_code, sizeof(g_kbd_code), "%s", g_layouts[k].code );
        set_page( P_START );
        break;
    case P_START: set_page( P_LICENSE ); break;
    case P_LICENSE:
        if (SendMessageA( g_accept, BM_GETCHECK, 0, 0 ) == BST_CHECKED) set_page( P_TYPE );
        break;
    case P_TYPE: set_page( P_ACCOUNT ); break;
    case P_ACCOUNT: if (account_page_done()) set_page( P_DISK ); break;
    case P_DISK:
        if (g_new_mode) { do_apply_new(); break; }
        if (IsWindowEnabled( g_next ) && g_sel >= 0) set_page( P_READY );
        break;
    case P_READY: start_install(); break;
    case P_INSTALLING: break;
    case P_DONE:
        KillTimer( g_main, TIMER_RESTART );
        set_status( "Restarting...", FALSE );
        EnableWindow( g_next, FALSE );
        send_line( "REBOOT" );
        break;
    case P_FAILED: set_page( g_windowed ? P_LICENSE : P_WELCOME ); break;
    }
}

static void go_back( void )
{
    switch (g_page)
    {
    case P_LICENSE: set_page( P_START ); break;
    case P_TYPE: set_page( P_LICENSE ); break;
    case P_ACCOUNT: set_page( P_TYPE ); break;
    case P_DISK: if (g_new_mode) set_new_mode( FALSE ); else if (!g_busy) set_page( P_ACCOUNT ); break;
    case P_READY: set_page( P_DISK ); break;
    case P_START: set_page( P_WELCOME ); break;
    default: break;
    }
}

static void shut_down( void )
{
    if (MessageBoxA( g_main, "Shut down this PC?", "Stained Glass OS Setup",
                     MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 ) != IDYES) return;
    set_status( "Shutting down...", FALSE );
    send_line( "POWEROFF" );
}

static void cancel_setup( void )
{
    if (g_page == P_INSTALLING || g_page == P_DONE) return;
    if (MessageBoxA( g_main, "Are you sure you want to cancel Stained Glass OS installation?",
                     "Stained Glass OS Setup", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 ) != IDYES) return;
    if (g_windowed) DestroyWindow( g_main );
    else set_page( P_WELCOME );
}

static void handle_line( char *line )
{
    if (g_drivers_listing && !strncmp( line, "DEVICE ", 7 ))
    {
        char *f[6];
        size_t n = strlen( g_found );
        if (split_tabs( line + 7, f, 5 ) >= 5 && n < sizeof(g_found) - 80)
            snprintf( g_found + n, sizeof(g_found) - n, "%s%s (%s)", n ? ", " : "", f[2],
                      !strcmp( f[3], "-" ) ? "open-source driver" : strstr( f[3], "nvidia-" ) || strstr( f[3], "broadcom-sta" )
                      ? "the manufacturer's driver" : "firmware" );
        return;
    }
    if (g_drivers_listing && !strcmp( line, "END" ))
    {
        g_drivers_listing = FALSE;
        g_drivers_listed = TRUE;
        log_line( "sg-setup: drivers %s", g_found[0] ? g_found : "none" );
        InvalidateRect( g_main, NULL, FALSE );
        return;
    }
    if (!strncmp( line, "MOKPASSWORD ", 12 ))
    {
        snprintf( g_mok, sizeof(g_mok), "%s", line + 12 );
        return;
    }
    if (g_listing && (!strncmp( line, "DISK ", 5 ) || !strncmp( line, "PART ", 5 ) || !strncmp( line, "FREE ", 5 )))
        layout_line( line );
    else if (g_listing && !strcmp( line, "END" ))
        layout_done();
    else if (g_busy && (!strcmp( line, "OK" ) || !strncmp( line, "FAILED ", 7 )))
        op_answer( line );
    else if (!strncmp( line, "PROGRESS ", 9 ) && g_page == P_INSTALLING)
    {
        char *text = strchr( line + 9, ' ' );
        g_percent = atoi( line + 9 );
        if (g_percent < 0) g_percent = 0;
        if (g_percent > 100) g_percent = 100;
        set_status( text ? text + 1 : "", FALSE );
    }
    else if (!strcmp( line, "DONE" ) && g_page == P_INSTALLING)
        set_page( P_DONE );
    else if (!strncmp( line, "FAILED ", 7 ))
    {
        g_listing = FALSE;
        log_line( "sg-setup: failed: %s", line + 7 );
        set_page( P_FAILED );
        snprintf( g_body, sizeof(g_body), "%s", line + 7 );
        InvalidateRect( g_main, NULL, TRUE );
    }
}

/* --- drawing ----------------------------------------------------------------- */

static int X( int x ) { return g_rc.left + x; }
static int Y( int y ) { return g_rc.top + (g_windowed ? 0 : CAP_H) + y; }

static void fill( HDC dc, int l, int t, int r, int b, COLORREF c )
{
    RECT rc = { l, t, r, b };
    HBRUSH br = CreateSolidBrush( c );
    FillRect( dc, &rc, br );
    DeleteObject( br );
}

/* The mark: four panes of coloured glass around a point. */
static void draw_logo( HDC dc, int cx, int cy, int size )
{
    static const COLORREF colors[4] = { RGB(0x7B, 0x3F, 0xD6), RGB(0xE0, 0x3E, 0x8C), RGB(0xF2, 0x9D, 0x2E), RGB(0x1F, 0xB5, 0xAD) };
    int h = size / 4, gap = size / 24 + 1, i;
    HPEN pen = CreatePen( PS_NULL, 0, 0 ), oldp = SelectObject( dc, pen );

    for (i = 0; i < 4; i++)
    {
        /* top, right, bottom, left diamonds */
        int dx = i == 1 ? h + gap : i == 3 ? -(h + gap) : 0;
        int dy = i == 0 ? -(h + gap) : i == 2 ? h + gap : 0;
        POINT p[4] = { { cx + dx, cy + dy - h }, { cx + dx + h, cy + dy }, { cx + dx, cy + dy + h }, { cx + dx - h, cy + dy } };
        HBRUSH br = CreateSolidBrush( colors[i] ), oldb = SelectObject( dc, br );
        Polygon( dc, p, 4 );
        SelectObject( dc, oldb );
        DeleteObject( br );
    }
    SelectObject( dc, oldp );
    DeleteObject( pen );
}

/* The full-screen backdrop: dark glass panes, leaded, over a blue to violet
 * gradient. Drawn once. */
static unsigned int g_seed = 0x5eed1e55;
static int rnd( int n ) { g_seed = g_seed * 1103515245 + 12345; return (int)((g_seed >> 16) % (unsigned)n); }

static COLORREF shade( int y, int h, int dr, int dg, int db )
{
    int t = h ? y * 256 / h : 0, r, g, b;
    r = 0x0E + (0x34 - 0x0E) * t / 256 + dr;
    g = 0x1A + (0x10 - 0x1A) * t / 256 + dg;
    b = 0x52 + (0x5E - 0x52) * t / 256 + db;
    r = r < 0 ? 0 : r > 255 ? 255 : r; g = g < 0 ? 0 : g > 255 ? 255 : g; b = b < 0 ? 0 : b > 255 ? 255 : b;
    return RGB(r, g, b);
}

static void build_backdrop( HDC ref, int w, int h )
{
    enum { CELL = 150 };
    int cols = w / CELL + 2, rows = h / CELL + 2, i, j;
    POINT *v = malloc( sizeof(POINT) * cols * rows );
    HDC dc = CreateCompatibleDC( ref );
    HPEN lead = CreatePen( PS_SOLID, 3, RGB(0x07, 0x08, 0x1A) ), oldp;
    HBITMAP oldbm;

    g_backdrop = CreateCompatibleBitmap( ref, w, h );
    oldbm = SelectObject( dc, g_backdrop );
    oldp = SelectObject( dc, lead );
    for (j = 0; j < rows; j++)
        for (i = 0; i < cols; i++)
        {
            v[j * cols + i].x = i * CELL - CELL / 2 + (i && i < cols - 1 ? rnd( CELL / 2 ) - CELL / 4 : 0);
            v[j * cols + i].y = j * CELL - CELL / 2 + (j && j < rows - 1 ? rnd( CELL / 2 ) - CELL / 4 : 0);
        }
    for (j = 0; j + 1 < rows; j++)
        for (i = 0; i + 1 < cols; i++)
        {
            POINT a = v[j * cols + i], b = v[j * cols + i + 1], c = v[(j + 1) * cols + i + 1], d = v[(j + 1) * cols + i];
            POINT t1[3] = { a, b, (i + j) & 1 ? c : d }, t2[3] = { (i + j) & 1 ? a : b, c, d };
            int k;
            for (k = 0; k < 2; k++)
            {
                POINT *t = k ? t2 : t1;
                int cy = (t[0].y + t[1].y + t[2].y) / 3, accent = rnd( 9 ), dr = rnd( 17 ) - 8, dg = rnd( 13 ) - 6, db = rnd( 21 ) - 10;
                HBRUSH br, oldb;
                if (accent == 0) { dr += 26; db += 14; }          /* a violet pane */
                else if (accent == 1) { dg += 18; db += 10; dr -= 6; } /* a teal one */
                else if (accent == 2) { dr += 30; dg -= 4; }       /* a rose one */
                br = CreateSolidBrush( shade( cy, h, dr, dg, db ) );
                oldb = SelectObject( dc, br );
                Polygon( dc, t, 3 );
                SelectObject( dc, oldb );
                DeleteObject( br );
            }
        }
    SelectObject( dc, oldp );
    SelectObject( dc, oldbm );
    DeleteObject( lead );
    DeleteDC( dc );
    free( v );
}

static void text_at( HDC dc, HFONT font, COLORREF color, int l, int t, int r, int b, const char *s, UINT fmt )
{
    RECT rc = { l, t, r, b };
    SelectObject( dc, font );
    SetTextColor( dc, color );
    DrawTextA( dc, s, -1, &rc, fmt );
}

static void draw_warning_icon( HDC dc, int x, int y )
{
    POINT p[3] = { { x + 8, y }, { x + 16, y + 15 }, { x, y + 15 } };
    HBRUSH br = CreateSolidBrush( RGB(0xF2, 0xB7, 0x05) ), oldb = SelectObject( dc, br );
    HPEN pen = CreatePen( PS_SOLID, 1, RGB(0xB0, 0x80, 0x00) ), oldp = SelectObject( dc, pen );
    Polygon( dc, p, 3 );
    SelectObject( dc, oldb ); SelectObject( dc, oldp );
    DeleteObject( br ); DeleteObject( pen );
    text_at( dc, g_font_bold, RGB(0, 0, 0), x, y + 2, x + 16, y + 15, "!", DT_CENTER | DT_SINGLELINE );
}

static void draw_steps( HDC dc )
{
    BOOL installing = g_page >= P_INSTALLING && g_page != P_FAILED;
    int bar = g_page == P_INSTALLING ? g_percent : g_page == P_DONE ? 100 : 0;
    char n1[] = "1", n2[] = "2";

    if (g_page < P_LICENSE) return;
    text_at( dc, installing ? g_font : g_font_bold, installing ? COL_SUBTLE : COL_TEXT,
             X( 24 ), Y( CH - 44 ), X( 40 ), Y( CH - 20 ), n1, DT_SINGLELINE );
    text_at( dc, installing ? g_font : g_font_bold, installing ? COL_SUBTLE : COL_TEXT,
             X( 44 ), Y( CH - 44 ), X( 300 ), Y( CH - 20 ), "Collecting information", DT_SINGLELINE );
    text_at( dc, installing ? g_font_bold : g_font, installing ? COL_TEXT : COL_SUBTLE,
             X( 310 ), Y( CH - 44 ), X( 330 ), Y( CH - 20 ), n2, DT_SINGLELINE );
    text_at( dc, installing ? g_font_bold : g_font, installing ? COL_TEXT : COL_SUBTLE,
             X( 330 ), Y( CH - 44 ), X( 620 ), Y( CH - 20 ), "Installing Stained Glass OS", DT_SINGLELINE );
    fill( dc, X( 0 ), Y( CH - 8 ), X( CW ), Y( CH ), COL_TRACK );
    /* Collecting information fills the first part; installing the rest. */
    fill( dc, X( 0 ), Y( CH - 8 ), X( installing ? 300 + (CW - 300) * bar / 100 : 300 * ((int)g_page - (int)P_LICENSE + 1) / 5 ),
          Y( CH ), COL_BAR );
}

static void draw_install_steps( HDC dc )
{
    static const struct { const char *text; int lo, hi; } steps[] = {
        { "Copying Stained Glass OS files", 0, 60 },
        { "Getting files ready for installation", 60, 75 },
        { "Installing features", 75, 85 },
        { "Setting up your account", 85, 95 },
        { "Finishing up", 95, 100 },
    };
    int i, y = 110;
    char line[160];

    text_at( dc, g_font, COL_SUBTLE, X( 52 ), Y( 60 ), X( CW - 40 ), Y( 84 ), "Status", DT_SINGLELINE );
    for (i = 0; i < 5; i++, y += 32)
    {
        BOOL done = g_page == P_DONE || g_percent >= steps[i].hi;
        BOOL now = !done && g_percent >= steps[i].lo;
        if (now)
        {
            int pct = (g_percent - steps[i].lo) * 100 / (steps[i].hi - steps[i].lo);
            snprintf( line, sizeof(line), "%s (%d%%)", steps[i].text, pct );
        }
        else snprintf( line, sizeof(line), "%s", steps[i].text );
        if (done)
        {
            HPEN pen = CreatePen( PS_SOLID, 2, RGB(0x10, 0x7C, 0x10) ), oldp = SelectObject( dc, pen );
            MoveToEx( dc, X( 58 ), Y( y + 10 ), NULL ); LineTo( dc, X( 63 ), Y( y + 15 ) ); LineTo( dc, X( 72 ), Y( y + 4 ) );
            SelectObject( dc, oldp ); DeleteObject( pen );
        }
        text_at( dc, now ? g_font_bold : g_font, done || now ? COL_TEXT : COL_SUBTLE,
                 X( 84 ), Y( y ), X( CW - 40 ), Y( y + 24 ), line, DT_SINGLELINE );
    }
}

static void paint( HWND hwnd )
{
    PAINTSTRUCT ps;
    HDC wdc = BeginPaint( hwnd, &ps ), dc;
    RECT client;
    HBITMAP bm, oldbm;
    int hx;

    GetClientRect( hwnd, &client );
    dc = CreateCompatibleDC( wdc );
    bm = CreateCompatibleBitmap( wdc, client.right, client.bottom );
    oldbm = SelectObject( dc, bm );
    SetBkMode( dc, TRANSPARENT );

    if (!g_windowed)
    {
        HDC bdc = CreateCompatibleDC( wdc );
        HBITMAP old;
        if (!g_backdrop) build_backdrop( wdc, client.right, client.bottom );
        old = SelectObject( bdc, g_backdrop );
        BitBlt( dc, 0, 0, client.right, client.bottom, bdc, 0, 0, SRCCOPY );
        SelectObject( bdc, old );
        DeleteDC( bdc );
        /* the window: a shadow, a frame, a caption */
        fill( dc, g_rc.left + 6, g_rc.top + 8, g_rc.right + 6, g_rc.bottom + 8, RGB(0x05, 0x05, 0x12) );
        fill( dc, g_rc.left - 1, g_rc.top - 1, g_rc.right + 1, g_rc.bottom + 1, RGB(0x4A, 0x3A, 0x7A) );
        fill( dc, g_rc.left, g_rc.top, g_rc.right, g_rc.bottom, COL_WIN );
        fill( dc, g_rc.left, g_rc.top + CAP_H - 1, g_rc.right, g_rc.top + CAP_H, COL_CAPLINE );
        draw_logo( dc, g_rc.left + 18, g_rc.top + 16, 18 );
        text_at( dc, g_font_small, COL_TEXT, g_rc.left + 36, g_rc.top, g_rc.right - 60, g_rc.top + CAP_H,
                 "Stained Glass OS Setup", DT_SINGLELINE | DT_VCENTER );
    }
    else fill( dc, 0, 0, client.right, client.bottom, COL_WIN );

    hx = IsWindowVisible( g_back ) ? 56 : 40;
    if (g_heading[0])
        text_at( dc, g_font_head, COL_TEXT, X( hx ), Y( 14 ), X( CW - 30 ), Y( 50 ), g_heading,
                 DT_SINGLELINE | DT_END_ELLIPSIS );

    switch (g_page)
    {
    case P_WELCOME:
        draw_logo( dc, X( CW / 2 - 150 ), Y( 86 ), 64 );
        text_at( dc, g_font_logo, COL_TEXT, X( CW / 2 - 100 ), Y( 60 ), X( CW - 20 ), Y( 116 ), "Stained Glass OS", DT_SINGLELINE );
        text_at( dc, g_font, COL_TEXT, X( 60 ), Y( 184 ), X( 350 ), Y( 208 ), "Language to install:", DT_SINGLELINE | DT_RIGHT );
        text_at( dc, g_font, COL_TEXT, X( 60 ), Y( 234 ), X( 350 ), Y( 258 ), "Time and currency format:", DT_SINGLELINE | DT_RIGHT );
        text_at( dc, g_font, COL_TEXT, X( 60 ), Y( 284 ), X( 350 ), Y( 308 ), "Keyboard or input method:", DT_SINGLELINE | DT_RIGHT );
        text_at( dc, g_font, COL_SUBTLE, X( 60 ), Y( 350 ), X( CW - 60 ), Y( 400 ), g_body, DT_WORDBREAK | DT_CENTER );
        text_at( dc, g_font_small, COL_SUBTLE, X( 24 ), Y( CH - 40 ), X( CW - 200 ), Y( CH - 12 ),
                 "Stained Glass OS is free software. \xA9 2026 Stained Glass OS contributors.", DT_SINGLELINE );
        break;
    case P_START:
        draw_logo( dc, X( CW / 2 - 150 ), Y( 150 ), 72 );
        text_at( dc, g_font_logo, COL_TEXT, X( CW / 2 - 96 ), Y( 122 ), X( CW - 20 ), Y( 180 ), "Stained Glass OS", DT_SINGLELINE );
        break;
    case P_TYPE:
    {
        char found[640];
        text_at( dc, g_font, COL_SUBTLE, X( 64 ), Y( 360 ), X( CW - 40 ), Y( 400 ),
                 "Drivers such as NVIDIA's, and firmware for graphics and Wi-Fi, from Debian's non-free archive: "
                 "installed when this PC first starts, if it needs them.", DT_WORDBREAK );
        if (g_drivers_listed)
            snprintf( found, sizeof(found), "%s%s", g_found[0] ? "This PC has: " : "",
                      g_found[0] ? g_found : "This PC doesn't appear to need any." );
        else snprintf( found, sizeof(found), "Looking at this PC's devices..." );
        text_at( dc, g_font, COL_TEXT, X( 64 ), Y( 402 ), X( CW - 40 ), Y( 440 ), found, DT_WORDBREAK | DT_END_ELLIPSIS );
        break;
    }
    case P_ACCOUNT:
        text_at( dc, g_font, COL_SUBTLE, X( 40 ), Y( 56 ), X( CW - 40 ), Y( 100 ), g_body, DT_WORDBREAK );
        text_at( dc, g_font, COL_TEXT, X( 40 ), Y( 112 ), X( 380 ), Y( 134 ), "Your name", DT_SINGLELINE );
        text_at( dc, g_font, COL_TEXT, X( 420 ), Y( 112 ), X( 760 ), Y( 134 ), "Account name", DT_SINGLELINE );
        text_at( dc, g_font, COL_TEXT, X( 40 ), Y( 182 ), X( 380 ), Y( 204 ), "Password", DT_SINGLELINE );
        text_at( dc, g_font, COL_TEXT, X( 420 ), Y( 182 ), X( 760 ), Y( 204 ), "Confirm password", DT_SINGLELINE );
        text_at( dc, g_font, COL_TEXT, X( 40 ), Y( 252 ), X( 380 ), Y( 274 ), "PC name", DT_SINGLELINE );
        break;
    case P_DISK:
        if (g_new_mode)
        {
            text_at( dc, g_font, COL_TEXT, X( 430 ), Y( 350 ), X( 480 ), Y( 374 ), "Size:", DT_SINGLELINE );
            text_at( dc, g_font, COL_TEXT, X( 588 ), Y( 350 ), X( 620 ), Y( 374 ), "MB", DT_SINGLELINE );
        }
        break;
    case P_READY:
        text_at( dc, g_font_bold, COL_TEXT, X( 56 ), Y( 70 ), X( CW - 56 ), Y( 300 ), g_body, DT_WORDBREAK );
        break;
    case P_INSTALLING:
    case P_DONE:
        if (g_page == P_INSTALLING) draw_install_steps( dc );
        else
        {
            char buf[128];
            snprintf( buf, sizeof(buf), "Restarting in %d second%s", g_countdown, g_countdown == 1 ? "" : "s" );
            if (!g_mok[0]) text_at( dc, g_font, COL_TEXT, X( 56 ), Y( 70 ), X( CW - 56 ), Y( 96 ), buf, DT_SINGLELINE );
            if (g_mok[0])
            {
                char pw[64];
                text_at( dc, g_font, COL_TEXT, X( 56 ), Y( 70 ), X( CW - 56 ), Y( 250 ),
                         "Secure Boot is on, so this PC's drivers need its key. Enroll it once, when the PC restarts:\n\n"
                         "1. A blue screen appears. Press a key.\n"
                         "2. Choose \"Enroll MOK\", then \"Continue\", then \"Yes\".\n"
                         "3. Type the password below, then choose \"Reboot\".\n\n"
                         "Remove the installation media first. Restart when you've written the password down.",
                         DT_WORDBREAK );
                snprintf( pw, sizeof(pw), "Password:  %.4s %s", g_mok, g_mok + (strlen( g_mok ) > 4 ? 4 : strlen( g_mok )) );
                text_at( dc, g_font_logo, COL_TEXT, X( 56 ), Y( 262 ), X( CW - 56 ), Y( 320 ), pw, DT_SINGLELINE );
            }
            else
            {
                text_at( dc, g_font, COL_SUBTLE, X( 56 ), Y( 104 ), X( CW - 56 ), Y( 150 ),
                         "Remove the installation media. You'll sign in with the account you created.", DT_WORDBREAK );
                fill( dc, X( 56 ), Y( 160 ), X( CW - 56 ), Y( 166 ), COL_TRACK );
                fill( dc, X( 56 ), Y( 160 ), X( 56 + (CW - 112) * (15 - g_countdown) / 15 ), Y( 166 ), COL_BAR );
            }
        }
        break;
    case P_FAILED:
        text_at( dc, g_font, COL_ERR, X( 40 ), Y( 70 ), X( CW - 40 ), Y( 300 ), g_body, DT_WORDBREAK );
        break;
    default:
        break;
    }

    if (g_status[0] && g_page != P_INSTALLING)   /* the steps say it; the journal has the detail */
    {
        int sy = g_page == P_DISK ? 396 : g_page == P_ACCOUNT ? 330 : g_page == P_INSTALLING ? 290 : 420;
        int sx = X( g_page == P_INSTALLING ? 84 : 40 );
        if (g_status_err && g_page == P_DISK) { draw_warning_icon( dc, sx, Y( sy + 2 ) ); sx += 24; }
        text_at( dc, g_font, g_status_err ? (g_page == P_DISK ? COL_TEXT : COL_ERR) : COL_SUBTLE,
                 sx, Y( sy ), X( CW - 40 ), Y( sy + 48 ), g_status, DT_WORDBREAK );
    }
    draw_steps( dc );

    BitBlt( wdc, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY );
    SelectObject( dc, oldbm );
    DeleteObject( bm );
    DeleteDC( dc );
    EndPaint( hwnd, &ps );
}

/* Owner-drawn controls: link-style commands, the two installation types, the
 * big Install now button, the back arrow, and the caption and power buttons. */
static void draw_item( const DRAWITEMSTRUCT *d )
{
    HDC dc = d->hDC;
    RECT r = d->rcItem;
    BOOL dis = (d->itemState & ODS_DISABLED) != 0, focus = (d->itemState & ODS_FOCUS) != 0;
    BOOL down = (d->itemState & ODS_SELECTED) != 0;
    char text[256];

    GetWindowTextA( d->hwndItem, text, sizeof(text) );
    SetBkMode( dc, TRANSPARENT );
    switch (d->CtlID)
    {
    case ID_INSTALL:
    {
        HBRUSH br = CreateSolidBrush( down ? RGB(0x3E, 0x1A, 0x80) : RGB(0x5B, 0x2A, 0xA8) );
        FillRect( dc, &r, br ); DeleteObject( br );
        SelectObject( dc, g_font_big ); SetTextColor( dc, RGB(0xFF, 0xFF, 0xFF) );
        DrawTextA( dc, text, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE );
        if (focus) { RECT f = r; InflateRect( &f, -3, -3 ); SetTextColor( dc, 0 ); DrawFocusRect( dc, &f ); }
        break;
    }
    case ID_UPGRADE:
    case ID_CUSTOM:
    {
        RECT t = r;
        const char *title = d->CtlID == ID_UPGRADE ? "Upgrade: Keep files, settings, and applications"
                                                   : "Custom: Install Stained Glass OS only (advanced)";
        const char *desc = d->CtlID == ID_UPGRADE
            ? "Not available. Stained Glass OS can't upgrade Windows, and an installed Stained Glass OS "
              "keeps itself up to date with its own updates."
            : "Choose where to install it: into unallocated space, beside Windows or another system, or onto "
              "a partition you format. You can create, delete and format partitions on the next page.";
        HBRUSH br = CreateSolidBrush( down ? RGB(0xE4, 0xDE, 0xF0) : COL_OPTION );
        FillRect( dc, &r, br ); DeleteObject( br );
        t.left += 20; t.top += 14; t.right -= 20;
        SelectObject( dc, g_font_big ); SetTextColor( dc, dis ? COL_DIS : COL_TEXT );
        DrawTextA( dc, title, -1, &t, DT_SINGLELINE );
        t.top += 34;
        SelectObject( dc, g_font ); SetTextColor( dc, dis ? COL_DIS : COL_SUBTLE );
        DrawTextA( dc, desc, -1, &t, DT_WORDBREAK );
        if (focus) { RECT f = r; InflateRect( &f, -3, -3 ); DrawFocusRect( dc, &f ); }
        break;
    }
    case ID_BACK:
    {
        HPEN pen = CreatePen( PS_SOLID, 2, dis ? COL_DIS : COL_TEXT ), oldp;
        int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        FillRect( dc, &r, down ? (HBRUSH)GetStockObject( LTGRAY_BRUSH ) : g_win_brush );
        oldp = SelectObject( dc, pen );
        MoveToEx( dc, cx + 8, cy, NULL ); LineTo( dc, cx - 8, cy );
        MoveToEx( dc, cx - 2, cy - 6, NULL ); LineTo( dc, cx - 8, cy ); LineTo( dc, cx - 2, cy + 6 );
        SelectObject( dc, oldp ); DeleteObject( pen );
        if (focus) { RECT f = r; InflateRect( &f, -2, -2 ); DrawFocusRect( dc, &f ); }
        break;
    }
    case ID_CLOSE:
    {
        HPEN pen = CreatePen( PS_SOLID, 1, dis ? COL_DIS : COL_TEXT ), oldp;
        int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        HBRUSH br = CreateSolidBrush( down ? RGB(0xE8, 0x11, 0x23) : COL_WIN );
        FillRect( dc, &r, br ); DeleteObject( br );
        oldp = SelectObject( dc, pen );
        MoveToEx( dc, cx - 5, cy - 5, NULL ); LineTo( dc, cx + 6, cy + 6 );
        MoveToEx( dc, cx + 5, cy - 5, NULL ); LineTo( dc, cx - 6, cy + 6 );
        SelectObject( dc, oldp ); DeleteObject( pen );
        break;
    }
    case ID_POWER:
    {
        HPEN pen = CreatePen( PS_SOLID, 2, RGB(0xFF, 0xFF, 0xFF) ), oldp;
        int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        HBRUSH br = CreateSolidBrush( down ? RGB(0x40, 0x30, 0x70) : RGB(0x1A, 0x16, 0x40) );
        FillRect( dc, &r, br ); DeleteObject( br );
        oldp = SelectObject( dc, pen );
        SelectObject( dc, GetStockObject( NULL_BRUSH ) );
        Arc( dc, cx - 9, cy - 8, cx + 9, cy + 10, cx - 5, cy - 7, cx + 5, cy - 7 );
        MoveToEx( dc, cx, cy - 11, NULL ); LineTo( dc, cx, cy + 1 );
        SelectObject( dc, oldp ); DeleteObject( pen );
        break;
    }
    default:    /* links */
    {
        LOGFONTA lf;
        HFONT ul;
        FillRect( dc, &r, g_win_brush );
        GetObjectA( g_font, sizeof(lf), &lf );
        lf.lfUnderline = focus;
        ul = CreateFontIndirectA( &lf );
        SelectObject( dc, ul );
        SetTextColor( dc, dis ? COL_DIS : COL_LINK );
        DrawTextA( dc, text, -1, &r, DT_SINGLELINE | DT_VCENTER | DT_LEFT );
        SelectObject( dc, g_font );
        DeleteObject( ul );
        if (focus) DrawFocusRect( dc, &r );
        break;
    }
    }
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_PAINT: paint( hwnd ); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_CTLCOLORSTATIC:
        SetBkColor( (HDC)wp, COL_WIN );
        SetTextColor( (HDC)wp, COL_TEXT );
        return (LRESULT)g_win_brush;
    case WM_DRAWITEM: draw_item( (const DRAWITEMSTRUCT *)lp ); return TRUE;
    case WM_NOTIFY:
    {
        const NMHDR *h = (const NMHDR *)lp;
        if (h->idFrom == ID_DISKS && h->code == LVN_ITEMCHANGED)
        {
            const NMLISTVIEW *lv = (const NMLISTVIEW *)lp;
            if ((lv->uNewState & LVIS_SELECTED) && !(lv->uOldState & LVIS_SELECTED) && lv->iItem != g_sel)
            {
                char name[128];
                g_sel = lv->iItem;
                if (g_sel >= 0 && g_sel < g_nrows)
                {
                    row_name( &g_row[g_sel], name, sizeof(name) );
                    log_line( "sg-setup: selected %s", name );
                }
                if (g_new_mode) set_new_mode( FALSE );
                update_disk_buttons();
            }
        }
        else if (h->idFrom == ID_DISKS && h->code == NM_DBLCLK && IsWindowEnabled( g_next )) go_next();
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case ID_NEXT: go_next(); break;
        case ID_BACK: go_back(); break;
        case ID_LEFT:
            if (g_page != P_FAILED) break;
            if (g_windowed) DestroyWindow( hwnd ); else shut_down();
            break;
        case ID_INSTALL: if (g_page == P_START) set_page( P_LICENSE ); break;
        case ID_TRY:
            if (g_page == P_START && !g_windowed)
            {
                log_line( "sg-setup: try" );
                send_line( "TRY" );
                DestroyWindow( hwnd );
            }
            break;
        case ID_ACCEPT:
            if (HIWORD(wp) == BN_CLICKED)
                EnableWindow( g_next, SendMessageA( g_accept, BM_GETCHECK, 0, 0 ) == BST_CHECKED );
            break;
        case ID_CUSTOM: if (g_page == P_TYPE) set_page( P_ACCOUNT ); break;
        case ID_REFRESH: if (!g_busy && !g_listing) { set_new_mode( FALSE ); request_layout(); } break;
        case ID_DELETE: if (!g_busy && g_sel >= 0) do_delete(); break;
        case ID_FORMAT: if (!g_busy && g_sel >= 0) do_format(); break;
        case ID_NEW: if (!g_busy && g_sel >= 0 && g_row[g_sel].kind == R_FREE) set_new_mode( TRUE ); break;
        case ID_APPLY: if (g_new_mode) do_apply_new(); break;
        case ID_CANCEL: if (g_new_mode) set_new_mode( FALSE ); break;
        case ID_CLOSE: cancel_setup(); break;
        case ID_POWER: shut_down(); break;
        }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_RESTART && g_page == P_DONE)
        {
            if (--g_countdown <= 0) go_next();
            InvalidateRect( hwnd, NULL, FALSE );
        }
        return 0;
    case WM_CLOSE:
        if (g_windowed) { if (g_page == P_INSTALLING || g_page == P_DONE) return 0; cancel_setup(); return 0; }
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
        else DestroyWindow( hwnd );
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
    HWND c = CreateWindowExA( ex, cls, text, WS_CHILD | style, X( x ), Y( y ), w, h,
                              g_main, (HMENU)(INT_PTR)id, GetModuleHandleA( NULL ), NULL );
    SendMessageA( c, WM_SETFONT, (WPARAM)g_font, TRUE );
    return c;
}

/* The small drive icon of the partition list: a drive, drawn here. */
static HIMAGELIST make_drive_icons( void )
{
    HIMAGELIST il = ImageList_Create( 16, 22, ILC_COLOR24 | ILC_MASK, 1, 1 );
    HDC screen = GetDC( NULL ), dc = CreateCompatibleDC( screen );
    HBITMAP bm = CreateCompatibleBitmap( screen, 16, 22 ), old = SelectObject( dc, bm );
    HPEN pen = CreatePen( PS_SOLID, 1, RGB(0x5A, 0x5E, 0x68) ), oldp;
    HBRUSH body = CreateSolidBrush( RGB(0xB4, 0xB8, 0xC2) ), oldb;

    /* 22 high, the drive in the middle: rows as tall as Windows Setup's */
    fill( dc, 0, 0, 16, 22, RGB(0xFF, 0x00, 0xFF) );
    oldp = SelectObject( dc, pen );
    oldb = SelectObject( dc, body );
    RoundRect( dc, 0, 7, 16, 16, 3, 3 );
    fill( dc, 2, 8, 14, 9, RGB(0xE2, 0xE4, 0xEA) );
    fill( dc, 11, 12, 14, 14, RGB(0x2E, 0xB8, 0x4A) );
    SelectObject( dc, oldb ); SelectObject( dc, oldp ); SelectObject( dc, old );
    ImageList_AddMasked( il, bm, RGB(0xFF, 0x00, 0xFF) );
    DeleteObject( body ); DeleteObject( pen ); DeleteObject( bm );
    DeleteDC( dc );
    ReleaseDC( NULL, screen );
    return il;
}

/* Enter and Escape: act on release, for a press seen on this page. */
static BOOL handle_key( MSG *m )
{
    HWND focus;
    char cls[32];

    if (m->wParam != VK_RETURN && m->wParam != VK_ESCAPE) return FALSE;
    /* A combo box's open list takes its own keys. */
    focus = GetFocus();
    if (focus && GetClassNameA( focus, cls, sizeof(cls) ) && !strcmp( cls, "ComboBox" ) &&
        SendMessageA( focus, CB_GETDROPPEDSTATE, 0, 0 ))
        return FALSE;
    if (m->message == WM_KEYDOWN || m->message == WM_SYSKEYDOWN)
    {
        if (!(m->lParam & (1 << 30))) g_armed = m->wParam;   /* not auto-repeat */
        return TRUE;
    }
    if (m->message != WM_KEYUP && m->message != WM_SYSKEYUP) return FALSE;
    if (g_armed != m->wParam) return TRUE;
    g_armed = 0;
    if (m->wParam == VK_ESCAPE) { go_back(); return TRUE; }
    if (focus && GetClassNameA( focus, cls, sizeof(cls) ) && !strcmp( cls, "Button" ) && focus != g_accept &&
        focus != g_drivers &&
        IsWindowVisible( focus ) && IsWindowEnabled( focus ))
    {
        SendMessageA( focus, BM_CLICK, 0, 0 );
        return TRUE;
    }
    if (g_page == P_DISK && focus == g_size) { do_apply_new(); return TRUE; }
    if (g_page == P_START) { set_page( P_LICENSE ); return TRUE; }
    if (IsWindowVisible( g_next ) && IsWindowEnabled( g_next )) go_next();
    return TRUE;
}

/* Started from a shortcut rather than by the bridge: start the bridge, which
 * starts this again, windowed, with the installer service on its pipes. */
static int launch_through_bridge( void )
{
    WCHAR cmd[1024];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    HWND existing = FindWindowA( "SgSetup", NULL );

    memset( &si, 0, sizeof(si) );
    si.cb = sizeof(si);
    if (existing) { SetForegroundWindow( existing ); return 0; }
    /* Through systemd-cat, so its page log reaches the journal (tag
     * sg-setup) as it does from the login screen. */
    lstrcpyW( cmd, L"\"\\\\?\\unix\\usr\\bin\\systemd-cat\" -t sg-setup "
                   L"/usr/libexec/stained-glass/sg-setup-bridge "
                   L"\"wine /usr/libexec/stained-glass/sg-setup64.exe --windowed\"" );
    if (!CreateProcessW( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
    {
        MessageBoxA( NULL, "Setup can't start: the installer is not available. Setup runs from the "
                     "Stained Glass OS installation media.", "Stained Glass OS Setup", MB_OK | MB_ICONERROR );
        return 1;
    }
    CloseHandle( pi.hThread );
    CloseHandle( pi.hProcess );
    return 0;
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show_cmd )
{
    INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES };
    WNDCLASSA wc = {0};
    LVCOLUMNA col = {0};
    MSG msg;
    int sw, sh, i;
    DWORD style = WS_CHILD | WS_TABSTOP;

    (void)prev; (void)show_cmd;
    g_windowed = cmdline && strstr( cmdline, "--windowed" ) != NULL;
    if (!GetEnvironmentVariableA( "SG_SETUP_BRIDGED", NULL, 0 )) return launch_through_bridge();

    g_in  = GetStdHandle( STD_INPUT_HANDLE );
    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    InitCommonControlsEx( &icc );

    g_font_small = make_font( 15, FW_NORMAL );
    g_font_title = make_font( 22, FW_SEMIBOLD );
    g_font_head  = make_font( 26, FW_NORMAL );
    g_font       = make_font( 17, FW_NORMAL );
    g_font_bold  = make_font( 17, FW_SEMIBOLD );
    g_font_big   = make_font( 20, FW_SEMIBOLD );
    g_font_logo  = make_font( 44, FW_LIGHT );
    g_win_brush  = CreateSolidBrush( COL_WIN );

    wc.lpfnWndProc   = wndproc;
    wc.hInstance     = inst;
    wc.hCursor       = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.hIcon         = LoadIconA( inst, MAKEINTRESOURCEA( 1 ) );
    wc.lpszClassName = "SgSetup";
    RegisterClassA( &wc );

    if (g_windowed)
    {
        RECT r = { 0, 0, CW, CH };
        DWORD ws = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
        AdjustWindowRect( &r, ws, FALSE );
        SetRect( &g_rc, 0, 0, CW, CH );
        g_main = CreateWindowExA( 0, "SgSetup", "Stained Glass OS Setup", ws, CW_USEDEFAULT, CW_USEDEFAULT,
                                  r.right - r.left, r.bottom - r.top, NULL, NULL, inst, NULL );
    }
    else
    {
        sw = GetSystemMetrics( SM_CXSCREEN );
        sh = GetSystemMetrics( SM_CYSCREEN );
        SetRect( &g_rc, (sw - WIN_W) / 2, (sh - WIN_H) / 2, (sw + WIN_W) / 2, (sh + WIN_H) / 2 );
        if (g_rc.top < 0) OffsetRect( &g_rc, 0, -g_rc.top );
        if (g_rc.left < 0) OffsetRect( &g_rc, -g_rc.left, 0 );
        g_main = CreateWindowExA( 0, "SgSetup", "Stained Glass OS Setup", WS_POPUP | WS_CLIPCHILDREN,
                                  0, 0, sw, sh, NULL, NULL, inst, NULL );
    }

    /* Creation order is tab order: Back first, then the page, then Next. */
    g_back = child( "BUTTON", "Back", style | BS_OWNERDRAW, 0, 10, 12, 36, 36, ID_BACK );
    g_lang = child( "COMBOBOX", "", style | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 370, 180, 300, 200, ID_LANG );
    g_locale = child( "COMBOBOX", "", style | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 370, 230, 300, 200, ID_LOCALE );
    g_kbd = child( "COMBOBOX", "", style | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 370, 280, 300, 240, ID_KBD );
    SendMessageA( g_lang, CB_ADDSTRING, 0, (LPARAM)"English (United States)" );
    SendMessageA( g_lang, CB_SETCURSEL, 0, 0 );
    SendMessageA( g_locale, CB_ADDSTRING, 0, (LPARAM)"English (United States)" );
    SendMessageA( g_locale, CB_SETCURSEL, 0, 0 );
    for (i = 0; i < (int)(sizeof(g_layouts) / sizeof(g_layouts[0])); i++)
        SendMessageA( g_kbd, CB_ADDSTRING, 0, (LPARAM)g_layouts[i].name );
    SendMessageA( g_kbd, CB_SETCURSEL, 0, 0 );
    g_install = child( "BUTTON", "Install now", style | BS_OWNERDRAW, 0, CW / 2 - 100, 250, 200, 48, ID_INSTALL );
    g_try = child( "BUTTON", "Try Stained Glass OS without installing it", style | BS_OWNERDRAW, 0,
                   24, CH - 50, 400, 26, ID_TRY );
    g_lictext = child( "EDIT", g_license, style | ES_MULTILINE | ES_READONLY | WS_VSCROLL | ES_AUTOVSCROLL,
                       WS_EX_CLIENTEDGE, 40, 60, CW - 80, 330, ID_LICTEXT );
    g_accept = child( "BUTTON", "I accept the license terms", style | BS_AUTOCHECKBOX, 0, 40, 400, 400, 26, ID_ACCEPT );
    g_upgrade = child( "BUTTON", "Upgrade", style | BS_OWNERDRAW | WS_DISABLED, 0, 40, 70, CW - 80, 118, ID_UPGRADE );
    g_custom = child( "BUTTON", "Custom", style | BS_OWNERDRAW, 0, 40, 200, CW - 80, 118, ID_CUSTOM );
    g_drivers = child( "BUTTON", "Install third-party drivers for graphics and Wi-Fi (recommended)",
                       style | BS_AUTOCHECKBOX, 0, 40, 330, CW - 80, 26, ID_DRIVERS );
    SendMessageA( g_drivers, BM_SETCHECK, BST_CHECKED, 0 );
    g_name = child( "EDIT", "", style | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, 40, 136, 340, 30, ID_NAME );
    g_account = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_LOWERCASE, WS_EX_CLIENTEDGE, 420, 136, 340, 30, ID_ACCOUNT );
    g_pass = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE, 40, 206, 340, 30, ID_PASS );
    g_pass2 = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE, 420, 206, 340, 30, ID_PASS2 );
    g_host = child( "EDIT", "stained-glass", style | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, 40, 276, 340, 30, ID_HOST );
    g_disks = child( WC_LISTVIEWA, "", style | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | LVS_NOSORTHEADER,
                     WS_EX_CLIENTEDGE, 40, 60, CW - 80, 270, ID_DISKS );
    SendMessageA( g_disks, LVM_SETEXTENDEDLISTVIEWSTYLE, LVS_EX_FULLROWSELECT, LVS_EX_FULLROWSELECT );
    SendMessageA( g_disks, LVM_SETIMAGELIST, LVSIL_SMALL, (LPARAM)make_drive_icons() );
    col.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_FMT;
    col.pszText = (char *)"Name"; col.cx = 330; col.fmt = LVCFMT_LEFT;
    SendMessageA( g_disks, LVM_INSERTCOLUMNA, 0, (LPARAM)&col );
    col.pszText = (char *)"Total size"; col.cx = 120; col.fmt = LVCFMT_RIGHT;
    SendMessageA( g_disks, LVM_INSERTCOLUMNA, 1, (LPARAM)&col );
    col.pszText = (char *)"Free space"; col.cx = 120;
    SendMessageA( g_disks, LVM_INSERTCOLUMNA, 2, (LPARAM)&col );
    col.pszText = (char *)"Type"; col.cx = 130; col.fmt = LVCFMT_LEFT;
    SendMessageA( g_disks, LVM_INSERTCOLUMNA, 3, (LPARAM)&col );
    g_refresh = child( "BUTTON", "Refresh", style | BS_OWNERDRAW, 0, 40, 346, 90, 26, ID_REFRESH );
    g_delete = child( "BUTTON", "Delete", style | BS_OWNERDRAW, 0, 140, 346, 90, 26, ID_DELETE );
    g_format = child( "BUTTON", "Format", style | BS_OWNERDRAW, 0, 240, 346, 90, 26, ID_FORMAT );
    g_new = child( "BUTTON", "New", style | BS_OWNERDRAW, 0, 340, 346, 70, 26, ID_NEW );
    g_size = child( "EDIT", "", style | ES_NUMBER | ES_RIGHT, WS_EX_CLIENTEDGE, 474, 346, 108, 28, ID_SIZE );
    g_apply = child( "BUTTON", "Apply", style | BS_OWNERDRAW, 0, 630, 346, 60, 26, ID_APPLY );
    g_cancel = child( "BUTTON", "Cancel", style | BS_OWNERDRAW, 0, 694, 346, 66, 26, ID_CANCEL );
    g_left = child( "BUTTON", "", style | BS_PUSHBUTTON, 0, 24, CH - 104, 130, 34, ID_LEFT );
    g_next = child( "BUTTON", "", style | BS_PUSHBUTTON, 0, CW - 24 - 130, CH - 104, 130, 34, ID_NEXT );
    if (!g_windowed)
    {
        g_close = CreateWindowExA( 0, "BUTTON", "", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, g_rc.right - 46, g_rc.top,
                                   46, CAP_H - 1, g_main, (HMENU)(INT_PTR)ID_CLOSE, inst, NULL );
        g_power = CreateWindowExA( 0, "BUTTON", "", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                   GetSystemMetrics( SM_CXSCREEN ) - 72, GetSystemMetrics( SM_CYSCREEN ) - 72,
                                   48, 48, g_main, (HMENU)(INT_PTR)ID_POWER, inst, NULL );
    }

    ShowWindow( g_main, SW_SHOW );
    set_page( P_WELCOME );
    UpdateWindow( g_main );
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
