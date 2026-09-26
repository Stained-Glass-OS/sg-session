/* Stained Glass OS first-run setup: the out-of-box experience (OOBE).
 *
 * At the first boot of an installed machine this takes the login screen's
 * place, full screen, as Windows' out-of-box experience comes before anyone
 * signs in: region, keyboard layout (and a second one), network, the owner's
 * account when Setup did not make one, privacy, and an optional web browser.
 * It is a Windows program for the same reason the login screen and Setup
 * are: remote-support tools can see and drive it. It decides nothing:
 * sg-setup-bridge --oobe passes what it asks for to sg-oobed, the root
 * service that checks and applies it.
 *
 * Protocol, line-based, on the pipes it was started with (sg-oobed has the
 * other end):
 *
 *   -> HELLO                 the window is up
 *   -> STATE                 <- KEYBOARD <layout>  ACCOUNT yes|no  ONLINE yes|no  END
 *   -> NETWORKS              <- WIRED <dev>\t<state>  WIFI ...  ONLINE yes|no  END
 *   -> CONNECT <ssid hex>\t<security>, KEY <key>   <- OK | FAILED <text>
 *   -> ACCOUNT <name>\t<full name>, PASSWORD <pw>  <- OK | FAILED <text>
 *   -> FINISH <locale>\t<geo>\t<layouts>\t<location>\t<microphone>\t<tailored>\t<advertising>\t<browser>
 *                            <- DONE | FAILED <text>
 *
 * Keys as in Setup: Tab moves; Enter presses the focused button, or elsewhere
 * the page's main button; Escape goes back; Enter and Escape act on release,
 * for a press seen on the same page. Each page change is logged to stderr
 * ("sg-oobe: page <name>"), and each list selection ("sg-oobe: selected
 * <text>"): the gates wait on them.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum page { P_REGION, P_KBD, P_KBD2, P_KBD2_PICK, P_NETWORK, P_ACCOUNT, P_PRIVACY, P_BROWSER, P_APPLY, P_DONE, P_FAILED };
static const char *const page_names[] = { "region", "keyboard", "second-keyboard", "second-keyboard-pick", "network",
                                          "account", "privacy", "browser", "applying", "done", "failed" };

#define ID_PRIMARY   401
#define ID_SECONDARY 402
#define ID_BACK      403
#define ID_LIST      404
#define ID_NAME      405
#define ID_PASS      406
#define ID_PASS2     407
#define ID_KEY       408
#define ID_TOGGLE    410    /* 410..413 */

#define WM_BRIDGE_LINE (WM_APP + 1)
#define WM_BRIDGE_EOF  (WM_APP + 2)
#define TIMER_CLOSE    1
#define TIMER_RESCAN   2

static const COLORREF COL_CARD    = RGB(0x22, 0x10, 0x42);
static const COLORREF COL_ART     = RGB(0x3A, 0x17, 0x6E);
static const COLORREF COL_TEXT    = RGB(0xFF, 0xFF, 0xFF);
static const COLORREF COL_SUBTLE  = RGB(0xC9, 0xBD, 0xE0);
static const COLORREF COL_DIM     = RGB(0x8E, 0x80, 0xA8);
static const COLORREF COL_LIST    = RGB(0x2D, 0x17, 0x55);
static const COLORREF COL_ACCENT  = RGB(0x7B, 0x2F, 0xBE);
static const COLORREF COL_ACCENT2 = RGB(0x9A, 0x5A, 0xD8);
static const COLORREF COL_ERR     = RGB(0xFF, 0x99, 0x99);

static HANDLE g_in, g_out;
static HWND g_main, g_primary, g_secondary, g_back, g_list, g_name, g_pass, g_pass2, g_key, g_toggle[4];
static HFONT g_font_head, g_font, g_font_bold, g_font_small, g_font_list, g_font_step;
static HBRUSH g_card_brush, g_list_brush;
static HBITMAP g_backdrop;
static RECT g_card, g_art, g_body;
static enum page g_page = P_REGION;
static WPARAM g_armed;
static char g_heading[160], g_text[600], g_status[256];
static BOOL g_status_err, g_busy, g_finished;

/* What the service told us, and what was chosen. */
static char g_setup_kbd[16] = "us";
static BOOL g_has_account = TRUE, g_online, g_state_known, g_region_touched;
static int g_region = -1, g_kbd = 0, g_kbd2 = -1, g_browser = 0;
static BOOL g_privacy[4] = { FALSE, TRUE, FALSE, FALSE };   /* location, microphone, tailored, advertising */

static const struct { const char *name, *locale, *kbd; } g_regions[] = {
    { "Australia", "en-AU", "us" }, { "Austria", "de-AT", "de" }, { "Belgium", "fr-BE", "be" },
    { "Brazil", "pt-BR", "br" }, { "Canada", "en-CA", "us" }, { "Czechia", "cs-CZ", "cz" },
    { "Denmark", "da-DK", "dk" }, { "Finland", "fi-FI", "fi" }, { "France", "fr-FR", "fr" },
    { "Germany", "de-DE", "de" }, { "Hungary", "hu-HU", "hu" }, { "India", "en-IN", "us" },
    { "Ireland", "en-IE", "ie" }, { "Italy", "it-IT", "it" }, { "Japan", "ja-JP", "jp" },
    { "Mexico", "es-MX", "latam" }, { "Netherlands", "nl-NL", "nl" }, { "New Zealand", "en-NZ", "us" },
    { "Norway", "nb-NO", "no" }, { "Poland", "pl-PL", "pl" }, { "Portugal", "pt-PT", "pt" },
    { "South Africa", "en-ZA", "us" }, { "Spain", "es-ES", "es" }, { "Sweden", "sv-SE", "se" },
    { "Switzerland", "de-CH", "ch" }, { "United Kingdom", "en-GB", "gb" }, { "United States", "en-US", "us" },
};
#define NREGIONS ((int)(sizeof(g_regions) / sizeof(g_regions[0])))

static const struct { const char *code, *name; } g_layouts[] = {
    { "us", "US" }, { "gb", "United Kingdom" }, { "de", "German" }, { "fr", "French" },
    { "es", "Spanish" }, { "latam", "Latin American" }, { "it", "Italian" }, { "pt", "Portuguese" },
    { "br", "Portuguese (Brazil ABNT2)" }, { "nl", "Dutch" }, { "be", "Belgian French" }, { "ch", "Swiss German" },
    { "se", "Swedish" }, { "no", "Norwegian" }, { "dk", "Danish" }, { "fi", "Finnish" }, { "pl", "Polish (Programmers)" },
    { "cz", "Czech" }, { "hu", "Hungarian" }, { "jp", "Japanese" }, { "ca", "Canadian French" }, { "ie", "Irish" },
};
#define NLAYOUTS ((int)(sizeof(g_layouts) / sizeof(g_layouts[0])))

