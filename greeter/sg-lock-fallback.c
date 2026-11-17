/* The lock screen's fallback: when the lock UI (the Wine greeter, sg-lock-ui)
 * cannot start or keeps dying -- a Wine that does not match its server after
 * an upgrade ("version mismatch"), a prefix it cannot open -- sg-lockd starts
 * this instead, so the person can always reach a password prompt, as
 * Windows' LogonUI always comes back. Nothing about the lock changes: it runs
 * on the lock screen's own X server (sg-lock-ui), speaks the same line protocol
 * on stdin/stdout, and sg-lockd still checks the password with PAM and is the
 * only one that sends UNLOCK. This program never unlocks anything itself.
 *
 *   -> HELLO                  <- PROMPT_SECRET <text>
 *   -> REPLY <password>       <- SUCCESS | FAILURE <text>
 *   (security screen, /sas:)  -> SAS cancel | SAS lock
 *
 * Plain Xlib and the X server's built-in "fixed" font, drawn scaled: no
 * toolkit or font library that an upgrade half-done could break too.
 *
 *   sg-lock-fallback /lock|/sas USER
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <errno.h>
#include <locale.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXPW 256

static Display *dpy;
static Window win;
static GC gc;
static XFontStruct *font;
static int W, H, scale = 2;
static int sas;
static char user[128], prompt[256] = "Password", message[256];
static char pw[MAXPW];
static size_t pwlen;
static int prompted;

static unsigned long rgb( int r, int g, int b )
{
    XColor c = { .red = r * 257, .green = g * 257, .blue = b * 257, .flags = DoRed | DoGreen | DoBlue };
    XAllocColor( dpy, DefaultColormap( dpy, DefaultScreen( dpy ) ), &c );
    return c.pixel;
}

/* text drawn with the built-in font, each pixel a scale x scale square */
static int text_width( const char *s )
{
    return XTextWidth( font, s, (int)strlen( s ) ) * scale;
}

static void draw_text( int x, int y, const char *s, unsigned long fg, unsigned long bg )
{
    int w = XTextWidth( font, s, (int)strlen( s ) ), h = font->ascent + font->descent;
    Pixmap p;
    XImage *img;
    GC pgc;

    if (w <= 0) return;
    p = XCreatePixmap( dpy, win, (unsigned)w, (unsigned)h, (unsigned)DefaultDepth( dpy, DefaultScreen( dpy ) ) );
    pgc = XCreateGC( dpy, p, 0, NULL );
    XSetFont( dpy, pgc, font->fid );
    XSetForeground( dpy, pgc, bg );
    XFillRectangle( dpy, p, pgc, 0, 0, (unsigned)w, (unsigned)h );
    XSetForeground( dpy, pgc, fg );
    XDrawString( dpy, p, pgc, 0, font->ascent, s, (int)strlen( s ) );
    img = XGetImage( dpy, p, 0, 0, (unsigned)w, (unsigned)h, AllPlanes, ZPixmap );
    if (img)
    {
        XSetForeground( dpy, gc, fg );
        for (int j = 0; j < h; j++)
            for (int i = 0; i < w; i++)
                if (XGetPixel( img, i, j ) == fg)
                    XFillRectangle( dpy, win, gc, x + i * scale, y + j * scale, (unsigned)scale, (unsigned)scale );
        XDestroyImage( img );
    }
    XFreeGC( dpy, pgc );
    XFreePixmap( dpy, p );
}

static void centred( int y, const char *s, unsigned long fg, unsigned long bg )
{
    draw_text( (W - text_width( s )) / 2, y, s, fg, bg );
}

