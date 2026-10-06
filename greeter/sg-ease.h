/* sg-ease.h: Ease of Access on the screens before anyone signs in -- the
 * login and lock screens (sg-greeter), the consent prompt (sg-consent),
 * Setup and the first-run setup (sg-setup, sg-oobe).
 *
 * A computer without a keyboard (a Surface without its Type Cover) could not
 * sign in: nothing on these screens brought up a keyboard. As on Windows:
 *
 *   - an Ease of Access button beside the power button, its menu turning
 *     the On-Screen Keyboard (sg-shell's sg-osk) and the touch keyboard
 *     (sg-touchkbd) on and off;
 *   - the touch keyboard running in the background from the start, so it
 *     shows itself when a text box (the password) is touched and no
 *     hardware keyboard is attached (wine-sg 1150 stamps the touch).
 *
 * The keyboards run in this screen's own Wine and X server -- the lock
 * screen's and the consent prompt's private, privileged ones (ADR 0009) --
 * so their key presses reach only this screen; they log nothing, use no
 * clipboard and write no typed text anywhere. They are in a job object that
 * ends them with this program (and sg_ease_stop ends them on the way out):
 * nothing of them outlives the screen.
 *
 * SG_SHELL_DIR: where sg-shell's programs are (Unix path, default
 * /usr/libexec/stained-glass/shell); without them the button is not shown.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef SG_EASE_H
#define SG_EASE_H

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "sg-smooth.h"

#define SG_EASE_OSK   0x7e01
#define SG_EASE_TOUCH 0x7e02

static HANDLE sg_ease_job;
static HANDLE sg_ease_procs[8];
static int sg_ease_nprocs;

/* a program of sg-shell's, as a path this Wine can start ("" if none) */
static void sg_ease_path( const char *exe, WCHAR *out, DWORD len )
{
    static WCHAR *(CDECL *to_dos)( const char * );
    const char *dir = getenv( "SG_SHELL_DIR" );
    char unix_path[MAX_PATH];
    WCHAR *dos;

    out[0] = 0;
    if (!to_dos) to_dos = (void *)GetProcAddress( GetModuleHandleA( "kernel32.dll" ), "wine_get_dos_file_name" );
    snprintf( unix_path, sizeof(unix_path), "%s/%s", dir && *dir ? dir : "/usr/libexec/stained-glass/shell", exe );
    if (!to_dos || !(dos = to_dos( unix_path ))) return;
    if (GetFileAttributesW( dos ) != INVALID_FILE_ATTRIBUTES) lstrcpynW( out, dos, len );
    HeapFree( GetProcessHeap(), 0, dos );
}

static BOOL sg_ease_available( void )
{
    WCHAR path[MAX_PATH];
#ifdef SG_MUTANT_NO_EASE
    return FALSE;
#endif
    sg_ease_path( "sg-osk64.exe", path, MAX_PATH );
    if (path[0]) return TRUE;
    sg_ease_path( "sg-touchkbd64.exe", path, MAX_PATH );
    return path[0] != 0;
}

/* start EXE with ARGS, in the job that ends it with this program */
static void sg_ease_run( const char *exe, const WCHAR *args )
{
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    WCHAR path[MAX_PATH], cmd[MAX_PATH * 2];

    memset( &si, 0, sizeof(si) );
    si.cb = sizeof(si);
    sg_ease_path( exe, path, MAX_PATH );
    if (!path[0]) return;
    if (!sg_ease_job)
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
        memset( &limits, 0, sizeof(limits) );
        sg_ease_job = CreateJobObjectW( NULL, NULL );
#ifndef SG_MUTANT_EASE_OUTLIVES
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
#endif
        if (sg_ease_job)
            SetInformationJobObject( sg_ease_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits) );
    }
    /* on this screen's own desktop (the consent prompt makes one) */
    {
        static WCHAR desk[128];
        DWORD n;
        HDESK d = GetThreadDesktop( GetCurrentThreadId() );
        if (d && GetUserObjectInformationW( d, UOI_NAME, desk, sizeof(desk), &n )) si.lpDesktop = desk;
    }
    _snwprintf( cmd, ARRAYSIZE(cmd), L"\"%ls\" %ls", path, args ? args : L"" );
    cmd[ARRAYSIZE(cmd) - 1] = 0;
    if (!CreateProcessW( path, cmd, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, NULL, &si, &pi )) return;
    if (sg_ease_job) AssignProcessToJobObject( sg_ease_job, pi.hProcess );
    ResumeThread( pi.hThread );
    CloseHandle( pi.hThread );
    if (sg_ease_nprocs < (int)ARRAYSIZE(sg_ease_procs)) sg_ease_procs[sg_ease_nprocs++] = pi.hProcess;
    else CloseHandle( pi.hProcess );
}

/* the keyboards end with this screen */
static void sg_ease_stop( void )
{
    int i;
#ifdef SG_MUTANT_EASE_OUTLIVES
    return;
#endif
    for (i = 0; i < sg_ease_nprocs; i++)
    {
        TerminateProcess( sg_ease_procs[i], 0 );
        CloseHandle( sg_ease_procs[i] );
    }
    sg_ease_nprocs = 0;
    if (sg_ease_job) CloseHandle( sg_ease_job );
    sg_ease_job = NULL;
}

