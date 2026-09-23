/* sg-policy-probe -- print SHRestricted(<id>), to prove machine policy is
 * honoured and that HKLM (machine) precedence works (wine-sg 0025). Used by
 * sg-policy-check. Argument is the numeric RESTRICTIONS value.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    if (argc < 2) { printf("usage: sg-policy-probe <restriction-id>\n"); return 2; }
    printf("%lu\n", (unsigned long)SHRestricted((RESTRICTIONS)strtoul(argv[1], NULL, 0)));
    return 0;
}
