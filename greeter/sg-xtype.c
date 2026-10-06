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
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
        usleep( 150000 );   /* and read the key before it goes */
        syms[0] = syms[1] = NoSymbol;
        XChangeKeyboardMapping( d, code, 2, syms, 1 );
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
    XCloseDisplay( d );
    return 0;
}
