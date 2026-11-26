/* rsprobe: what a Windows program in some session can do to the screen, for
 * the remote-support gate (test/remote-support-vm.sh, ADR 0010 pattern A):
 *   grab          BitBlt the whole screen from the screen DC:
 *   igrab         the same on the input desktop (OpenInputDesktop +
 *                 SetThreadDesktop first, as VNC servers do): "DESK <name>" first
 *                 "GRAB <w> <h> <pixels not black> <amber pixels>"
 *   type TEXT     SendInput the characters (KEYEVENTF_UNICODE) and Return
 *   vtype TEXT    SendInput them as virtual keys (VkKeyScan), and Return
 * Run by the gate as the person's program, as an elevated one, and as a
 * service's helper. Never installed. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DWORD grab_rop = SRCCOPY;
static BOOL grab_display_dc;

static int grab(void)
{
    int x = GetSystemMetrics( SM_XVIRTUALSCREEN ), y = GetSystemMetrics( SM_YVIRTUALSCREEN );
    int w = GetSystemMetrics( SM_CXVIRTUALSCREEN ), h = GetSystemMetrics( SM_CYVIRTUALSCREEN );
    BITMAPINFO bi = { { sizeof(bi.bmiHeader), 0, 0, 1, 32, BI_RGB } };
    HDC screen = grab_display_dc ? CreateDCA( "\\\\.\\DISPLAY1", NULL, NULL, NULL ) : GetDC( NULL );
    HDC mem = CreateCompatibleDC( screen );
    unsigned int *bits;
    HBITMAP bmp;
    long nonblack = 0, amber = 0, i;

    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    if (!(bmp = CreateDIBSection( mem, &bi, DIB_RGB_COLORS, (void **)&bits, NULL, 0 ))) return 1;
    SelectObject( mem, bmp );
    if (!BitBlt( mem, 0, 0, w, h, screen, x, y, grab_rop ))
    {
        printf( "GRAB failed %lu\n", GetLastError() );
        return 1;
    }
    for (i = 0; i < (long)w * h; i++)
    {
        unsigned int p = bits[i] & 0xffffff;
        if (p) nonblack++;
        if (p == 0xffb400) amber++;
    }
    printf( "GRAB %d %d %ld %ld\n", w, h, nonblack, amber );
    return 0;
}

static void send_key( WORD vk, WCHAR ch, DWORD flags )
{
    INPUT in = { INPUT_KEYBOARD };
    in.ki.wVk = vk;
    in.ki.wScan = ch;
    in.ki.dwFlags = flags;
    SendInput( 1, &in, sizeof(in) );
    Sleep( 30 );
}

int main( int argc, char **argv )
{
    const char *p;

    if (argc < 2) return 2;
    if (!strcmp( argv[1], "grab" )) return grab();
    /* as TightVNC's WindowsScreenGrabber: SRCCOPY | CAPTUREBLT */
    /* as DXGI's Desktop Duplication reads it: the display's DC (CreateDC) */
    if (!strcmp( argv[1], "dgrab" )) { grab_display_dc = TRUE; grab_rop = SRCCOPY | CAPTUREBLT; return grab(); }
    if (!strcmp( argv[1], "cgrab" )) { grab_rop = SRCCOPY | CAPTUREBLT; return grab(); }
    if (!strcmp( argv[1], "bmi" ))
    {
        /* what VNC servers ask the screen DC first (TightVNC's Screen::getBMI) */
        struct { BITMAPINFOHEADER h; RGBQUAD c[256]; } bmi = { { sizeof(BITMAPINFOHEADER) } };
        HDC dc = GetDC( NULL );
        HBITMAP bm = GetCurrentObject( dc, OBJ_BITMAP );
        int r;
        SetLastError( 0 );
        r = GetDIBits( dc, bm, 0, 0, NULL, (BITMAPINFO *)&bmi, DIB_RGB_COLORS );
        printf( "BMI dc %p bm %p r %d err %lu bpp %d %ldx%ld\n", dc, bm, r, GetLastError(), bmi.h.biBitCount,
                bmi.h.biWidth, bmi.h.biHeight );
        /* TightVNC then deletes that bitmap and the DC, and asks again */
        DeleteObject( bm );
        DeleteDC( dc );
        dc = GetDC( NULL );
        bm = GetCurrentObject( dc, OBJ_BITMAP );
        SetLastError( 0 );
        r = GetDIBits( dc, bm, 0, 0, NULL, (BITMAPINFO *)&bmi, DIB_RGB_COLORS );
        printf( "BMI2 dc %p bm %p r %d err %lu\n", dc, bm, r, GetLastError() );
        return 0;
    }
    if (!strcmp( argv[1], "igrab" ))
    {
        HDESK desk = OpenInputDesktop( 0, TRUE, GENERIC_ALL );
        char name[256] = "";
        DWORD len;
        if (!desk) { printf( "DESK none %lu\n", GetLastError() ); return 1; }
        GetUserObjectInformationA( desk, UOI_NAME, name, sizeof(name), &len );
        printf( "DESK %s %d\n", name, SetThreadDesktop( desk ) );
        return grab();
    }
    if (argc < 3) return 2;
    for (p = argv[2]; *p; p++)
    {
        if (!strcmp( argv[1], "type" ))
        {
            send_key( 0, (WCHAR)(unsigned char)*p, KEYEVENTF_UNICODE );
            send_key( 0, (WCHAR)(unsigned char)*p, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP );
        }
        else
        {
            SHORT vks = VkKeyScanA( *p );
            if (vks & 0x100) send_key( VK_SHIFT, 0, 0 );
            send_key( LOBYTE( vks ), 0, 0 );
            send_key( LOBYTE( vks ), 0, KEYEVENTF_KEYUP );
            if (vks & 0x100) send_key( VK_SHIFT, 0, KEYEVENTF_KEYUP );
        }
    }
    send_key( VK_RETURN, 0, 0 );
    send_key( VK_RETURN, 0, KEYEVENTF_KEYUP );
    printf( "TYPED %u\n", (unsigned)strlen( argv[2] ) );
    return 0;
}
