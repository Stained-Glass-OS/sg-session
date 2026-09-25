/* sg-sid-probe: the Windows identity of the process's user, for
 * sg-image's domain gate (make domain-test):
 *
 *   sg-sid-probe [FILE_DIR [NAME...]]
 *   sg-sid-probe acl SUBKEY NAME
 *
 * prints the token's user SID, primary group and groups; the user's name as
 * LookupAccountSid and GetUserNameEx(NameSamCompatible) give it; what
 * LookupAccountName says for each NAME; the owner of a file created in
 * FILE_DIR; whether HKEY_USERS\<SID> is the user's HKCU (a value written
 * through HKCU is read back there); and ProfileList\<SID>.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define SECURITY_WIN32
#include <windows.h>
#include <sddl.h>
#include <aclapi.h>
#include <security.h>
#include <stdio.h>

static char *sid_str( PSID sid )
{
    static char buf[4][256];
    static int n;
    char *out = buf[n++ & 3], *s = NULL;

    if (sid && ConvertSidToStringSidA( sid, &s ))
    {
        lstrcpynA( out, s, 256 );
        LocalFree( s );
    }
    else lstrcpyA( out, "(none)" );
    return out;
}

static void print_name( const char *key, PSID sid )
{
    char name[256], domain[256];
    DWORD nl = sizeof(name), dl = sizeof(domain);
    SID_NAME_USE use;

    if (LookupAccountSidA( NULL, sid, name, &nl, domain, &dl, &use ))
        printf( "%s=%s\\%s use=%d\n", key, domain, name, use );
    else printf( "%s=error %lu\n", key, GetLastError() );
}

/* sg-sid-probe acl SUBKEY NAME: a key under HKCU whose DACL grants only
 * NAME (a domain group) read; its ACE as LookupAccountSid names it, and
 * whether this user may then open it for reading (Opened=0/5) */
static int acl( const char *subkey, const char *name )
{
    EXPLICIT_ACCESS_A ea = { 0 };
    PACL dacl = NULL, back = NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    ACL_SIZE_INFORMATION info;
    char path[512];
    DWORD i, err;
    HKEY key;

    snprintf( path, sizeof(path), "Software\\StainedGlassSidProbe\\%s", subkey );
    RegDeleteKeyA( HKEY_CURRENT_USER, path );
    if ((err = RegCreateKeyExA( HKEY_CURRENT_USER, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL )))
    {
        printf( "Acl=error create %lu\n", err );
        return 1;
    }
    BuildExplicitAccessWithNameA( &ea, (char *)name, KEY_READ, SET_ACCESS, NO_INHERITANCE );
    if ((err = SetEntriesInAclA( 1, &ea, NULL, &dacl )))
    {
        printf( "Acl=error name %lu\n", err );
        return 1;
    }
    if ((err = SetSecurityInfo( key, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                NULL, NULL, dacl, NULL )))
    {
        printf( "Acl=error set %lu\n", err );
        return 1;
    }
    if ((err = GetSecurityInfo( key, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION, NULL, NULL, &back, NULL, &sd )))
    {
        printf( "Acl=error reread %lu\n", err );
        return 1;
    }
    RegCloseKey( key );
    GetAclInformation( back, &info, sizeof(info), AclSizeInformation );
    for (i = 0; i < info.AceCount; i++)
    {
        ACCESS_ALLOWED_ACE *ace;
        if (GetAce( back, i, (void **)&ace ) && ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE)
        {
            printf( "Ace=%s\n", sid_str( &ace->SidStart ) );
            print_name( "AceName", &ace->SidStart );
        }
    }
    err = RegOpenKeyExA( HKEY_CURRENT_USER, path, 0, KEY_READ, &key );
    printf( "Opened=%lu\n", err );
    if (!err) RegCloseKey( key );
    return 0;
}