static void redraw( void )
{
    unsigned long bg = rgb( 0x2a, 0x1b, 0x4d ), fg = rgb( 0xff, 0xff, 0xff ), dim = rgb( 0xc8, 0xc0, 0xdc );
    unsigned long box = rgb( 0xff, 0xff, 0xff ), ink = rgb( 0x20, 0x20, 0x20 ), err = rgb( 0xff, 0xc0, 0xc0 );
    int lh = (font->ascent + font->descent) * scale, y = H / 2 - 3 * lh;
    char dots[MAXPW + 1];
    int bw = W / 3 > 24 * lh ? 24 * lh / 2 : W / 3, bx = (W - bw) / 2;

    XSetForeground( dpy, gc, bg );
    XFillRectangle( dpy, win, gc, 0, 0, (unsigned)W, (unsigned)H );
    centred( y, user, fg, bg );
    y += lh * 2;
    if (sas)
    {
        centred( y, "Press Enter to lock this computer,", fg, bg );
        centred( y + lh, "or Esc to go back.", fg, bg );
    }
    else
    {
        centred( y, prompted ? prompt : "Starting...", dim, bg );
        y += lh + lh / 2;
        XSetForeground( dpy, gc, box );
        XFillRectangle( dpy, win, gc, bx, y, (unsigned)bw, (unsigned)(lh + lh / 2) );
        memset( dots, '*', pwlen > MAXPW ? MAXPW : pwlen );
        dots[pwlen > MAXPW ? MAXPW : pwlen] = 0;
        draw_text( bx + lh / 2, y + lh / 4, dots, ink, box );
        y += lh * 3;
        if (message[0]) centred( y, message, err, bg );
    }
    centred( H - 3 * lh, "The lock screen could not start; this is its simple stand-in.", dim, bg );
    XFlush( dpy );
}

static void say( const char *line )
{
    size_t n = strlen( line ), off = 0;
    while (off < n)
    {
        ssize_t r = write( 1, line + off, n - off );
        if (r < 0) { if (errno == EINTR) continue; exit( 1 ); }
        off += (size_t)r;
    }
}

/* a line from sg-lockd */
static void heard( char *line )
{
    if (!strncmp( line, "PROMPT_SECRET ", 14 ))
    {
        snprintf( prompt, sizeof(prompt), "%.200s", line + 14 );
        prompted = 1;
    }
    else if (!strncmp( line, "FAILURE", 7 ))
        snprintf( message, sizeof(message), "%.200s", line[7] ? line + 8 : "Not unlocked." );
    else if (!strcmp( line, "SUCCESS" ))
        exit( 0 );
    redraw();
}

static void key( XKeyEvent *ev, XIC ic )
{
    char buf[64];
    KeySym ks = NoSymbol;
    Status st;
    int n = Xutf8LookupString( ic, ev, buf, sizeof(buf) - 1, &ks, &st );

    if (sas)
    {
        if (ks == XK_Escape) say( "SAS cancel\n" );
        else if (ks == XK_Return || ks == XK_KP_Enter || ks == XK_l || ks == XK_L) say( "SAS lock\n" );
        return;
    }
    if (ks == XK_Return || ks == XK_KP_Enter)
    {
        char line[MAXPW + 8];
        if (!prompted) return;
        snprintf( line, sizeof(line), "REPLY %.*s\n", (int)pwlen, pw );
        say( line );
        explicit_bzero( line, sizeof(line) );
        explicit_bzero( pw, sizeof(pw) );
        pwlen = 0;
        message[0] = 0;
    }
    else if (ks == XK_BackSpace)
    {
        while (pwlen > 0 && (pw[pwlen - 1] & 0xc0) == 0x80) pwlen--;   /* a whole UTF-8 character */
        if (pwlen > 0) pwlen--;
        pw[pwlen] = 0;
    }
    else if (ks == XK_Escape)
    {
        explicit_bzero( pw, sizeof(pw) );
        pwlen = 0;
    }
    else if ((st == XLookupChars || st == XLookupBoth) && n > 0 && (unsigned char)buf[0] >= 0x20
             && pwlen + (size_t)n < MAXPW - 1)
    {
        memcpy( pw + pwlen, buf, (size_t)n );
        pwlen += (size_t)n;
        pw[pwlen] = 0;
    }
    explicit_bzero( buf, sizeof(buf) );
    redraw();
}

