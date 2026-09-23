/* sg-token-probe: can this process obtain an administrator's token?
 *
 * Tries each way the Windows side has of getting one -- the process's own
 * token (which a requireAdministrator manifest used to swap for SYSTEM's), the
 * linked token, NtCreateToken, and Wine's own ProcessWineGrantAdminToken --
 * and prints one line per attempt: GRANTED or DENIED. For a standard user
 * every line must say DENIED; for SYSTEM they say GRANTED. sg-token-check
 * reads the lines. Built twice: plain, and with a requireAdministrator
 * manifest (sg-token-probe-admin.exe). Multi-user debt D17.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <winternl.h>
#include <sddl.h>
#include <stdio.h>

typedef NTSTATUS (WINAPI *pNtCreateToken)(HANDLE*, ACCESS_MASK, OBJECT_ATTRIBUTES*, TOKEN_TYPE, LUID*,
    LARGE_INTEGER*, TOKEN_USER*, TOKEN_GROUPS*, TOKEN_PRIVILEGES*, TOKEN_OWNER*, TOKEN_PRIMARY_GROUP*,
    TOKEN_DEFAULT_DACL*, TOKEN_SOURCE*);
typedef NTSTATUS (WINAPI *pNtSetInformationProcess)(HANDLE, ULONG, void*, ULONG);

static BOOL token_is_admin(HANDLE tok)
{
    BYTE sid[SECURITY_MAX_SID_SIZE]; DWORD n = sizeof(sid); BOOL member = FALSE;
    CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, sid, &n);
    HANDLE imp;
    if (!DuplicateToken(tok, SecurityIdentification, &imp)) return FALSE;
    CheckTokenMembership(imp, sid, &member);
    CloseHandle(imp);
    return member;
}
static void report_self(const char *what)
{
    HANDLE tok; char buf[256]; DWORD len; WCHAR *s = L"?";
    OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &tok);
    if (GetTokenInformation(tok, TokenUser, buf, sizeof(buf), &len)) ConvertSidToStringSidW(((TOKEN_USER *)buf)->User.Sid, &s);
    printf("%-8s %s (process token %ls)\n", token_is_admin(tok) ? "GRANTED" : "DENIED", what, s);
    CloseHandle(tok);
}
int main(int argc, char **argv)
{
    HANDLE tok, ntdll = GetModuleHandleA("ntdll.dll");
    TOKEN_LINKED_TOKEN linked; DWORD len;

    report_self(argc > 1 ? argv[1] : "the process's own token");

    OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok);
    if (GetTokenInformation(tok, TokenLinkedToken, &linked, sizeof(linked), &len) && linked.LinkedToken)
        printf("%-8s the linked token\n", token_is_admin(linked.LinkedToken) ? "GRANTED" : "DENIED");
    else
        printf("DENIED   the linked token (error %lu)\n", GetLastError());
    CloseHandle(tok);

    {
        pNtCreateToken create = (pNtCreateToken)GetProcAddress(ntdll, "NtCreateToken");
        BYTE sys[SECURITY_MAX_SID_SIZE], adm[SECURITY_MAX_SID_SIZE]; DWORD n1 = sizeof(sys), n2 = sizeof(adm);
        TOKEN_USER user; TOKEN_GROUPS groups; TOKEN_PRIVILEGES privs = {0}; TOKEN_OWNER owner; TOKEN_PRIMARY_GROUP pg;
        TOKEN_SOURCE src = {"sgprobe", {0}}; LUID luid = {0x3e7, 0}; LARGE_INTEGER exp = {{0xffffffff, 0x7fffffff}};
        OBJECT_ATTRIBUTES attr = {sizeof(attr)}; HANDLE newtok = NULL; NTSTATUS st;
        CreateWellKnownSid(WinLocalSystemSid, NULL, sys, &n1);
        CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, adm, &n2);
        user.User.Sid = sys; user.User.Attributes = 0;
        groups.GroupCount = 1; groups.Groups[0].Sid = adm;
        groups.Groups[0].Attributes = SE_GROUP_ENABLED | SE_GROUP_ENABLED_BY_DEFAULT | SE_GROUP_MANDATORY;
        owner.Owner = sys; pg.PrimaryGroup = adm;
        st = create(&newtok, TOKEN_ALL_ACCESS, &attr, TokenPrimary, &luid, &exp, &user, &groups, &privs,
                    &owner, &pg, NULL, &src);
        printf("%-8s NtCreateToken for SYSTEM + Administrators (status %#lx)\n", st ? "DENIED" : "GRANTED", st);
        if (!st) CloseHandle(newtok);
    }
    {
        pNtSetInformationProcess set = (pNtSetInformationProcess)GetProcAddress(ntdll, "NtSetInformationProcess");
        NTSTATUS st = set(GetCurrentProcess(), 1002 /* ProcessWineGrantAdminToken */, NULL, 0);
        report_self("after ProcessWineGrantAdminToken");
        (void)st;
    }
    return 0;
}
