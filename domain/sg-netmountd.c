/* sg-netmountd -- network drives and UNC paths for Windows programs.
 *
 * Stained Glass OS (D1 follow-on: domain drive maps and logon scripts).
 * Windows reaches \\server\share\... directly and maps drive letters to
 * shares per logon session. Here a share is a kernel CIFS mount under
 *
 *     /run/stained-glass-net/unc/<server>/<share>
 *
 * mounted "multiuser" with Kerberos: every user who touches it is a separate
 * SMB session on their *own* ticket (cifs.upcall finds it by uid), so the
 * file server decides what each user may do -- the mount grants nothing.
 * A user's drive letters are symlinks in
 *
 *     /run/stained-glass-net/drives/<uid>/<letter>:
 *
 * which wine-sg's ntdll consults before the prefix's dosdevices (patch 0056),
 * so H: is alice's home share and nobody else's.
 *
 * Mounting needs root, so this runs as root, one instance per connection
 * (sg-netmountd.socket, Accept=yes), and acts only for the peer's uid
 * (SO_PEERCRED). The first mount of a share is made with the requester's
 * ticket (cruid); without a ticket the mount fails and nothing is created.
 * Requests are one line each:
 *
 *     MOUNT <server> <share>                   -> OK <path> | ERR <errno> <why>
 *     MAP <letter> <server> <share> [<dir>...] -> OK <path> | ERR ...
 *     UNMAP <letter>                           -> OK | ERR ...
 *
 * Root may also run it directly for a user (the PAM session helper does):
 *     sg-netmountd --uid UID MAP H dc1 home alice
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <resolv.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define NET_ROOT   "/run/stained-glass-net"
#define UNC_ROOT   NET_ROOT "/unc"
#define DRIVE_ROOT NET_ROOT "/drives"
#define ROLE_FILE  "/etc/stained-glass/role"

static FILE *out;

static void reply(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(out, fmt, ap);
    va_end(ap);
    fputc('\n', out);
    fflush(out);
}

/* A server: a DNS name, a NetBIOS name or an IPv4 address. */
static int valid_server(const char *s)
{
    size_t n = strlen(s), i;
    if (!n || n > 253 || s[0] == '.' || s[0] == '-') return 0;
    for (i = 0; i < n; i++)
        if (!isalnum((unsigned char)s[i]) && s[i] != '.' && s[i] != '-') return 0;
    return strstr(s, "..") == NULL;
}

/* A share or directory name: what Windows allows in one, and never . or .. */
static int valid_component(const char *s)
{
    size_t n = strlen(s), i;
    if (!n || n > 80 || !strcmp(s, ".") || !strcmp(s, "..")) return 0;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 32 || c == 127 || strchr("\\/:*?\"<>|[]+=;,", c)) return 0;
    }
    return 1;
}

static void lower(char *s) { for (; *s; s++) *s = (char)tolower((unsigned char)*s); }

/* The domain this machine belongs to, from sg-domain-join's role file. */
static void read_role(char *realm, size_t rlen, char *domain, size_t dlen)
{
    char line[256];
    FILE *f = fopen(ROLE_FILE, "r");
    realm[0] = domain[0] = 0;
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "realm=", 6)) snprintf(realm, rlen, "%s", line + 6);
        else if (!strncmp(line, "domain=", 7)) snprintf(domain, dlen, "%s", line + 7);
    }
    fclose(f);
    lower(realm);
    lower(domain);
}

/* \\DOMAIN\share (NETLOGON, SYSVOL, domain DFS) means a domain controller:
 * ask DNS for one, as Windows' DFS client does. */
static int find_dc(const char *dnsdomain, char *host, size_t len)
{
    unsigned char answer[4096];
    char name[300];
    ns_msg msg;
    ns_rr rr;
    int n, i;

    snprintf(name, sizeof(name), "_ldap._tcp.dc._msdcs.%s", dnsdomain);
    if ((n = res_search(name, ns_c_in, ns_t_srv, answer, sizeof(answer))) < 0) return 0;
    if (ns_initparse(answer, n, &msg) < 0) return 0;
    for (i = 0; i < ns_msg_count(msg, ns_s_an); i++) {
        if (ns_parserr(&msg, ns_s_an, i, &rr) < 0 || ns_rr_type(rr) != ns_t_srv) continue;
        if (ns_rr_rdlen(rr) < 7) continue;
        if (dn_expand(ns_msg_base(msg), ns_msg_end(msg), ns_rr_rdata(rr) + 6, host, (int)len) < 0) continue;
        return 1;
    }
    return 0;
}