static const struct { const char *id, *name, *note; } g_browsers[] = {
    { "Mozilla.Firefox", "Mozilla Firefox", "Free and open source, from Mozilla" },
    { "Mozilla.Firefox.ESR", "Mozilla Firefox ESR", "Firefox's extended support release: fewer changes" },
    { "none", "Don't install a browser now", "You can install one later with winget or from its website" },
};
#define NBROWSERS ((int)(sizeof(g_browsers) / sizeof(g_browsers[0])))

static const struct { const char *key, *title, *desc; } g_privacy_items[4] = {
    { "location", "Location",
      "Let programs use your location, and let Stained Glass OS find it from your network." },
    { "microphone", "Microphone",
      "Let voice typing (Start key + H) and other programs use the microphone. Speech is recognised on this PC." },
    { "tailored", "Tailored experiences",
      "Let Stained Glass OS use what it knows about how you use this PC for tips. Nothing leaves this PC." },
    { "advertising", "Advertising ID",
      "Let programs use an advertising ID to show more relevant ads." },
};

/* The network page's rows. */
#define MAX_NETS 32
static struct net { BOOL wired; char text[80], hex[72], sec[16], state[24]; int signal; BOOL inuse; } g_nets[MAX_NETS];
static int g_nnets;
static BOOL g_listing_nets;

static int g_list_map[64];   /* list row -> table index */
static int g_list_count;

/* --- the bridge ---------------------------------------------------------------- */

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

/* --- pages --------------------------------------------------------------------- */

static void show( HWND w, BOOL on ) { ShowWindow( w, on ? SW_SHOW : SW_HIDE ); }

static void set_status( const char *text, BOOL err )
{
    snprintf( g_status, sizeof(g_status), "%s", text );
    g_status_err = err;
    InvalidateRect( g_main, &g_body, FALSE );
}

static int layout_index( const char *code )
{
    int i;
    for (i = 0; i < NLAYOUTS; i++) if (!strcmp( g_layouts[i].code, code )) return i;
    return -1;
}

static int region_for_kbd( const char *code )
{
    static const struct { const char *kbd, *region; } pref[] = {
        { "us", "United States" }, { "gb", "United Kingdom" }, { "de", "Germany" }, { "fr", "France" },
        { "es", "Spain" }, { "it", "Italy" }, { "pt", "Portugal" }, { "br", "Brazil" }, { "nl", "Netherlands" },
        { "be", "Belgium" }, { "ch", "Switzerland" }, { "se", "Sweden" }, { "no", "Norway" }, { "dk", "Denmark" },
        { "fi", "Finland" }, { "pl", "Poland" }, { "cz", "Czechia" }, { "hu", "Hungary" }, { "jp", "Japan" },
        { "ca", "Canada" }, { "latam", "Mexico" }, { "ie", "Ireland" },
    };
    int i, j;
    for (i = 0; i < (int)(sizeof(pref) / sizeof(pref[0])); i++)
        if (!strcmp( pref[i].kbd, code ))
            for (j = 0; j < NREGIONS; j++) if (!strcmp( g_regions[j].name, pref[i].region )) return j;
    for (j = 0; j < NREGIONS; j++) if (!strcmp( g_regions[j].name, "United States" )) return j;
    return 0;
}

static void list_clear( void )
{
    SendMessageA( g_list, LB_RESETCONTENT, 0, 0 );
    g_list_count = 0;
}

static void list_add( const char *text, int index )
{
    if (g_list_count >= (int)(sizeof(g_list_map) / sizeof(g_list_map[0]))) return;
    SendMessageA( g_list, LB_ADDSTRING, 0, (LPARAM)text );
    g_list_map[g_list_count++] = index;
}

static void list_select_index( int index )
{
    int i;
    for (i = 0; i < g_list_count; i++)
        if (g_list_map[i] == index)
        {
            SendMessageA( g_list, LB_SETCURSEL, i, 0 );
            return;
        }
}

static int list_selected( void )
{
    LRESULT i = SendMessageA( g_list, LB_GETCURSEL, 0, 0 );
    return i >= 0 && i < g_list_count ? g_list_map[i] : -1;
}

static void log_selection( void )
{
    char text[128];
    LRESULT i = SendMessageA( g_list, LB_GETCURSEL, 0, 0 );
    if (i < 0 || SendMessageA( g_list, LB_GETTEXTLEN, i, 0 ) >= (LRESULT)sizeof(text)) return;
    SendMessageA( g_list, LB_GETTEXT, i, (LPARAM)text );
    log_line( "sg-oobe: selected %s", text );
}

static void fill_layouts( int except )
{
    int i;
    list_clear();
    for (i = 0; i < NLAYOUTS; i++) if (i != except) list_add( g_layouts[i].name, i );
}

static struct net *selected_net( void )
{
    int i = list_selected();
    return i >= 0 && i < g_nnets ? &g_nets[i] : NULL;
}

/* The network page's buttons follow the row chosen: a Wi-Fi network not in
 * use connects (with a key if it has security); otherwise Next. */
static void update_network_buttons( void )
{
    struct net *n = selected_net();
    BOOL join = n && !n->wired && !n->inuse;
    BOOL secured = join && strcmp( n->sec, "open" );

    SetWindowTextA( g_primary, join ? "Connect" : "Next" );
    show( g_key, secured );
    EnableWindow( g_primary, !g_busy && !g_listing_nets && (join || g_online) );
    SetWindowTextA( g_secondary, g_online ? "" : "Skip for now" );
    show( g_secondary, !g_online );
    InvalidateRect( g_primary, NULL, FALSE );
    InvalidateRect( g_main, &g_body, FALSE );
}

static void request_networks( void )
{
    g_nnets = 0;
    g_listing_nets = TRUE;
    list_clear();
    update_network_buttons();
    send_line( "NETWORKS" );
}

