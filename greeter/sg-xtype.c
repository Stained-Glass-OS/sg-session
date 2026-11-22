/* sg-xtype: type into the X window that has the focus, through XTEST.
 *
 * The touch keyboard (sg-shell's sg-touchkbd) is a Wine program: its key
 * presses (SendInput) reach Wine's windows only. A Linux program's window
 * (inside its Wine frame, SgLinuxWindow) has the X focus itself; for it the
 * keyboard starts this, which presses the keys on the X server the session
 * runs on (DISPLAY), as a hardware keyboard would.
 *
 *   sg-xtype TOKEN...
 *     u:XXXX      the character U+XXXX
 *     k:NAME      the key of that keysym name (BackSpace, Return, Tab, Left)
 *     ctrl+TOKEN  with Ctrl held
 *
 * A character no key of the layout gives is typed through a spare key code
 * mapped to it for the moment, and the map is put back. Refuses DISPLAY :0
 * when SG_XTYPE_TEST is set (gates).
 *
 * The map goes back late, not 150 ms after the key: a program reads a key's
 * symbol from the map as the server has it when the program gets round to the
 * key press -- after a mapping change it fetches the map again, lazily. A
 * program slower than that (any program, under load: "no eacute" in make
 * lint) found the spare key empty again and saw nothing. So the spare keys in
 * use are listed on the root window (_SG_XTYPE_SPARE: a generation, then the
 * key codes), and a detached child of the last sg-xtype to use one empties
 * them all REVERT_MS later -- unless a later sg-xtype has taken over the list.
 * A key code already mapped to the character by an earlier run is simply
 * typed again.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>

static void press( Display *d, KeyCode code, int down )
{
    XTestFakeKeyEvent( d, code, down, CurrentTime );
}

/* the key for KEYSYM, and whether Shift goes with it; 0 when none */
static KeyCode find_key( Display *d, KeySym sym, int *shift )
{
    KeyCode code = XKeysymToKeycode( d, sym );
    *shift = 0;
    if (!code) return 0;
    if (XkbKeycodeToKeysym( d, code, 0, 0 ) == sym) return code;
    if (XkbKeycodeToKeysym( d, code, 0, 1 ) == sym) { *shift = 1; return code; }
    return 0;
}

#define REVERT_MS 2000
#define MAX_SPARE 64

/* the spare key codes this run mapped */
static KeyCode g_spare[MAX_SPARE];
static int g_nspare;

/* a key code with nothing on it, for a character the layout lacks */
static KeyCode spare_key( Display *d )
{
    int min, max, per, k, j;
    KeySym *map;
    KeyCode found = 0;

    XDisplayKeycodes( d, &min, &max );
    map = XGetKeyboardMapping( d, min, max - min + 1, &per );
    if (!map) return 0;
    for (k = max; k >= min && !found; k--)
    {
        int empty = 1;
        for (j = 0; j < per; j++) if (map[(k - min) * per + j] != NoSymbol) empty = 0;
        if (empty) found = k;
    }
    XFree( map );
    return found;
}

#ifndef SG_MUTANT_XTYPE_REVERT_AT_ONCE
/* _SG_XTYPE_SPARE on the root window: generation, key code... ; returns the count of codes */
static int read_spare_list( Display *d, Atom prop, unsigned long *gen, KeyCode *codes, int max )
{
    Atom type;
    int format, n = 0;
    unsigned long count, after, i;
    unsigned char *data = NULL;

    *gen = 0;
    if (XGetWindowProperty( d, DefaultRootWindow( d ), prop, 0, MAX_SPARE * 2 + 1, False, XA_CARDINAL, &type, &format,
                            &count, &after, &data ) == Success && data && type == XA_CARDINAL && format == 32 && count)
    {
        unsigned long *v = (unsigned long *)data;
        *gen = v[0] & 0xffffffffu;   /* format 32 comes as a long, sign-extended */
        for (i = 1; i < count && n < max; i++) codes[n++] = (KeyCode)(v[i] & 0xff);
    }
    if (data) XFree( data );
    return n;
}

/* list this run's spare keys with any an earlier run left mapped, under a new generation; a child
 * empties them all after REVERT_MS unless a later run has written the list again */