int main( int argc, char **argv )
{
    char buffer[8192], user_sid[256], path[MAX_PATH], sam[512];
    TOKEN_USER *user = (TOKEN_USER *)buffer;
    TOKEN_GROUPS *groups;
    TOKEN_PRIMARY_GROUP *primary;
    ULONG sam_len = sizeof(sam);
    DWORD len, i;
    HANDLE token, file;
    HKEY key;
    int n;

    if (argc == 4 && !strcmp( argv[1], "acl" )) return acl( argv[2], argv[3] );
    if (!OpenProcessToken( GetCurrentProcess(), TOKEN_QUERY, &token )) return 1;
    GetTokenInformation( token, TokenUser, buffer, sizeof(buffer), &len );
    lstrcpyA( user_sid, sid_str( user->User.Sid ) );
    printf( "UserSid=%s\n", user_sid );
    print_name( "UserName", user->User.Sid );
    if (GetUserNameExA( NameSamCompatible, sam, &sam_len )) printf( "SamCompatible=%s\n", sam );
    else printf( "SamCompatible=error %lu\n", GetLastError() );

    if (GetTokenInformation( token, TokenPrimaryGroup, buffer, sizeof(buffer), &len ))
    {
        primary = (TOKEN_PRIMARY_GROUP *)buffer;
        printf( "PrimaryGroup=%s\n", sid_str( primary->PrimaryGroup ) );
        print_name( "PrimaryGroupName", primary->PrimaryGroup );
    }
    if (GetTokenInformation( token, TokenGroups, buffer, sizeof(buffer), &len ))
    {
        groups = (TOKEN_GROUPS *)buffer;
        for (i = 0; i < groups->GroupCount; i++)
            printf( "Group=%s\n", sid_str( groups->Groups[i].Sid ) );
    }

    for (n = 2; n < argc; n++)
    {
        BYTE sid[SECURITY_MAX_SID_SIZE];
        char domain[256];
        DWORD sl = sizeof(sid), dl = sizeof(domain);
        SID_NAME_USE use;

        if (LookupAccountNameA( NULL, argv[n], sid, &sl, domain, &dl, &use ))
            printf( "Name[%s]=%s %s use=%d\n", argv[n], sid_str( sid ), domain, use );
        else printf( "Name[%s]=error %lu\n", argv[n], GetLastError() );
    }

    if (argc > 1)
    {
        PSID owner = NULL, group = NULL;
        PSECURITY_DESCRIPTOR sd = NULL;

        snprintf( path, sizeof(path), "%s\\sg-sid-%lu.txt", argv[1], GetCurrentProcessId() );
        file = CreateFileA( path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL );
        if (file != INVALID_HANDLE_VALUE)
        {
            if (!GetSecurityInfo( file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION,
                                  &owner, &group, NULL, NULL, &sd ))
                printf( "FileOwner=%s\nFileGroup=%s\n", sid_str( owner ), sid_str( group ) );
            else printf( "FileOwner=error\n" );
            CloseHandle( file );
            DeleteFileA( path );
            LocalFree( sd );
        }
        else printf( "FileOwner=error create %lu\n", GetLastError() );
    }

    /* HKCU is HKEY_USERS\<SID> */
    if (!RegCreateKeyExA( HKEY_CURRENT_USER, "Software\\StainedGlassSidProbe", 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL ))
    {
        DWORD v = GetCurrentProcessId(), got = 0, size = sizeof(got);
        char sub[512];

        RegSetValueExA( key, "Pid", 0, REG_DWORD, (BYTE *)&v, sizeof(v) );
        RegCloseKey( key );
        snprintf( sub, sizeof(sub), "%s\\Software\\StainedGlassSidProbe", user_sid );
        if (!RegGetValueA( HKEY_USERS, sub, "Pid", RRF_RT_REG_DWORD, NULL, &got, &size ) && got == v)
            printf( "HkcuIsHkuSid=1\n" );
        else printf( "HkcuIsHkuSid=0\n" );
        size = sizeof(got);
        if (!RegGetValueA( HKEY_CURRENT_USER, "Software\\StainedGlassSidProbe", "Earlier", RRF_RT_REG_DWORD, NULL, &got, &size ))
            printf( "Earlier=%lu\n", got );
        v = 7;
        if (!RegOpenKeyExA( HKEY_CURRENT_USER, "Software\\StainedGlassSidProbe", 0, KEY_SET_VALUE, &key ))
        {
            RegSetValueExA( key, "Earlier", 0, REG_DWORD, (BYTE *)&v, sizeof(v) );
            RegCloseKey( key );
        }
    }
    else printf( "HkcuIsHkuSid=error\n" );

    {
        char sub[512], profile[MAX_PATH];
        DWORD size = sizeof(profile);
        snprintf( sub, sizeof(sub), "Software\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\%s", user_sid );
        if (!RegGetValueA( HKEY_LOCAL_MACHINE, sub, "ProfileImagePath", RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND,
                           NULL, profile, &size ))
            printf( "ProfileImagePath=%s\n", profile );
        else printf( "ProfileImagePath=(none)\n" );
    }
    return 0;
}