static void set_page( enum page p )
{
    int i;
    BOOL list = p == P_REGION || p == P_KBD || p == P_KBD2_PICK || p == P_NETWORK || p == P_BROWSER;

    g_page = p;
    g_armed = 0;
    g_status[0] = 0;
    g_status_err = FALSE;
    g_text[0] = 0;
    log_line( "sg-oobe: page %s", page_names[p] );
    KillTimer( g_main, TIMER_RESCAN );

    show( g_list, list );
    EnableWindow( g_list, TRUE );
    /* The network page's list is shorter: the key field goes under it. */
    MoveWindow( g_list, g_body.left, g_body.top + 136, g_body.right - g_body.left,
                g_body.bottom - g_body.top - 136 - (p == P_NETWORK ? 200 : 124), TRUE );
    show( g_name, p == P_ACCOUNT ); show( g_pass, p == P_ACCOUNT ); show( g_pass2, p == P_ACCOUNT );
    show( g_key, FALSE );
    for (i = 0; i < 4; i++) show( g_toggle[i], p == P_PRIVACY );
    show( g_back, p != P_REGION && p != P_APPLY && p != P_DONE && p != P_FAILED );
    show( g_primary, p != P_APPLY && p != P_DONE );
    show( g_secondary, p == P_KBD2 );
    EnableWindow( g_primary, TRUE );
    SetWindowTextA( g_secondary, "Skip" );

    switch (p)
    {
    case P_REGION:
        strcpy( g_heading, "Let's start with region. Is this right?" );
        list_clear();
        for (i = 0; i < NREGIONS; i++) list_add( g_regions[i].name, i );
        if (g_region < 0) g_region = region_for_kbd( g_setup_kbd );
        list_select_index( g_region );
        SetWindowTextA( g_primary, "Yes" );
        SetFocus( g_list );
        break;
    case P_KBD:
        strcpy( g_heading, "Is this the right keyboard layout?" );
        strcpy( g_text, "If you also use another keyboard layout, you can add that next." );
        fill_layouts( -1 );
        list_select_index( g_kbd );
        SetWindowTextA( g_primary, "Yes" );
        SetFocus( g_list );
        break;
    case P_KBD2:
        strcpy( g_heading, "Want to add a second keyboard layout?" );
        snprintf( g_text, sizeof(g_text), "You're using the %s layout. To switch between two layouts, press "
                  "Start key + Space.", g_layouts[g_kbd].name );
        SetWindowTextA( g_primary, "Add layout" );
        SetFocus( g_primary );
        break;
    case P_KBD2_PICK:
        strcpy( g_heading, "Choose a second keyboard layout" );
        fill_layouts( g_kbd );
        list_select_index( g_kbd2 >= 0 ? g_kbd2 : g_list_map[0] );
        SetWindowTextA( g_primary, "Add layout" );
        SetFocus( g_list );
        break;
    case P_NETWORK:
        strcpy( g_heading, "Let's connect you to a network" );
        request_networks();
        SetTimer( g_main, TIMER_RESCAN, 15000, NULL );
        SetFocus( g_list );
        break;
    case P_ACCOUNT:
        strcpy( g_heading, "Who's going to use this PC?" );
        strcpy( g_text, "What name do you want to use? Then create a password you'll remember. "
                        "This account will be the PC's administrator." );
        SetWindowTextA( g_primary, "Next" );
        SetFocus( g_name );
        break;
    case P_PRIVACY:
        strcpy( g_heading, "Choose privacy settings for your device" );
        strcpy( g_text, "Diagnostic data: none. Stained Glass OS doesn't collect or send diagnostic data. "
                        "You can change the rest later in Settings > Privacy." );
        SetWindowTextA( g_primary, "Accept" );
        SetFocus( g_toggle[0] );
        break;
    case P_BROWSER:
        strcpy( g_heading, "Get a web browser" );
        list_clear();
        for (i = 0; i < NBROWSERS; i++) list_add( g_browsers[i].name, i );
        if (!g_online)
        {
            strcpy( g_text, "You're not connected to the internet, so a browser can't be downloaded now. "
                            "You can install one later with winget." );
            g_browser = NBROWSERS - 1;
            EnableWindow( g_list, FALSE );
        }
        else strcpy( g_text, "It's downloaded from its publisher and installed for everyone on this PC, "
                             "in the background, after setup. Stained Glass OS doesn't include one." );
        list_select_index( g_browser );
        SetWindowTextA( g_primary, "Next" );
        SetFocus( g_online ? g_list : g_primary );
        break;
    case P_APPLY:
        strcpy( g_heading, "Hi." );
        strcpy( g_text, "We're setting things up for you. This might take a few minutes." );
        SetFocus( g_main );
        break;
    case P_DONE:
        strcpy( g_heading, "All set." );
        strcpy( g_text, "Your PC is ready. Sign in to get started." );
        SetTimer( g_main, TIMER_CLOSE, 2500, NULL );
        break;
    case P_FAILED:
        strcpy( g_heading, "Something went wrong" );
        SetWindowTextA( g_primary, "Try again" );
        SetFocus( g_primary );
        break;
    }
    if (list) log_selection();
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
    return strcmp( s, "root" ) && strcmp( s, "sgsystem" ) && strcmp( s, "nobody" ) && strcmp( s, "daemon" ) &&
           strcmp( s, "sguser" ) && strcmp( s, "live" ) && strcmp( s, "sggreet" ) && strcmp( s, "sgrdp" );
}

/* The account name from the name typed: its first word, lower case. */
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

static void submit_account( void )
{
    char name[128], account[64], pass[256], pass2[256];

    GetWindowTextA( g_name, name, sizeof(name) );
    derive_account( name, account, sizeof(account) );
    if (strchr( name, '\t' ) || strchr( name, ':' )) { set_status( "The name can't contain a tab or ':'.", TRUE ); return; }
    if (!valid_account( account ))
    {
        set_status( "Start the name with a letter, and use letters and digits.", TRUE );
        SetFocus( g_name );
        return;
    }
    GetWindowTextA( g_pass, pass, sizeof(pass) );
    GetWindowTextA( g_pass2, pass2, sizeof(pass2) );
    if (!pass[0] || strcmp( pass, pass2 ))
    {
        set_status( pass[0] ? "The passwords don't match." : "Create a password.", TRUE );
        SetWindowTextA( g_pass2, "" );
        SetFocus( pass[0] ? g_pass2 : g_pass );
    }
    else
    {
        g_busy = TRUE;
        EnableWindow( g_primary, FALSE );
        set_status( "Please wait...", FALSE );
        log_line( "sg-oobe: creating the account %s", account );
        send_line( "ACCOUNT %s\t%s", account, name );
        send_line( "PASSWORD %s", pass );
    }
    SecureZeroMemory( pass, sizeof(pass) );
    SecureZeroMemory( pass2, sizeof(pass2) );
}

static void connect_network( void )
{
    struct net *n = selected_net();
    char key[128] = "";

    if (!n || n->wired) return;
    if (strcmp( n->sec, "open" ))
    {
        GetWindowTextA( g_key, key, sizeof(key) );
        if (strlen( key ) < 8) { set_status( "Enter the network security key.", TRUE ); SetFocus( g_key ); return; }
    }
    g_busy = TRUE;
    update_network_buttons();
    set_status( "Connecting...", FALSE );
    log_line( "sg-oobe: connecting to %s", n->text );
    send_line( "CONNECT %s\t%s", n->hex, n->sec );
    send_line( "KEY %s", key );
    SecureZeroMemory( key, sizeof(key) );
    SetWindowTextA( g_key, "" );
}

static void finish( void )
{
    WCHAR wloc[16], geo[16] = L"";
    char layouts[32];
    int r = g_region;

    MultiByteToWideChar( CP_ACP, 0, g_regions[r].locale, -1, wloc, 16 );
    if (!GetLocaleInfoEx( wloc, LOCALE_IGEOID, geo, 16 )) lstrcpyW( geo, L"244" );
    if (g_kbd2 >= 0) snprintf( layouts, sizeof(layouts), "%s,%s", g_layouts[g_kbd].code, g_layouts[g_kbd2].code );
    else snprintf( layouts, sizeof(layouts), "%s", g_layouts[g_kbd].code );
    set_page( P_APPLY );
    log_line( "sg-oobe: finishing: %s %ls %s location=%d microphone=%d tailored=%d advertising=%d browser=%s",
              g_regions[r].locale, geo, layouts, g_privacy[0], g_privacy[1], g_privacy[2], g_privacy[3],
              g_browsers[g_browser].id );
    send_line( "FINISH %s\t%ls\t%s\t%d\t%d\t%d\t%d\t%s", g_regions[r].locale, geo, layouts,
               g_privacy[0], g_privacy[1], g_privacy[2], g_privacy[3], g_browsers[g_browser].id );
}