int main( int argc, char **argv )
{
    XSetWindowAttributes wa = { 0 };
    Atom state, fs;
    XIM im;
    XIC ic;
    char line[1024];
    size_t have = 0;

    if (argc < 3) { fprintf( stderr, "usage: %s /lock|/sas USER\n", argv[0] ); return 2; }
    sas = !strcmp( argv[1], "/sas" );
    snprintf( user, sizeof(user), "%s", argv[2] );
    setlocale( LC_CTYPE, "" );
    if (!setlocale( LC_CTYPE, NULL ) || !strcmp( setlocale( LC_CTYPE, NULL ), "C" )) setlocale( LC_CTYPE, "C.UTF-8" );
    XSetLocaleModifiers( "@im=none" );   /* no input method of the session's: keys go nowhere else */
    if (!(dpy = XOpenDisplay( NULL ))) { fprintf( stderr, "sg-lock-fallback: no display\n" ); return 1; }
    if (!(font = XLoadQueryFont( dpy, "fixed" ))) { fprintf( stderr, "sg-lock-fallback: no font\n" ); return 1; }
    W = DisplayWidth( dpy, DefaultScreen( dpy ) );
    H = DisplayHeight( dpy, DefaultScreen( dpy ) );
    scale = H / 360 > 1 ? H / 360 : 1;
    wa.background_pixel = rgb( 0x2a, 0x1b, 0x4d );
    wa.event_mask = ExposureMask | KeyPressMask | StructureNotifyMask | FocusChangeMask;
    win = XCreateWindow( dpy, DefaultRootWindow( dpy ), 0, 0, (unsigned)W, (unsigned)H, 0, CopyFromParent, InputOutput,
                         CopyFromParent, CWBackPixel | CWEventMask, &wa );
    XStoreName( dpy, win, sas ? "Security options" : "Sign in" );
    state = XInternAtom( dpy, "_NET_WM_STATE", False );
    fs = XInternAtom( dpy, "_NET_WM_STATE_FULLSCREEN", False );
    XChangeProperty( dpy, win, state, XA_ATOM, 32, PropModeReplace, (unsigned char *)&fs, 1 );
    gc = XCreateGC( dpy, win, 0, NULL );
    im = XOpenIM( dpy, NULL, NULL, NULL );
    ic = im ? XCreateIC( im, XNInputStyle, XIMPreeditNothing | XIMStatusNothing, XNClientWindow, win,
                         XNFocusWindow, win, NULL ) : NULL;
    if (!ic) { fprintf( stderr, "sg-lock-fallback: no input context\n" ); return 1; }
    XMapRaised( dpy, win );
    XSync( dpy, False );
    say( "HELLO\n" );

    for (;;)
    {
        struct pollfd pf[2] = { { ConnectionNumber( dpy ), POLLIN, 0 }, { 0, POLLIN, 0 } };
        while (XPending( dpy ))
        {
            XEvent ev;
            XNextEvent( dpy, &ev );
            if (ev.type == Expose && !ev.xexpose.count) redraw();
            else if (ev.type == MapNotify) XSetInputFocus( dpy, win, RevertToParent, CurrentTime );
            else if (ev.type == ConfigureNotify) { W = ev.xconfigure.width; H = ev.xconfigure.height; }
            else if (ev.type == KeyPress) key( &ev.xkey, ic );
        }
        if (poll( pf, 2, -1 ) < 0) { if (errno == EINTR) continue; return 1; }
        if (pf[1].revents)
        {
            ssize_t r = read( 0, line + have, sizeof(line) - 1 - have );
            if (r <= 0) return 0;   /* sg-lockd is gone: so is this */
            have += (size_t)r;
            line[have] = 0;
            for (char *nl; (nl = memchr( line, '\n', have ));)
            {
                *nl = 0;
                heard( line );
                have -= (size_t)(nl + 1 - line);
                memmove( line, nl + 1, have );
                line[have] = 0;
            }
            if (have == sizeof(line) - 1) have = 0;
        }
    }
}
