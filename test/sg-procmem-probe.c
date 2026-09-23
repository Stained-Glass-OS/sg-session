/* sg-procmem-probe -- prove one process can read and write another's memory.
 *
 * Parent spawns a copy of itself (child mode), which allocates a page, prints
 * its pid and the page address, and waits. The parent opens the child, writes
 * a pattern with WriteProcessMemory, reads it back with ReadProcessMemory, and
 * checks it matches. On Stained Glass this only works when the user's
 * sg-procagent is running (ADR 0014); it is the gate for debt D16/D19.
 * Prints exactly "PROCMEM OK" on success.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child"))
    {
        void *buf = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!buf) { printf("child alloc failed\n"); return 1; }
        memset(buf, 0, 16);
        printf("%lu %p\n", GetCurrentProcessId(), buf);
        fflush(stdout);
        Sleep(30000);
        return 0;
    }

    char cmd[MAX_PATH * 2];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE rd, wr;

    if (!CreatePipe(&rd, &wr, &sa, 0)) { printf("pipe failed\n"); return 1; }
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = wr;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    snprintf(cmd, sizeof(cmd), "\"%s\" child", argv[0]);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
    { printf("CreateProcess failed %lu\n", GetLastError()); return 1; }
    CloseHandle(wr);

    char line[128]; DWORD got = 0, off = 0;
    while (off < sizeof(line) - 1 && ReadFile(rd, line + off, 1, &got, NULL) && got)
    { if (line[off] == '\n') break; off++; }
    line[off] = 0;

    DWORD cpid = 0; unsigned long long addr = 0;
    if (sscanf(line, "%lu %llx", &cpid, &addr) != 2 || !addr)
    { printf("bad child handshake: '%s'\n", line); TerminateProcess(pi.hProcess, 1); return 1; }

    HANDLE child = OpenProcess(PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION,
                               FALSE, cpid);
    if (!child) { printf("OpenProcess failed %lu\n", GetLastError()); TerminateProcess(pi.hProcess, 1); return 1; }

    const char pattern[] = "SG-PROCMEM-42";
    SIZE_T n = 0;
    int ok = 1;
    if (!WriteProcessMemory(child, (void *)(UINT_PTR)addr, pattern, sizeof(pattern), &n) || n != sizeof(pattern))
    { printf("WriteProcessMemory failed %lu\n", GetLastError()); ok = 0; }

    char back[sizeof(pattern)] = {0};
    if (ok && (!ReadProcessMemory(child, (void *)(UINT_PTR)addr, back, sizeof(back), &n) || n != sizeof(back)))
    { printf("ReadProcessMemory failed %lu\n", GetLastError()); ok = 0; }

    if (ok && memcmp(pattern, back, sizeof(pattern)))
    { printf("readback mismatch: '%s'\n", back); ok = 0; }

    CloseHandle(child);
    TerminateProcess(pi.hProcess, 0);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd);
    if (ok) printf("PROCMEM OK\n");
    return ok ? 0 : 1;
}
