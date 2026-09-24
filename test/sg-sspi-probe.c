/* Single sign-on from a Windows program (D1): does SSPI hand out Kerberos?
 *
 *   sg-sspi-probe.exe SPN        e.g. cifs/dc1.sgtest.lan
 *
 * Acquires the signed-in user's outbound credentials from the Kerberos and
 * Negotiate packages -- no password: they come from the ticket the user got at
 * sign-in -- names the principal they belong to, and asks for a context to
 * SPN, which only succeeds if the KDC issues a service ticket. Prints
 * KEY=VALUE lines for the gate.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define SECURITY_WIN32
#include <windows.h>
#include <security.h>
#include <stdio.h>
#include <string.h>

/* Which mechanism a token carries: Kerberos (its OID, as MIT or as Microsoft
 * writes it, inside SPNEGO or on its own) or NTLM (the NTLMSSP signature).
 * Negotiate falls back to NTLM without saying so; this says which it chose. */
static const char *mech_of( const unsigned char *p, unsigned long len )
{
    static const unsigned char krb5[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x02 };
    static const unsigned char mskrb5[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x82, 0xf7, 0x12, 0x01, 0x02, 0x02 };
    unsigned long i;

    if (!p) return "none";
    for (i = 0; i + sizeof(krb5) <= len; i++)
        if (!memcmp( p + i, krb5, sizeof(krb5) ) || !memcmp( p + i, mskrb5, sizeof(mskrb5) )) return "kerberos";
    for (i = 0; i + 8 <= len; i++)
        if (!memcmp( p + i, "NTLMSSP", 8 )) return "ntlm";
    return "unknown";
}

static void try_package( const wchar_t *package, const char *tag, const wchar_t *spn )
{
    CredHandle cred;
    CtxtHandle ctx;
    TimeStamp expiry;
    SecPkgCredentials_NamesW names;
    SecBuffer out = { 0, SECBUFFER_TOKEN, NULL };
    SecBufferDesc outdesc = { SECBUFFER_VERSION, 1, &out };
    ULONG attrs = 0;
    SECURITY_STATUS st;

    st = AcquireCredentialsHandleW( NULL, (wchar_t *)package, SECPKG_CRED_OUTBOUND, NULL, NULL, NULL, NULL,
                                    &cred, &expiry );
    printf( "Acquire%s=0x%08lx\n", tag, (unsigned long)st );
    if (st != SEC_E_OK) return;
    if (QueryCredentialsAttributesW( &cred, SECPKG_CRED_ATTR_NAMES, &names ) == SEC_E_OK && names.sUserName)
    {
        printf( "User%s=%ls\n", tag, names.sUserName );
        FreeContextBuffer( names.sUserName );
    }
    st = InitializeSecurityContextW( &cred, NULL, (wchar_t *)spn,
                                     ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_MUTUAL_AUTH | ISC_REQ_CONNECTION, 0,
                                     SECURITY_NATIVE_DREP, NULL, 0, &ctx, &outdesc, &attrs, &expiry );
    printf( "Init%s=0x%08lx\n", tag, (unsigned long)st );
    printf( "Token%s=%lu\n", tag, (unsigned long)out.cbBuffer );
    printf( "Mech%s=%s\n", tag, mech_of( out.pvBuffer, out.cbBuffer ) );
    if (out.pvBuffer) FreeContextBuffer( out.pvBuffer );
    if (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED) DeleteSecurityContext( &ctx );
    FreeCredentialsHandle( &cred );
}

int wmain( int argc, wchar_t **argv )
{
    if (argc < 2) { fprintf( stderr, "usage: sg-sspi-probe SPN\n" ); return 2; }
    try_package( L"Kerberos", "Kerberos", argv[1] );
    try_package( L"Negotiate", "Negotiate", argv[1] );
    return 0;
}