static void go_next( void )
{
    int i;

    if (g_busy) return;
    switch (g_page)
    {
    case P_REGION:
        if ((i = list_selected()) >= 0) g_region = i;
        set_page( P_KBD );
        break;
    case P_KBD:
        if ((i = list_selected()) >= 0) g_kbd = i;
        if (g_kbd2 == g_kbd) g_kbd2 = -1;
        set_page( P_KBD2 );
        break;
    case P_KBD2: set_page( P_KBD2_PICK ); break;
    case P_KBD2_PICK:
        if ((i = list_selected()) >= 0) g_kbd2 = i;
        log_line( "sg-oobe: second layout %s", g_kbd2 >= 0 ? g_layouts[g_kbd2].code : "none" );
        set_page( P_NETWORK );
        break;
    case P_NETWORK:
    {
        struct net *n = selected_net();
        if (n && !n->wired && !n->inuse) { connect_network(); break; }
        if (!g_online) break;
        set_page( g_has_account ? P_PRIVACY : P_ACCOUNT );
        break;
    }
    case P_ACCOUNT: submit_account(); break;
    case P_PRIVACY: set_page( P_BROWSER ); break;
    case P_BROWSER:
        if ((i = list_selected()) >= 0) g_browser = i;
        finish();
        break;
    case P_FAILED: finish(); break;
    default: break;
    }
}

static void go_skip( void )
{
    if (g_busy) return;
    if (g_page == P_KBD2) { g_kbd2 = -1; log_line( "sg-oobe: second layout none" ); set_page( P_NETWORK ); }
    else if (g_page == P_NETWORK && !g_online) set_page( g_has_account ? P_PRIVACY : P_ACCOUNT );
}

static void go_back( void )
{
    if (g_busy) return;
    switch (g_page)
    {
    case P_KBD: set_page( P_REGION ); break;
    case P_KBD2: set_page( P_KBD ); break;
    case P_KBD2_PICK: set_page( P_KBD2 ); break;
    case P_NETWORK: set_page( P_KBD2 ); break;
    case P_ACCOUNT: set_page( P_NETWORK ); break;
    case P_PRIVACY: set_page( g_has_account ? P_NETWORK : P_ACCOUNT ); break;
    case P_BROWSER: set_page( P_PRIVACY ); break;
    default: break;
    }
}

static void handle_line( char *line )
{
    char *f[8];

    if (!strncmp( line, "KEYBOARD ", 9 ))
    {
        int k;
        snprintf( g_setup_kbd, sizeof(g_setup_kbd), "%s", line + 9 );
        if ((k = layout_index( g_setup_kbd )) >= 0) g_kbd = k;
        if (g_page == P_REGION && !g_region_touched)
        {
            g_region = region_for_kbd( g_setup_kbd );
            list_select_index( g_region );
            log_selection();
        }
        return;
    }
    if (!strncmp( line, "ACCOUNT ", 8 )) { g_has_account = !strcmp( line + 8, "yes" ); return; }
    if (!strncmp( line, "ONLINE ", 7 ))
    {
        g_online = !strcmp( line + 7, "yes" );
        return;
    }
    if (g_listing_nets && !strncmp( line, "WIRED ", 6 ) && g_nnets < MAX_NETS)
    {
        struct net *n = &g_nets[g_nnets];
        if (split_tabs( line + 6, f, 2 ) < 2) return;
        memset( n, 0, sizeof(*n) );
        n->wired = TRUE;
        n->inuse = !strcmp( f[1], "connected" );
        snprintf( n->state, sizeof(n->state), "%s", n->inuse ? "Connected" : "Not connected" );
        snprintf( n->text, sizeof(n->text), "Ethernet (%s)", f[0] );
        g_nnets++;
        return;
    }
    if (g_listing_nets && !strncmp( line, "WIFI ", 5 ) && g_nnets < MAX_NETS)
    {
        struct net *n = &g_nets[g_nnets];
        if (split_tabs( line + 5, f, 6 ) < 6) return;
        if (strcmp( f[1], "open" ) && strcmp( f[1], "wpa-psk" ) && strcmp( f[1], "sae" )) return;
        memset( n, 0, sizeof(*n) );
        n->signal = atoi( f[0] );
        snprintf( n->sec, sizeof(n->sec), "%s", f[1] );
        n->inuse = !strcmp( f[2], "yes" );
        snprintf( n->hex, sizeof(n->hex), "%s", f[4] );
        snprintf( n->text, sizeof(n->text), "%s", f[5] );
        snprintf( n->state, sizeof(n->state), "%s", n->inuse ? "Connected" : strcmp( n->sec, "open" ) ? "Secured" : "Open" );
        g_nnets++;
        return;
    }
    if (!strcmp( line, "END" ))
    {
        if (!g_state_known) { g_state_known = TRUE; log_line( "sg-oobe: state keyboard=%s account=%s online=%s",
                                                              g_setup_kbd, g_has_account ? "yes" : "no", g_online ? "yes" : "no" ); }
        if (g_listing_nets)
        {
            int i;
            g_listing_nets = FALSE;
            list_clear();
            for (i = 0; i < g_nnets; i++)
            {
                char row[128];
                snprintf( row, sizeof(row), "%s", g_nets[i].text );
                list_add( row, i );
            }
            for (i = 0; i < g_nnets && !g_nets[i].inuse; i++) ;
            if (g_nnets) SendMessageA( g_list, LB_SETCURSEL, i < g_nnets ? i : 0, 0 );
            log_line( "sg-oobe: networks %d online=%s", g_nnets, g_online ? "yes" : "no" );
            if (g_page == P_NETWORK)
            {
                strcpy( g_text, g_online ? "You're connected to the internet." :
                        g_nnets ? "Choose a network, or skip this for now." : "No networks were found. You can skip this for now." );
                log_selection();
                update_network_buttons();
            }
        }
        return;
    }
    if (!strcmp( line, "OK" ) && g_busy)
    {
        g_busy = FALSE;
        if (g_page == P_ACCOUNT)
        {
            log_line( "sg-oobe: account created" );
            SetWindowTextA( g_pass, "" ); SetWindowTextA( g_pass2, "" );
            g_has_account = TRUE;
            set_page( P_PRIVACY );
        }
        else if (g_page == P_NETWORK)
        {
            log_line( "sg-oobe: connected" );
            set_status( "Connected.", FALSE );
            request_networks();
        }
        return;
    }
    if (!strcmp( line, "DONE" ) && g_page == P_APPLY)
    {
        g_finished = TRUE;
        log_line( "sg-oobe: done" );
        set_page( P_DONE );
        return;
    }
    if (!strncmp( line, "FAILED ", 7 ))
    {
        log_line( "sg-oobe: failed: %s", line + 7 );
        if (g_page == P_APPLY)
        {
            set_page( P_FAILED );
            snprintf( g_text, sizeof(g_text), "%s", line + 7 );
        }
        else
        {
            g_busy = FALSE;
            set_status( line + 7, TRUE );
            if (g_page == P_NETWORK) update_network_buttons();
            else EnableWindow( g_primary, TRUE );
        }
        InvalidateRect( g_main, NULL, FALSE );
    }
}

