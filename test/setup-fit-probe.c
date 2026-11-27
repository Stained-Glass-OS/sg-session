/* test/setup-fit-gate.sh's probe (i0555): where windowed Setup's window is against the work area and the
 * taskbar. Lines: SETUP l t r b caption | WORK l t r b | MONITOR l t r b | TRAY 0/1 | HIT name x y root |
 * BUTTONS close 0/1 power 0/1 */
#include <windows.h>
#include <stdio.h>

#define ID_NEXT 301 /* sg-setup.c */

static void hit(const char *name, HWND setup, int x, int y)
{
    POINT pt = { x, y };
    HWND h = WindowFromPoint(pt), root = h ? GetAncestor(h, GA_ROOT) : NULL;
    char cls[64] = "";
    if (root) GetClassNameA(root, cls, sizeof(cls));
    printf("HIT %s %d %d %s\n", name, x, y, root == setup ? "setup" : (cls[0] ? cls : "none"));
}

int main(void)
{
    HWND setup = NULL, tray;
    RECT r, work;
    MONITORINFO mi = { sizeof(mi) };
    int i;

    for (i = 0; i < 300 && !(setup = FindWindowA("SgSetup", NULL)); i++) Sleep(100);
    if (!setup) { printf("SETUP none\n"); return 1; }
    Sleep(1500);
    GetWindowRect(setup, &r);
    printf("SETUP %ld %ld %ld %ld %d\n", r.left, r.top, r.right, r.bottom,
           (GetWindowLongA(setup, GWL_STYLE) & WS_CAPTION) == WS_CAPTION);
    SystemParametersInfoA(SPI_GETWORKAREA, 0, &work, 0);
    printf("WORK %ld %ld %ld %ld\n", work.left, work.top, work.right, work.bottom);
    GetMonitorInfoA(MonitorFromWindow(setup, MONITOR_DEFAULTTOPRIMARY), &mi);
    printf("MONITOR %ld %ld %ld %ld\n", mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right, mi.rcMonitor.bottom);
    tray = FindWindowA("Shell_TrayWnd", NULL);
    printf("TRAY %d %d\n", tray != NULL, tray && IsWindowVisible(tray));
    /* the bottom of Setup's window (its status row, Next) and the middle of it */
    hit("bottom", setup, (r.left + r.right) / 2, r.bottom - 6);
    {
        HWND next = GetDlgItem(setup, ID_NEXT);
        RECT n;
        if (next && GetWindowRect(next, &n)) hit("next", setup, (n.left + n.right) / 2, (n.top + n.bottom) / 2);
        else printf("HIT next 0 0 nobutton\n");
    }
    hit("middle", setup, (r.left + r.right) / 2, (r.top + r.bottom) / 2);
    /* windowed Setup's own buttons: Close in a full-screen layout, never Shut down (the full-screen
     * Setup of the live medium's sign-in screen) */
    printf("BUTTONS close %d power %d\n", GetDlgItem(setup, 326) != NULL, GetDlgItem(setup, 327) != NULL);
    fflush(stdout);
    return 0;
}
