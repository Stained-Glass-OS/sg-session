/* sg-polimport -- convert a Windows registry.pol (Group Policy) file to a .reg
 * file on stdout, so sg-session can apply domain/GPO-authored policy the same
 * way as its own .reg drop-ins. All keys are written under HKEY_LOCAL_MACHINE
 * (machine policy); on Stained Glass that branch is administrator-owned, so
 * this only takes effect when run as the SYSTEM account at boot.
 *
 * registry.pol format: the signature "PReg" and a version DWORD, then entries
 *   [ key ; value ; type ; size ; data ]
 * where the brackets and semicolons are literal UTF-16LE characters, key and
 * value are NUL-terminated UTF-16LE, type and size are little-endian DWORDs,
 * and data is `size` bytes. Values are emitted as hex(type): so every type is
 * represented losslessly without .reg string escaping.
 *
 * Usage: sg-polimport FILE.pol   (writes a .reg file to stdout)
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *g;      /* whole file */
static size_t glen, pos;

static int need(size_t n) { return pos + n <= glen; }
static uint16_t u16(void) { uint16_t v = g[pos] | (g[pos+1] << 8); pos += 2; return v; }
static uint32_t u32(void) { uint32_t v = g[pos] | (g[pos+1]<<8) | (g[pos+2]<<16) | ((uint32_t)g[pos+3]<<24); pos += 4; return v; }

/* read a UTF-16LE string until its NUL; write it as UTF-8 (BMP, good enough for
 * registry key and value names) into out (out_sz bytes). Returns 0 on success. */
static int wstr(char *out, size_t out_sz)
{
    size_t o = 0;
    for (;;) {
        if (!need(2)) return -1;
        uint16_t c = u16();
        if (!c) break;
        if (c < 0x80) { if (o + 1 >= out_sz) return -1; out[o++] = (char)c; }
        else if (c < 0x800) { if (o + 2 >= out_sz) return -1; out[o++] = 0xC0|(c>>6); out[o++] = 0x80|(c&0x3F); }
        else { if (o + 3 >= out_sz) return -1; out[o++] = 0xE0|(c>>12); out[o++] = 0x80|((c>>6)&0x3F); out[o++] = 0x80|(c&0x3F); }
    }
    out[o] = 0;
    return 0;
}

/* expect a literal UTF-16LE character */
static int expect(uint16_t want) { return need(2) && u16() == want; }

int main(int argc, char **argv)
{
    FILE *f;
    long sz;
    char key[8192], val[2048];

    if (argc < 2) { fprintf(stderr, "usage: sg-polimport FILE.pol\n"); return 2; }
    if (!(f = fopen(argv[1], "rb"))) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 8) { fprintf(stderr, "sg-polimport: too short\n"); fclose(f); return 1; }
    g = malloc(sz); glen = sz;
    if (fread(g, 1, sz, f) != (size_t)sz) { fclose(f); return 1; }
    fclose(f);

    if (memcmp(g, "PReg", 4) != 0) { fprintf(stderr, "sg-polimport: not a registry.pol file\n"); return 1; }
    pos = 8;  /* signature + version */

    printf("Windows Registry Editor Version 5.00\n\n");
    while (pos < glen) {
        uint32_t type, dsize, i;
        if (!expect('[')) break;
        if (wstr(key, sizeof(key)) || !expect(';')) break;
        if (wstr(val, sizeof(val)) || !expect(';')) break;
        if (!need(4)) break;
        type = u32();
        if (!expect(';')) break;
        if (!need(4)) break;
        dsize = u32();
        if (!expect(';')) break;
        if (dsize > glen - pos) break;

        printf("[HKEY_LOCAL_MACHINE\\%s]\n", key);
        /* GPO deletion markers begin with "**del." etc.; pass the value name
         * through -- an administrator's tooling authored it. */
        printf("\"%s\"=hex(%lx):", val, (unsigned long)type);
        for (i = 0; i < dsize; i++) printf("%s%02x", i ? "," : "", g[pos + i]);
        printf("\n\n");
        pos += dsize;
        if (!expect(']')) break;
    }
    free(g);
    return 0;
}