/* at the start: the touch keyboard in the background, to show itself for a
 * touched text box with no keyboard attached (it ends at once on a computer
 * without a touch screen or pen) */
static void sg_ease_start( void )
{
    if (!sg_ease_available()) return;
    sg_ease_run( "sg-touchkbd64.exe", L"/background" );
    atexit( sg_ease_stop );
}

static HWND sg_ease_button( HWND parent, int x, int y, int size, int id, HINSTANCE inst )
{
    if (!sg_ease_available()) return NULL;
    return CreateWindowExA( 0, "BUTTON", "Ease of Access", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                            x, y, size, size, parent, (HMENU)(INT_PTR)id, inst, NULL );
}

/* the text box to type into after the menu (the button took the focus): a
 * visible password box first, else any visible text box */
static BOOL CALLBACK sg_ease_find_edit( HWND hwnd, LPARAM lp )
{
    HWND *found = (HWND *)lp;
    char cls[16];
    if (!IsWindowVisible( hwnd ) || !IsWindowEnabled( hwnd ) || !GetClassNameA( hwnd, cls, sizeof(cls) ) ||
        lstrcmpiA( cls, "Edit" ) || (GetWindowLongA( hwnd, GWL_STYLE ) & ES_READONLY)) return TRUE;
    if (GetWindowLongA( hwnd, GWL_STYLE ) & ES_PASSWORD) { found[0] = hwnd; return FALSE; }
    if (!found[1]) found[1] = hwnd;
    return TRUE;
}

static void sg_ease_refocus( HWND owner )
{
    HWND found[2] = { NULL, NULL };
    EnumChildWindows( owner, sg_ease_find_edit, (LPARAM)found );
    if (found[0] || found[1]) SetFocus( found[0] ? found[0] : found[1] );
}

/* the button's menu: the On-Screen Keyboard and the touch keyboard, each
 * turned on or off; then the text box has the focus again, to type into */
static void sg_ease_menu( HWND owner, HWND button )
{
    HMENU menu = CreatePopupMenu();
    HWND osk = FindWindowW( L"OSKMainClass", NULL ), tip = FindWindowW( L"IPTip_Main_Window", NULL );
    WCHAR path[MAX_PATH];
    RECT r;
    int cmd;

    sg_ease_path( "sg-osk64.exe", path, MAX_PATH );
    if (path[0])
        AppendMenuW( menu, MF_STRING | (osk && IsWindowVisible( osk ) ? MF_CHECKED : 0), SG_EASE_OSK,
                     L"&On-Screen Keyboard" );
    sg_ease_path( "sg-touchkbd64.exe", path, MAX_PATH );
    if (path[0])
        AppendMenuW( menu, MF_STRING | (tip && IsWindowVisible( tip ) ? MF_CHECKED : 0), SG_EASE_TOUCH,
                     L"&Touch keyboard" );
    GetWindowRect( button, &r );
    cmd = TrackPopupMenu( menu, TPM_RETURNCMD | TPM_RIGHTALIGN | TPM_BOTTOMALIGN | TPM_NONOTIFY,
                          r.right, r.top - 4, 0, owner, NULL );
    DestroyMenu( menu );
    if (cmd == SG_EASE_OSK)
    {
        if (osk) PostMessageW( osk, WM_CLOSE, 0, 0 );
        else sg_ease_run( "sg-osk64.exe", NULL );
    }
    else if (cmd == SG_EASE_TOUCH)
    {
        /* a running touch keyboard takes the command; else one starts shown */
        sg_ease_run( "sg-touchkbd64.exe", L"/toggle" );
    }
    sg_ease_refocus( owner );
}

/* the Ease of Access figure: a person in a circle, as Windows draws it */
static void sg_ease_draw( const DRAWITEMSTRUCT *di, COLORREF bg, COLORREF bg_down, COLORREF fg )
{
    HDC dc = di->hDC;
    RECT r = di->rcItem;
    BOOL down = (di->itemState & ODS_SELECTED) != 0;
    HPEN pen = CreatePen( PS_SOLID, 2, fg ), oldp;
    HBRUSH br = CreateSolidBrush( down ? bg_down : bg );
    int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2, s = (r.bottom - r.top) / 2 - 10;

    FillRect( dc, &r, br );
    DeleteObject( br );
    if (s < 6) s = 6;
    oldp = SelectObject( dc, pen );
    SelectObject( dc, GetStockObject( NULL_BRUSH ) );
    sg_ellipse( dc, cx - s, cy - s, cx + s, cy + s );                        /* the circle */
    sg_ellipse( dc, cx - s / 6, cy - s * 3 / 5, cx + s / 6, cy - s * 4 / 15 ); /* the head */
    sg_line( dc, cx - s / 2, cy - s / 6, cx + s / 2, cy - s / 6 );           /* the arms */
    sg_line( dc, cx, cy - s / 6, cx, cy + s / 4 );                           /* the body */
    sg_line( dc, cx, cy + s / 4, cx - s / 3, cy + s * 3 / 5 );               /* the legs */
    sg_line( dc, cx, cy + s / 4, cx + s / 3, cy + s * 3 / 5 );
    SelectObject( dc, oldp );
    DeleteObject( pen );
    if (di->itemState & ODS_FOCUS)
    {
        InflateRect( &r, -3, -3 );
        DrawFocusRect( dc, &r );
    }
}

#endif