/* The host to mount from: a domain name becomes a domain controller, and a
 * short name gets the domain's DNS suffix so Kerberos finds cifs/<fqdn>. */
static int resolve(const char *server, char *host, size_t hlen, char *ip, size_t iplen)
{
    char realm[256], domain[64];
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM, .ai_flags = AI_CANONNAME }, *ai;

    read_role(realm, sizeof(realm), domain, sizeof(domain));
    if (realm[0] && (!strcmp(server, realm) || (domain[0] && !strcmp(server, domain)))) {
        if (!find_dc(realm, host, hlen)) return 0;
    } else if (!strchr(server, '.') && realm[0] && !inet_aton(server, &(struct in_addr){0})) {
        snprintf(host, hlen, "%s.%s", server, realm);
        if (getaddrinfo(host, NULL, &hints, &ai)) snprintf(host, hlen, "%s", server);
        else freeaddrinfo(ai);
    } else snprintf(host, hlen, "%s", server);

    if (getaddrinfo(host, NULL, &hints, &ai)) return 0;
    inet_ntop(AF_INET, &((struct sockaddr_in *)ai->ai_addr)->sin_addr, ip, (socklen_t)iplen);
    freeaddrinfo(ai);
    lower(host);
    return 1;
}

static int is_mounted(const char *path)
{
    char line[4096], mp[4096];
    int found = 0;
    FILE *f = fopen("/proc/self/mountinfo", "r");
    if (!f) return 0;
    while (!found && fgets(line, sizeof(line), f)) {
        /* field 5 is the mount point, with spaces as \040 */
        char *p = line, *q;
        int field;
        for (field = 1; field < 5 && p; field++) { p = strchr(p, ' '); if (p) p++; }
        if (!p) continue;
        for (q = mp; *p && *p != ' ' && q < mp + sizeof(mp) - 1; ) {
            if (p[0] == '\\' && p[1] >= '0' && p[1] <= '7' && p[2] && p[3]) {
                *q++ = (char)(((p[1] - '0') << 6) | ((p[2] - '0') << 3) | (p[3] - '0'));
                p += 4;
            } else *q++ = *p++;
        }
        *q = 0;
        found = !strcmp(mp, path);
    }
    fclose(f);
    return found;
}

static int mkdirs(const char *path, mode_t mode)
{
    char buf[4096], *p;
    snprintf(buf, sizeof(buf), "%s", path);
    for (p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(buf, mode) && errno != EEXIST) return -1;
        *p = '/';
    }
    return (mkdir(buf, mode) && errno != EEXIST) ? -1 : 0;
}

/* Mount //server/share for uid (its ticket), unless it is mounted already. */
static int do_mount(uid_t uid, char *server, char *share, char *path, size_t plen)
{
    char host[256], ip[64], unc[600], opts[512];
    pid_t pid;
    int status;

    lower(server);
    lower(share);
    snprintf(path, plen, "%s/%s/%s", UNC_ROOT, server, share);
    if (is_mounted(path)) return 0;
    if (!resolve(server, host, sizeof(host), ip, sizeof(ip))) { errno = EHOSTUNREACH; return -1; }
    if (mkdirs(path, 0755)) return -1;

    snprintf(unc, sizeof(unc), "//%s/%s", host, share);
    /* The server checks each user; locally everyone may try. */
    snprintf(opts, sizeof(opts), "multiuser,sec=krb5,cruid=%u,ip=%s,noperm,file_mode=0777,dir_mode=0777,nosuid,nodev",
             (unsigned)uid, ip);
    if ((pid = fork()) < 0) return -1;
    if (!pid) {
        char *argv[] = { "mount", "-t", "cifs", unc, path, "-o", opts, NULL };
        char *envp[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL };
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) { dup2(null, 0); dup2(null, 1); }
        execve("/usr/bin/mount", argv, envp);
        execve("/bin/mount", argv, envp);
        _exit(127);
    }
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR);
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        rmdir(path);
        errno = EACCES;
        return -1;
    }
    return 0;
}

