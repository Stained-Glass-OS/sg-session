/*
 * Stained Glass OS: the person's leave to control their session.
 *
 * The compositor offers the virtual keyboard and pointer only to privileged
 * connections (sg-compositor lock.c, global_filter): no program in the
 * session can type or click for the person by itself, and neither can this
 * portal. It asks sg-brokerd ("@capture"), which puts the question to the
 * person on the secure surface -- where no program in the session can see,
 * click or type -- and, if they allow it, hands one end of a socketpair to
 * the session's compositor as a controlling shadow (SHADOW control): a
 * privileged connection, with a frame round the screen while it lasts, which
 * Ctrl+Alt+Del ends. The other end comes back here.
 *
 * Copyright (C) 2026 Stained Glass OS contributors
 * SPDX-License-Identifier: MIT
 */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "remotedesktop.h"
#include "logger.h"

#define BROKER_SOCK "/run/stained-glass-broker/broker.sock"

static int write_full(int fd, const void *buf, size_t len) {
	const char *p = buf;
	while (len) {
		ssize_t n = write(fd, p, len);
		if (n <= 0) {
			if (n < 0 && errno == EINTR) {
				continue;
			}
			return -1;
		}
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

/* What the prompt may show of the asking program: letters, digits and a few
 * marks, no longer than fits (the frontend's app id, or nothing). */
static void plain(const char *in, char *out, size_t cap) {
	size_t n = 0;
	for (; in && *in && n + 1 < cap && n < 64; in++) {
		char c = *in;
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strchr("-_. ", c)) {
			out[n++] = c;
		}
	}
	out[n] = 0;
}

int xdpw_capture_grant(const char *app_id, int control) {
	const char *sock = getenv("SG_PORTAL_BROKER_SOCK");
	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	char app[80], blob[512], cbuf[CMSG_SPACE(sizeof(int))];
	unsigned char verdict = 1;
	uint32_t len;
	int fd, sv[2], n;

	if (!sock) {
		sock = BROKER_SOCK;
	}
	plain(app_id, app, sizeof(app));
	n = snprintf(blob, sizeof(blob), "@capture%cCAPTURE_APP=%s%cCAPTURE_MODE=%s%c%cScreen sharing%c", 0, app, 0,
		control ? "control" : "view", 0, 0, 0);
	if (n <= 0 || n >= (int)sizeof(blob) || strlen(sock) >= sizeof(addr.sun_path)) {
		return -1;
	}
	len = (uint32_t)n;
	strcpy(addr.sun_path, sock);
	if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0) {
		return -1;
	}
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		logprint(ERROR, "remotedesktop: no broker at %s: %s", sock, strerror(errno));
		close(fd);
		return -1;
	}
	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0) {
		close(fd);
		return -1;
	}

	/* the length, with the compositor's end of the pair alongside */
	struct iovec iov = { .iov_base = &len, .iov_len = sizeof(len) };
	struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof(cbuf) };
	memset(cbuf, 0, sizeof(cbuf));
	struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
	cm->cmsg_level = SOL_SOCKET;
	cm->cmsg_type = SCM_RIGHTS;
	cm->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(cm), &sv[0], sizeof(int));
	if (sendmsg(fd, &mh, MSG_NOSIGNAL) != (ssize_t)sizeof(len) || write_full(fd, blob, len)) {
		goto refused;
	}
	close(sv[0]);
	sv[0] = -1;

	/* the person has as long as the broker gives them; this only guards a hang */
	struct pollfd p = { .fd = fd, .events = POLLIN };
	if (poll(&p, 1, 150 * 1000) != 1 || read(fd, &verdict, 1) != 1) {
		verdict = 1;
	}
	if (verdict != 0) {
		goto refused;
	}
	close(fd);
	logprint(INFO, "remotedesktop: allowed on the secure surface");
	return sv[1];

refused:
	logprint(INFO, "remotedesktop: not allowed (the person declined, or no broker)");
	if (sv[0] >= 0) {
		close(sv[0]);
	}
	close(sv[1]);
	close(fd);
	return -1;
}
