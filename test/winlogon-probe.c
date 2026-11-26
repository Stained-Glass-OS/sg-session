/* test/winlogon-gate.sh's probe (wine-sg 9657, i0634): what the caller can do with the processes called
 * NAME (winlogon.exe): open them, open their token, duplicate it, and (launch) start a program with it in
 * its session -- what UltraVNC's and AnyDesk's services do. Usage: winlogon-probe.exe NAME [launch]
 * Lines: ME session | PROC pid session | OPEN_* ok err | TOKEN_* | DUP | TOKUSER | TOKSESSION | LAUNCH | CHILD */
#include <windows.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <stdio.h>

static void step(const char *what, BOOL ok) { printf("%s %d %lu\n", what, ok ? 1 : 0, ok ? 0 : GetLastError()); }

int main(int argc, char **argv)
{
    const char *name = argc > 1 ? argv[1] : "winlogon.exe";
    int launch = argc > 2 && !strcmp(argv[2], "launch");
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 pe = { sizeof(pe) };
    DWORD me = 0, mysess = 0, n = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &mysess);
    printf("ME session %lu\n", mysess);
    if (Process32First(snap, &pe)) do {
        if (_stricmp(pe.szExeFile, name)) continue;
        DWORD sess = 0, len; HANDLE p, t = 0, d = 0;
        n++;
        ProcessIdToSessionId(pe.th32ProcessID, &sess);
        printf("PROC %lu %lu\n", pe.th32ProcessID, sess);
        p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID); step("OPEN_LIMITED", p != 0); if (p) CloseHandle(p);
        p = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pe.th32ProcessID); step("OPEN_QUERY", p != 0); if (p) CloseHandle(p);
        p = OpenProcess(MAXIMUM_ALLOWED, FALSE, pe.th32ProcessID); step("OPEN_MAX", p != 0);
        if (!p) continue;
        step("TOKEN_QUERY", OpenProcessToken(p, TOKEN_QUERY, &t)); if (t) CloseHandle(t), t = 0;
        step("TOKEN_DUP", OpenProcessToken(p, TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY, &t));
        if (t) {
            char buf[256]; TOKEN_USER *tu = (void *)buf; char *s = NULL; DWORD ts = 0;
            step("DUP", DuplicateTokenEx(t, MAXIMUM_ALLOWED, NULL, SecurityIdentification, TokenPrimary, &d));
            if (GetTokenInformation(t, TokenUser, tu, sizeof(buf), &len) && ConvertSidToStringSidA(tu->User.Sid, &s)) printf("TOKUSER %s\n", s);
            if (GetTokenInformation(t, TokenSessionId, &ts, sizeof(ts), &len)) printf("TOKSESSION %lu\n", ts);
            if (launch && d) {
                STARTUPINFOA si = { sizeof(si) }; PROCESS_INFORMATION pi;
                char cmd[] = "C:\\windows\\system32\\cmd.exe /c exit 7";
                BOOL ok = CreateProcessAsUserA(d, NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
                step("LAUNCH", ok);
                if (ok) { DWORD c = 0; WaitForSingleObject(pi.hProcess, 60000); GetExitCodeProcess(pi.hProcess, &c);
                          ProcessIdToSessionId(pi.dwProcessId, &ts); printf("CHILD exit %lu session %lu\n", c, ts); }
            }
            CloseHandle(t); if (d) CloseHandle(d);
        }
        CloseHandle(p);
    } while (Process32Next(snap, &pe));
    printf("FOUND %lu\n", n);
    fflush(stdout);
    return 0;
}