/* --- drawing -------------------------------------------------------------------- */

static void fill( HDC dc, int l, int t, int r, int b, COLORREF c )
{
    RECT rc = { l, t, r, b };
    HBRUSH br = CreateSolidBrush( c );
    FillRect( dc, &rc, br );
    DeleteObject( br );
}

static void text_at( HDC dc, HFONT font, COLORREF color, int l, int t, int r, int b, const char *s, UINT fmt )
{
    RECT rc = { l, t, r, b };
    SelectObject( dc, font );
    SetTextColor( dc, color );
    DrawTextA( dc, s, -1, &rc, fmt );
}

static unsigned int g_seed = 0x0bbe5eed;
static int rnd( int n ) { g_seed = g_seed * 1103515245 + 12345; return (int)((g_seed >> 16) % (unsigned)n); }

/* The backdrop behind the card: dark violet glass panes, leaded. */
static void build_backdrop( HDC ref, int w, int h )
{
    enum { CELL = 160 };
    int cols = w / CELL + 2, rows = h / CELL + 2, i, j;
    POINT *v = malloc( sizeof(POINT) * cols * rows );
    HDC dc = CreateCompatibleDC( ref );
    HPEN lead = CreatePen( PS_SOLID, 3, RGB(0x0B, 0x04, 0x18) ), oldp;
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
                int y = (t[0].y + t[1].y + t[2].y) / 3, s = h ? y * 256 / h : 0, accent = rnd( 9 );
                int r = 0x1C + (0x2C - 0x1C) * s / 256 + rnd( 13 ) - 6, g = 0x0C + rnd( 7 ) - 3, bl = 0x3A + (0x4E - 0x3A) * s / 256 + rnd( 17 ) - 8;
                HBRUSH br, oldb;
                if (accent == 0) { r += 24; bl += 18; }
                else if (accent == 1) { g += 14; bl += 16; }
                else if (accent == 2) { r += 30; bl -= 4; }
                r = r < 0 ? 0 : r > 255 ? 255 : r; g = g < 0 ? 0 : g > 255 ? 255 : g; bl = bl < 0 ? 0 : bl > 255 ? 255 : bl;
                br = CreateSolidBrush( RGB(r, g, bl) );
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

/* The mark: four panes of coloured glass around a point. */
static void draw_logo( HDC dc, int cx, int cy, int size )
{
    static const COLORREF colors[4] = { RGB(0x7B, 0x3F, 0xD6), RGB(0xE0, 0x3E, 0x8C), RGB(0xF2, 0x9D, 0x2E), RGB(0x1F, 0xB5, 0xAD) };
    int h = size / 4, gap = size / 24 + 1, i;
    HPEN pen = CreatePen( PS_NULL, 0, 0 ), oldp = SelectObject( dc, pen );

    for (i = 0; i < 4; i++)
    {
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

/* Each page's picture, drawn in white lines on the art panel. */
static void draw_art( HDC dc )
{
    int cx = (g_art.left + g_art.right) / 2, cy = (g_art.top + g_art.bottom) / 2 + 10, r = 78, i;
    HPEN pen = CreatePen( PS_SOLID, 4, COL_TEXT ), thin = CreatePen( PS_SOLID, 2, COL_SUBTLE ), oldp;
    HBRUSH oldb = SelectObject( dc, GetStockObject( NULL_BRUSH ) );

    oldp = SelectObject( dc, pen );
    switch (g_page)
    {
    case P_REGION:     /* a globe */
        Ellipse( dc, cx - r, cy - r, cx + r, cy + r );
        SelectObject( dc, thin );
        Ellipse( dc, cx - r / 2, cy - r, cx + r / 2, cy + r );
        MoveToEx( dc, cx, cy - r, NULL ); LineTo( dc, cx, cy + r );
        MoveToEx( dc, cx - r, cy, NULL ); LineTo( dc, cx + r, cy );
        MoveToEx( dc, cx - r + 12, cy - r / 2, NULL ); LineTo( dc, cx + r - 12, cy - r / 2 );
        MoveToEx( dc, cx - r + 12, cy + r / 2, NULL ); LineTo( dc, cx + r - 12, cy + r / 2 );
        break;
    case P_KBD: case P_KBD2: case P_KBD2_PICK:     /* a keyboard */
    {
        int w = 200, h = 96, x0 = cx - w / 2, y0 = cy - h / 2, row, col;
        RoundRect( dc, x0, y0, x0 + w, y0 + h, 16, 16 );
        SelectObject( dc, thin );
        for (row = 0; row < 3; row++)
            for (col = 0; col < 10; col++)
            {
                int kx = x0 + 14 + col * 17 + (row == 1 ? 6 : row == 2 ? 12 : 0), ky = y0 + 12 + row * 19;
                if (kx + 12 > x0 + w - 10) continue;
                Rectangle( dc, kx, ky, kx + 12, ky + 13 );
            }
        Rectangle( dc, x0 + 50, y0 + 70, x0 + w - 50, y0 + 83 );
        if (g_page != P_KBD)
        {
            SelectObject( dc, pen );
            MoveToEx( dc, cx + 110, cy - 70, NULL ); LineTo( dc, cx + 110, cy - 34 );
            MoveToEx( dc, cx + 92, cy - 52, NULL ); LineTo( dc, cx + 128, cy - 52 );
        }
        break;
    }
    case P_NETWORK:    /* Wi-Fi arcs */
        for (i = 1; i <= 3; i++)
        {
            int rr = i * 32;
            Arc( dc, cx - rr, cy + 40 - rr, cx + rr, cy + 40 + rr, cx + rr, cy + 40 - rr, cx - rr, cy + 40 - rr );
        }
        SelectObject( dc, GetStockObject( WHITE_BRUSH ) );
        Ellipse( dc, cx - 8, cy + 32, cx + 8, cy + 48 );
        break;
    case P_ACCOUNT:    /* a person */
        Ellipse( dc, cx - 34, cy - 70, cx + 34, cy - 2 );
        Arc( dc, cx - 70, cy + 10, cx + 70, cy + 150, cx + 70, cy + 80, cx - 70, cy + 80 );
        break;
    case P_PRIVACY:    /* a shield */
    {
        POINT p[6] = { { cx, cy - 86 }, { cx + 70, cy - 58 }, { cx + 62, cy + 20 }, { cx, cy + 86 }, { cx - 62, cy + 20 }, { cx - 70, cy - 58 } };
        Polygon( dc, p, 6 );
        MoveToEx( dc, cx - 26, cy, NULL ); LineTo( dc, cx - 6, cy + 22 ); LineTo( dc, cx + 30, cy - 22 );
        break;
    }
    case P_BROWSER:    /* a window with a globe */
        RoundRect( dc, cx - 100, cy - 72, cx + 100, cy + 72, 10, 10 );
        MoveToEx( dc, cx - 100, cy - 44, NULL ); LineTo( dc, cx + 100, cy - 44 );
        SelectObject( dc, thin );
        Ellipse( dc, cx - 36, cy - 30, cx + 36, cy + 42 );
        Ellipse( dc, cx - 16, cy - 30, cx + 16, cy + 42 );
        MoveToEx( dc, cx - 36, cy + 6, NULL ); LineTo( dc, cx + 36, cy + 6 );
        break;
    default:
        draw_logo( dc, cx, cy, 200 );
        break;
    }
    SelectObject( dc, oldp );
    SelectObject( dc, oldb );
    DeleteObject( pen );
    DeleteObject( thin );
}

/* The steps down the art panel, Windows 10's: Basics, Network, Account, Services. */
static void draw_steps( HDC dc )
{
    static const char *const steps[] = { "Basics", "Network", "Account", "Services" };
    int cur = g_page <= P_KBD2_PICK ? 0 : g_page == P_NETWORK ? 1 : g_page == P_ACCOUNT ? 2 : 3, i;
    int x = g_art.left + 32, y = g_art.top + 32;

    for (i = 0; i < 4; i++, x += 88)
    {
        text_at( dc, g_font_step, i == cur ? COL_TEXT : COL_DIM, x, y, x + 86, y + 22, steps[i], DT_SINGLELINE );
        if (i == cur) fill( dc, x, y + 24, x + 40, y + 27, COL_ACCENT2 );
    }
}

static void paint( HWND hwnd )
{
    PAINTSTRUCT ps;
    HDC wdc = BeginPaint( hwnd, &ps ), dc;
    RECT client;
    HBITMAP bm, oldbm;
    int x = g_body.left, y = g_body.top;

    GetClientRect( hwnd, &client );
    dc = CreateCompatibleDC( wdc );
    bm = CreateCompatibleBitmap( wdc, client.right, client.bottom );
    oldbm = SelectObject( dc, bm );
    SetBkMode( dc, TRANSPARENT );

    if (!g_backdrop) build_backdrop( wdc, client.right, client.bottom );
    {
        HDC bd = CreateCompatibleDC( wdc );
        HBITMAP old = SelectObject( bd, g_backdrop );
        BitBlt( dc, 0, 0, client.right, client.bottom, bd, 0, 0, SRCCOPY );
        SelectObject( bd, old );
        DeleteDC( bd );
    }
    fill( dc, g_card.left, g_card.top, g_card.right, g_card.bottom, COL_CARD );
    fill( dc, g_art.left, g_art.top, g_art.right, g_art.bottom, COL_ART );
    draw_steps( dc );
    draw_art( dc );

    text_at( dc, g_font_head, COL_TEXT, x, y + 40, g_body.right, y + 130, g_heading, DT_WORDBREAK );
    y += 136;
    if (g_page == P_PRIVACY)
    {
        int i;
        for (i = 0; i < 4; i++)
        {
            int ty = y + i * 64;
            text_at( dc, g_font_bold, COL_TEXT, x + 64, ty, g_body.right, ty + 22, g_privacy_items[i].title, DT_SINGLELINE );
            text_at( dc, g_font_small, COL_SUBTLE, x + 64, ty + 22, g_body.right, ty + 60, g_privacy_items[i].desc, DT_WORDBREAK );
        }
        text_at( dc, g_font_small, COL_SUBTLE, x, y + 262, g_body.right, y + 310, g_text, DT_WORDBREAK );
    }
    else if (g_page == P_ACCOUNT)
    {
        text_at( dc, g_font, COL_SUBTLE, x, y, g_body.right, y + 50, g_text, DT_WORDBREAK );
        text_at( dc, g_font_small, COL_SUBTLE, x, y + 56, g_body.right, y + 76, "Name", DT_SINGLELINE );
        text_at( dc, g_font_small, COL_SUBTLE, x, y + 124, g_body.right, y + 144, "Password", DT_SINGLELINE );
        text_at( dc, g_font_small, COL_SUBTLE, x, y + 192, g_body.right, y + 212, "Confirm your password", DT_SINGLELINE );
    }
    else if (g_page == P_KBD2 || g_page == P_APPLY || g_page == P_DONE || g_page == P_FAILED)
        text_at( dc, g_font, COL_SUBTLE, x, y, g_body.right, y + 120, g_text, DT_WORDBREAK );
    else if (g_text[0])
        text_at( dc, g_font_small, COL_SUBTLE, x, g_body.bottom - 112, g_body.right, g_body.bottom - 64, g_text, DT_WORDBREAK );
    if (g_page == P_NETWORK && IsWindowVisible( g_key ))
        text_at( dc, g_font_small, COL_SUBTLE, x, g_body.bottom - 192, g_body.right, g_body.bottom - 172,
                 "Enter the network security key", DT_SINGLELINE );
    if (g_page == P_APPLY)
    {
        /* a row of dots, Windows' "please wait" */
        int i, dx = g_body.left;
        for (i = 0; i < 5; i++) fill( dc, dx + i * 16, y + 96, dx + i * 16 + 6, y + 102, COL_TEXT );
    }
    if (g_status[0])
        text_at( dc, g_font_small, g_status_err ? COL_ERR : COL_SUBTLE, x, g_body.bottom - 58, g_body.right - 280,
                 g_body.bottom - 10, g_status, DT_WORDBREAK );

    BitBlt( wdc, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY );
    SelectObject( dc, oldbm );
    DeleteObject( bm );
    DeleteDC( dc );
    EndPaint( hwnd, &ps );
}

static void draw_list_item( const DRAWITEMSTRUCT *d )
{
    HDC dc = d->hDC;
    RECT r = d->rcItem;
    BOOL sel = (d->itemState & ODS_SELECTED) != 0;
    BOOL dis = !IsWindowEnabled( g_list );
    char text[128] = "";
    int idx;

    if (d->itemID == (UINT)-1) { FillRect( dc, &r, g_list_brush ); return; }
    SendMessageA( g_list, LB_GETTEXT, d->itemID, (LPARAM)text );
    idx = (int)d->itemID < g_list_count ? g_list_map[d->itemID] : -1;
    fill( dc, r.left, r.top, r.right, r.bottom, sel ? (dis ? RGB(0x4A, 0x3A, 0x66) : COL_ACCENT) : COL_LIST );
    SetBkMode( dc, TRANSPARENT );
    r.left += 16;
    SelectObject( dc, g_font_list );
    SetTextColor( dc, dis ? COL_DIM : COL_TEXT );
    if (g_page == P_NETWORK && idx >= 0 && idx < g_nnets)
    {
        const struct net *n = &g_nets[idx];
        RECT t = r;
        int b, bx = r.left, by = (r.top + r.bottom) / 2 + 8;
        /* signal bars, or a plug for the wire */
        for (b = 0; b < 4; b++)
        {
            BOOL lit = n->wired || n->signal > b * 25;
            fill( dc, bx + b * 5, by - 4 - b * 4, bx + b * 5 + 3, by, lit ? COL_TEXT : COL_DIM );
        }
        t.left += 34;
        DrawTextA( dc, text, -1, &t, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS );
        t.right -= 16;
        SelectObject( dc, g_font_small );
        SetTextColor( dc, sel ? COL_TEXT : COL_SUBTLE );
        DrawTextA( dc, n->state, -1, &t, DT_SINGLELINE | DT_VCENTER | DT_RIGHT );
    }
    else if (g_page == P_BROWSER && idx >= 0 && idx < NBROWSERS)
    {
        RECT t = r;
        t.bottom = (r.top + r.bottom) / 2 + 2;
        DrawTextA( dc, text, -1, &t, DT_SINGLELINE | DT_BOTTOM );
        t.top = t.bottom + 2; t.bottom = r.bottom;
        SelectObject( dc, g_font_small );
        SetTextColor( dc, dis ? COL_DIM : sel ? COL_TEXT : COL_SUBTLE );
        DrawTextA( dc, g_browsers[idx].note, -1, &t, DT_SINGLELINE | DT_TOP );
    }
    else DrawTextA( dc, text, -1, &r, DT_SINGLELINE | DT_VCENTER );
    if ((d->itemState & ODS_FOCUS) && !dis) { RECT f = d->rcItem; InflateRect( &f, -2, -2 ); DrawFocusRect( dc, &f ); }
}

static void draw_item( const DRAWITEMSTRUCT *d )
{
    HDC dc = d->hDC;
    RECT r = d->rcItem;
    BOOL dis = (d->itemState & ODS_DISABLED) != 0, focus = (d->itemState & ODS_FOCUS) != 0;
    BOOL down = (d->itemState & ODS_SELECTED) != 0;
    char text[128];

    if (d->CtlType == ODT_LISTBOX) { draw_list_item( d ); return; }
    GetWindowTextA( d->hwndItem, text, sizeof(text) );
    SetBkMode( dc, TRANSPARENT );
    if (d->CtlID >= ID_TOGGLE && d->CtlID < ID_TOGGLE + 4)
    {
        BOOL on = g_privacy[d->CtlID - ID_TOGGLE];
        int w = 44, h = 20, x = r.left, y = r.top + 2;
        HPEN pen = CreatePen( PS_SOLID, 2, on ? COL_ACCENT2 : COL_TEXT ), oldp;
        HBRUSH br = CreateSolidBrush( on ? COL_ACCENT2 : COL_CARD ), oldb;
        FillRect( dc, &r, g_card_brush );
        oldp = SelectObject( dc, pen ); oldb = SelectObject( dc, br );
        RoundRect( dc, x, y, x + w, y + h, h, h );
        SelectObject( dc, oldb ); DeleteObject( br );
        br = CreateSolidBrush( COL_TEXT ); oldb = SelectObject( dc, br );
        SelectObject( dc, GetStockObject( NULL_PEN ) );
        Ellipse( dc, on ? x + w - 16 : x + 5, y + 5, on ? x + w - 5 : x + 16, y + 16 );
        SelectObject( dc, oldb ); SelectObject( dc, oldp );
        DeleteObject( br ); DeleteObject( pen );
        SelectObject( dc, g_font_small );
        SetTextColor( dc, COL_SUBTLE );
        { RECT t = { x, y + h + 2, r.right, r.bottom }; DrawTextA( dc, on ? "On" : "Off", -1, &t, DT_SINGLELINE ); }
        if (focus) { RECT f = { x - 3, y - 3, x + w + 3, y + h + 3 }; DrawFocusRect( dc, &f ); }
        return;
    }
    switch (d->CtlID)
    {
    case ID_PRIMARY:
    {
        HBRUSH br = CreateSolidBrush( dis ? RGB(0x4A, 0x3A, 0x66) : down ? RGB(0x5F, 0x24, 0x96) : COL_ACCENT );
        FillRect( dc, &r, br ); DeleteObject( br );
        SelectObject( dc, g_font_bold ); SetTextColor( dc, dis ? COL_DIM : COL_TEXT );
        DrawTextA( dc, text, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE );
        if (focus) { RECT f = r; InflateRect( &f, -3, -3 ); DrawFocusRect( dc, &f ); }
        break;
    }
    case ID_SECONDARY:
    {
        HPEN pen = CreatePen( PS_SOLID, 2, COL_SUBTLE ), oldp;
        HBRUSH br = CreateSolidBrush( down ? COL_LIST : COL_CARD ), oldb;
        oldp = SelectObject( dc, pen ); oldb = SelectObject( dc, br );
        Rectangle( dc, r.left + 1, r.top + 1, r.right, r.bottom );
        SelectObject( dc, oldp ); SelectObject( dc, oldb ); DeleteObject( pen ); DeleteObject( br );
        SelectObject( dc, g_font_bold ); SetTextColor( dc, COL_TEXT );
        DrawTextA( dc, text, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE );
        if (focus) { RECT f = r; InflateRect( &f, -4, -4 ); DrawFocusRect( dc, &f ); }
        break;
    }
    case ID_BACK:
    {
        HPEN pen = CreatePen( PS_SOLID, 2, COL_TEXT ), oldp;
        int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        fill( dc, r.left, r.top, r.right, r.bottom, down ? COL_LIST : COL_CARD );
        oldp = SelectObject( dc, pen );
        MoveToEx( dc, cx + 9, cy, NULL ); LineTo( dc, cx - 9, cy );
        MoveToEx( dc, cx - 2, cy - 7, NULL ); LineTo( dc, cx - 9, cy ); LineTo( dc, cx - 2, cy + 7 );
        SelectObject( dc, oldp ); DeleteObject( pen );
        if (focus) { RECT f = r; InflateRect( &f, -2, -2 ); DrawFocusRect( dc, &f ); }
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
    case WM_MEASUREITEM:
    {
        MEASUREITEMSTRUCT *m = (MEASUREITEMSTRUCT *)lp;
        if (m->CtlType == ODT_LISTBOX) m->itemHeight = 44;
        return TRUE;
    }
    case WM_DRAWITEM: draw_item( (const DRAWITEMSTRUCT *)lp ); return TRUE;
    case WM_CTLCOLORLISTBOX:
        SetBkColor( (HDC)wp, COL_LIST );
        return (LRESULT)g_list_brush;
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case ID_PRIMARY: go_next(); break;
        case ID_SECONDARY: go_skip(); break;
        case ID_BACK: go_back(); break;
        case ID_LIST:
            if (HIWORD(wp) == LBN_SELCHANGE)
            {
                if (g_page == P_REGION) g_region_touched = TRUE;
                log_selection();
                if (g_page == P_NETWORK) { set_status( "", FALSE ); update_network_buttons(); }
            }
            else if (HIWORD(wp) == LBN_DBLCLK) go_next();
            break;
        default:
            if (LOWORD(wp) >= ID_TOGGLE && LOWORD(wp) < ID_TOGGLE + 4 && HIWORD(wp) == BN_CLICKED)
            {
                int i = LOWORD(wp) - ID_TOGGLE;
                g_privacy[i] = !g_privacy[i];
                log_line( "sg-oobe: toggle %s %s", g_privacy_items[i].key, g_privacy[i] ? "on" : "off" );
                InvalidateRect( g_toggle[i], NULL, FALSE );
            }
            break;
        }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_CLOSE) { KillTimer( hwnd, TIMER_CLOSE ); DestroyWindow( hwnd ); }
        else if (wp == TIMER_RESCAN && g_page == P_NETWORK && !g_busy && !g_listing_nets && !g_online) request_networks();
        return 0;
    case WM_CLOSE:
        return 0;   /* full screen, no way out but through it, as Windows' */
    case WM_BRIDGE_LINE:
        handle_line( (char *)lp );
        SecureZeroMemory( (char *)lp, strlen( (char *)lp ) );
        free( (char *)lp );
        return 0;
    case WM_BRIDGE_EOF:
        if (g_finished) { DestroyWindow( hwnd ); return 0; }
        g_busy = FALSE;
        set_page( P_FAILED );
        strcpy( g_text, "Setup lost contact with its service. Restart the PC to try again." );
        show( g_primary, FALSE );
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
    HWND c = CreateWindowExA( ex, cls, text, WS_CHILD | style, x, y, w, h, g_main, (HMENU)(INT_PTR)id,
                              GetModuleHandleA( NULL ), NULL );
    SendMessageA( c, WM_SETFONT, (WPARAM)g_font, TRUE );
    return c;
}

/* Enter and Escape: act on release, for a press seen on this page. */
static BOOL handle_key( MSG *m )
{
    HWND focus = GetFocus();
    char cls[32];

    if (m->wParam != VK_RETURN && m->wParam != VK_ESCAPE) return FALSE;
    if (m->message == WM_KEYDOWN || m->message == WM_SYSKEYDOWN)
    {
        if (!(m->lParam & (1 << 30))) g_armed = m->wParam;
        return TRUE;
    }
    if (m->message != WM_KEYUP && m->message != WM_SYSKEYUP) return FALSE;
    if (g_armed != m->wParam) return TRUE;
    g_armed = 0;
    if (m->wParam == VK_ESCAPE) { go_back(); return TRUE; }
    /* A focused button is pressed -- but not a privacy switch: Space turns
     * those, and Enter there accepts the page. */
    if (focus && GetClassNameA( focus, cls, sizeof(cls) ) && !strcmp( cls, "Button" ) &&
        GetDlgCtrlID( focus ) < ID_TOGGLE && IsWindowVisible( focus ) && IsWindowEnabled( focus ))
    {
        SendMessageA( focus, BM_CLICK, 0, 0 );
        return TRUE;
    }
    if (IsWindowVisible( g_primary ) && IsWindowEnabled( g_primary )) go_next();
    return TRUE;
}

int WINAPI WinMain( HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show_cmd )
{
    WNDCLASSA wc = {0};
    MSG msg;
    int sw, sh, cw, ch, bx, i;
    DWORD style = WS_CHILD | WS_TABSTOP;

    (void)prev; (void)show_cmd; (void)cmdline;
    g_in  = GetStdHandle( STD_INPUT_HANDLE );
    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    g_font_head  = make_font( 34, FW_LIGHT );
    g_font       = make_font( 18, FW_NORMAL );
    g_font_bold  = make_font( 18, FW_SEMIBOLD );
    g_font_small = make_font( 15, FW_NORMAL );
    g_font_list  = make_font( 19, FW_NORMAL );
    g_font_step  = make_font( 15, FW_SEMIBOLD );
    g_card_brush = CreateSolidBrush( COL_CARD );
    g_list_brush = CreateSolidBrush( COL_LIST );

    wc.lpfnWndProc   = wndproc;
    wc.hInstance     = inst;
    wc.hCursor       = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.lpszClassName = "SgOobe";
    RegisterClassA( &wc );

    sw = GetSystemMetrics( SM_CXSCREEN );
    sh = GetSystemMetrics( SM_CYSCREEN );
    cw = sw - 64 < 1060 ? sw - 64 : 1060;
    ch = sh - 64 < 640 ? sh - 64 : 640;
    SetRect( &g_card, (sw - cw) / 2, (sh - ch) / 2, (sw + cw) / 2, (sh + ch) / 2 );
    SetRect( &g_art, g_card.left, g_card.top, g_card.left + cw * 2 / 5, g_card.bottom );
    SetRect( &g_body, g_art.right + 56, g_card.top + 24, g_card.right - 48, g_card.bottom - 24 );
    g_main = CreateWindowExA( 0, "SgOobe", "Stained Glass OS setup", WS_POPUP | WS_CLIPCHILDREN,
                              0, 0, sw, sh, NULL, NULL, inst, NULL );

    bx = g_body.left;
    /* Creation order is tab order. */
    g_back = child( "BUTTON", "Back", style | BS_OWNERDRAW, 0, bx - 8, g_body.top, 40, 36, ID_BACK );
    g_list = child( "LISTBOX", "", style | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOTIFY | WS_VSCROLL | LBS_NOINTEGRALHEIGHT,
                    0, bx, g_body.top + 136, g_body.right - bx, g_body.bottom - g_body.top - 136 - 124, ID_LIST );
    g_name = child( "EDIT", "", style | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, bx, g_body.top + 136 + 78, 360, 30, ID_NAME );
    g_pass = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE, bx, g_body.top + 136 + 146, 360, 30, ID_PASS );
    g_pass2 = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE, bx, g_body.top + 136 + 214, 360, 30, ID_PASS2 );
    g_key = child( "EDIT", "", style | ES_AUTOHSCROLL | ES_PASSWORD, WS_EX_CLIENTEDGE, bx, g_body.bottom - 168, 360, 30, ID_KEY );
    for (i = 0; i < 4; i++)
        g_toggle[i] = child( "BUTTON", g_privacy_items[i].title, style | BS_OWNERDRAW, 0, bx, g_body.top + 136 + i * 64,
                             56, 44, ID_TOGGLE + i );
    g_secondary = child( "BUTTON", "Skip", style | BS_OWNERDRAW, 0, g_body.right - 272, g_body.bottom - 44, 128, 40, ID_SECONDARY );
    g_primary = child( "BUTTON", "Yes", style | BS_OWNERDRAW, 0, g_body.right - 128, g_body.bottom - 44, 128, 40, ID_PRIMARY );
    SendMessageA( g_list, WM_SETFONT, (WPARAM)g_font_list, TRUE );

    ShowWindow( g_main, SW_SHOW );
    set_page( P_REGION );
    UpdateWindow( g_main );
    CloseHandle( CreateThread( NULL, 0, reader_thread, g_main, 0, NULL ) );
    send_line( "HELLO" );
    send_line( "STATE" );

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
