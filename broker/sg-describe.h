/* What the permission prompt shows as the program: the command line, as the
 * person would write it on Windows.
 *
 * The requester chose every byte of it, so it is shown, never trusted:
 * control characters are replaced, the program's own name can hold no quote
 * (so nothing after it can pass for part of it), and the whole is cut short
 * rather than allowed to push the real text off the panel.
 *
 * argv is what sg-elevate asked for ("wine" PROGRAM ARG..., or a Linux
 * program). An argument with blanks is shown in quotes, as the program gets
 * it. wine-sg 8400's "/sg-raw-args:TEXT" (the caller's arguments, exactly as
 * written) is shown as TEXT: the prompt showed the marker itself, and the
 * quotes in it as "?" (sg-control64's firewall-allow).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef SG_DESCRIBE_H
#define SG_DESCRIBE_H

#include <string.h>

#define SG_RAW_ARGS_MARK "/sg-raw-args:"

static void describe_put(char *out, size_t max, size_t *n, char c)
{
#ifdef SG_MUTANT_DESCRIBE_QUOTES
    if (c == '"') c = '?';   /* as before: quotes shown as "?" */
#endif
    if (*n + 1 < max) out[(*n)++] = ((unsigned char)c < 0x20 || c == 0x7f) ? '?' : c;
}

static void describe_program(char **argv, char *out, size_t max)
{
    size_t n = 0;
    int i = (argv[0] && !strcmp(argv[0], "wine") && argv[1]) ? 1 : 0, first = i;
    out[0] = 0;
    if (!max) return;
    for (; argv[i]; i++) {
        const char *p = argv[i];
        int quote;
        if (i > first) describe_put(out, max, &n, ' ');
#ifndef SG_MUTANT_DESCRIBE_MARKER
        if (i > first && !argv[i + 1] && !strncmp(p, SG_RAW_ARGS_MARK, strlen(SG_RAW_ARGS_MARK))) {
            for (p += strlen(SG_RAW_ARGS_MARK); *p; p++) describe_put(out, max, &n, *p);
            break;
        }
#endif
        quote = !*p || strpbrk(p, " \t") != NULL;
        if (quote) describe_put(out, max, &n, '"');
        for (; *p; p++) {
            if (*p == '"' && i == first) { describe_put(out, max, &n, '?'); continue; }
            if (*p == '"' && quote) describe_put(out, max, &n, '\\');
            describe_put(out, max, &n, *p);
        }
        if (quote) describe_put(out, max, &n, '"');
    }
    out[n] = 0;
    if (n > 200 && max > 201) strcpy(out + 197, "...");
}

#endif