static void revert_spare_later( Display *d )
{
    Atom prop = XInternAtom( d, "_SG_XTYPE_SPARE", False );
    KeyCode codes[MAX_SPARE * 2];
    unsigned long v[MAX_SPARE * 2 + 1], gen, old;
    int n, i, j;
    struct timespec ts;

    XGrabServer( d );
    n = read_spare_list( d, prop, &old, codes, MAX_SPARE );
    for (i = 0; i < g_nspare; i++)
    {
        for (j = 0; j < n && codes[j] != g_spare[i]; j++) ;
        if (j == n && n < MAX_SPARE) codes[n++] = g_spare[i];
    }
    clock_gettime( CLOCK_MONOTONIC, &ts );
    gen = ((unsigned long)ts.tv_sec * 1000003u + (unsigned long)ts.tv_nsec / 1000 + (unsigned long)getpid()) & 0xffffffffu;
    if (!gen || gen == old) gen = old + 1;
    v[0] = gen;
    for (i = 0; i < n; i++) v[i + 1] = codes[i];
    XChangeProperty( d, DefaultRootWindow( d ), prop, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)v, n + 1 );
    XUngrabServer( d );
    XSync( d, False );

    if (fork() == 0)
    {
        Display *c;
        unsigned long now;
        KeyCode list[MAX_SPARE];
        int m;

        setsid();
        signal( SIGHUP, SIG_IGN );
        close( ConnectionNumber( d ) );   /* the parent's connection is the parent's */
        usleep( REVERT_MS * 1000 );
        if (!(c = XOpenDisplay( NULL ))) _exit( 0 );
        /* its own atom: the server may have reset meanwhile (no clients left), and then the
         * keyboard map is the server's own again anyway */
        prop = XInternAtom( c, "_SG_XTYPE_SPARE", False );
        XGrabServer( c );
        m = read_spare_list( c, prop, &now, list, MAX_SPARE );
        if (now == gen)
        {
            KeySym none[2] = { NoSymbol, NoSymbol };
            for (i = 0; i < m; i++) XChangeKeyboardMapping( c, list[i], 2, none, 1 );
            XDeleteProperty( c, DefaultRootWindow( c ), prop );
        }
        XUngrabServer( c );
        XCloseDisplay( c );
        _exit( 0 );
    }
}
#endif

static void type_sym( Display *d, KeySym sym, int ctrl )
{
    KeyCode shift_code = XKeysymToKeycode( d, XK_Shift_L ), ctrl_code = XKeysymToKeycode( d, XK_Control_L );
    int shift;
    KeyCode code = find_key( d, sym, &shift );

    if (ctrl) press( d, ctrl_code, True );
    if (code)
    {
        if (shift) press( d, shift_code, True );
        press( d, code, True );
        press( d, code, False );
        if (shift) press( d, shift_code, False );
    }
#ifndef SG_MUTANT_XTYPE_NO_SPARE
    else if ((code = spare_key( d )))
    {
        KeySym syms[2] = { sym, sym };
        XChangeKeyboardMapping( d, code, 2, syms, 1 );
        XSync( d, False );
        usleep( 50000 );    /* the programs have heard of the new map */
        press( d, code, True );
        press( d, code, False );
        XSync( d, False );
        if (g_nspare < MAX_SPARE) g_spare[g_nspare++] = code;
    }
#endif
    if (ctrl) press( d, ctrl_code, False );
    XSync( d, False );
}

int main( int argc, char **argv )
{
    const char *disp = getenv( "DISPLAY" );
    int ev, err, major, minor, i;
    Display *d;

    if (!disp || (getenv( "SG_XTYPE_TEST" ) && !strcmp( disp, ":0" ))) return 2;
    if (!(d = XOpenDisplay( NULL ))) return 2;
    if (!XTestQueryExtension( d, &ev, &err, &major, &minor )) return 3;
    for (i = 1; i < argc; i++)
    {
        const char *t = argv[i];
        int ctrl = 0;
        KeySym sym = NoSymbol;

        if (!strncmp( t, "ctrl+", 5 )) { ctrl = 1; t += 5; }
        if (!strncmp( t, "u:", 2 ))
        {
            unsigned long cp = strtoul( t + 2, NULL, 16 );
            sym = cp < 0x100 ? (KeySym)cp : (KeySym)(0x1000000 | cp);
        }
        else if (!strncmp( t, "k:", 2 )) sym = XStringToKeysym( t + 2 );
        if (sym != NoSymbol) type_sym( d, sym, ctrl );
    }
#ifndef SG_MUTANT_XTYPE_REVERT_AT_ONCE
    if (g_nspare) revert_spare_later( d );
#else
    if (g_nspare)
    {
        KeySym none[2] = { NoSymbol, NoSymbol };
        usleep( 150000 );
        for (i = 0; i < g_nspare; i++) XChangeKeyboardMapping( d, g_spare[i], 2, none, 1 );
    }
#endif
    XCloseDisplay( d );
    return 0;
}