static int valid_letter(const char *s, char *letter)
{
    if (strlen(s) != 1 || !isalpha((unsigned char)s[0])) return 0;
    *letter = (char)tolower((unsigned char)s[0]);
    return *letter != 'c' && *letter != 'z';   /* the system and Unix drives stay */
}

static int handle(uid_t uid, char *line)
{
    char *argv[16], *save = NULL, *tok, path[4096], letter;
    int argc = 0, i;

    line[strcspn(line, "\r\n")] = 0;
    for (tok = strtok_r(line, "\t", &save); tok && argc < 16; tok = strtok_r(NULL, "\t", &save))
        argv[argc++] = tok;
    if (!argc) return 0;

    if (!strcmp(argv[0], "MOUNT") && argc == 3) {
        if (!valid_server(argv[1]) || !valid_component(argv[2])) { reply("ERR %d bad name", EINVAL); return 0; }
        if (do_mount(uid, argv[1], argv[2], path, sizeof(path))) { reply("ERR %d cannot mount", errno); return 0; }
        reply("OK %s", path);
        return 0;
    }
    if (!strcmp(argv[0], "MAP") && argc >= 4) {
        char dir[64], link[128], target[4096];
        if (!valid_letter(argv[1], &letter) || !valid_server(argv[2])) { reply("ERR %d bad name", EINVAL); return 0; }
        for (i = 3; i < argc; i++) if (!valid_component(argv[i])) { reply("ERR %d bad name", EINVAL); return 0; }
        if (do_mount(uid, argv[2], argv[3], path, sizeof(path))) { reply("ERR %d cannot mount", errno); return 0; }
        snprintf(target, sizeof(target), "%s", path);
        for (i = 4; i < argc; i++) {
            size_t n = strlen(target);
            snprintf(target + n, sizeof(target) - n, "/%s", argv[i]);
        }
        snprintf(dir, sizeof(dir), "%s/%u", DRIVE_ROOT, (unsigned)uid);
        if (mkdirs(DRIVE_ROOT, 0755) || (mkdir(dir, 0755) && errno != EEXIST)) { reply("ERR %d no drive directory", errno); return 0; }
        snprintf(link, sizeof(link), "%s/%c:", dir, letter);
        unlink(link);
        if (symlink(target, link)) { reply("ERR %d cannot map", errno); return 0; }
        reply("OK %s", target);
        return 0;
    }
    if (!strcmp(argv[0], "UNMAP") && argc == 2) {
        char link[128];
        if (!valid_letter(argv[1], &letter)) { reply("ERR %d bad name", EINVAL); return 0; }
        snprintf(link, sizeof(link), "%s/%u/%c:", DRIVE_ROOT, (unsigned)uid, letter);
        if (unlink(link) && errno != ENOENT) { reply("ERR %d cannot unmap", errno); return 0; }
        reply("OK");
        return 0;
    }
    reply("ERR %d unknown request", EINVAL);
    return 0;
}

int main(int argc, char **argv)
{
    char line[2048];
    uid_t uid;

    out = stdout;
    umask(022);
    if (argc >= 3 && !strcmp(argv[1], "--uid")) {
        /* root acting for a user: the request is the rest of the command line */
        char req[2048] = "";
        int i;
        if (getuid() != 0) { fprintf(stderr, "sg-netmountd: --uid is for root\n"); return 2; }
        uid = (uid_t)strtoul(argv[2], NULL, 10);
        for (i = 3; i < argc; i++) {
            size_t n = strlen(req);
            snprintf(req + n, sizeof(req) - n, "%s%s", i > 3 ? "\t" : "", argv[i]);
        }
        handle(uid, req);
        return 0;
    }

    /* socket activation: fd 0 is the connection */
    {
        struct ucred cred;
        socklen_t len = sizeof(cred);
        if (getsockopt(0, SOL_SOCKET, SO_PEERCRED, &cred, &len)) { fprintf(stderr, "sg-netmountd: not a socket\n"); return 2; }
        uid = cred.uid;
    }
    /* A few requests per connection at most; each is a line. */
    {
        FILE *in = fdopen(0, "r");
        int n = 0;
        if (!in) return 2;
        while (n++ < 32 && fgets(line, sizeof(line), in)) handle(uid, line);
    }
    return 0;
}
