# xdg-desktop-portal-sg: screen sharing and remote control for Stained Glass OS.
# A fork of xdg-desktop-portal-wlr 0.7.1 (MIT, see LICENSE) with a RemoteDesktop
# portal: input goes through a connection the person allowed on the secure
# surface (sg-brokerd's "@capture", the compositor's SHADOW control).
#
#   make            build ./xdg-desktop-portal-sg
#   make clean

CC      ?= cc
PKGS     = libpipewire-0.3 wayland-client libsystemd inih gbm libdrm xkbcommon
CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -Wno-missing-braces -Wno-missing-field-initializers -Wno-unused-parameter \
           -D_POSIX_C_SOURCE=200809L -D_GNU_SOURCE -DHAVE_LIBSYSTEMD=1 -DSYSCONFDIR=\"/etc\" \
           -Iinclude -Ibuild $(shell pkg-config --cflags $(PKGS))
LDLIBS  += $(shell pkg-config --libs $(PKGS)) -lrt -lm
SCANNER  = $(shell pkg-config --variable=wayland_scanner wayland-scanner)
WLPROTO  = $(shell pkg-config --variable=pkgdatadir wayland-protocols)

XMLS     = $(WLPROTO)/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml \
           $(WLPROTO)/unstable/xdg-output/xdg-output-unstable-v1.xml \
           protocols/wlr-screencopy-unstable-v1.xml \
           protocols/wlr-virtual-pointer-unstable-v1.xml \
           protocols/virtual-keyboard-unstable-v1.xml
PROTO_C  = $(patsubst %.xml,build/%-protocol.c,$(notdir $(XMLS)))
PROTO_H  = $(patsubst %.xml,build/%-client-protocol.h,$(notdir $(XMLS)))

SRCS     = src/core/main.c src/core/logger.c src/core/config.c src/core/request.c src/core/session.c \
           src/core/timer.c src/core/timespec_util.c src/screenshot/screenshot.c \
           src/screencast/screencast.c src/screencast/screencast_common.c src/screencast/wlr_screencast.c \
           src/screencast/pipewire_screencast.c src/screencast/fps_limit.c \
           src/remotedesktop/remotedesktop.c src/remotedesktop/capture_grant.c
OBJS     = $(patsubst %.c,build/%.o,$(SRCS)) $(PROTO_C:.c=.o)

xdg-desktop-portal-sg: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

build/%-protocol.c: $(filter %.xml,$(XMLS))
	@mkdir -p build
	$(SCANNER) private-code $(filter %/$*.xml,$(XMLS)) $@
build/%-client-protocol.h: $(filter %.xml,$(XMLS))
	@mkdir -p build
	$(SCANNER) client-header $(filter %/$*.xml,$(XMLS)) $@

build/%.o: %.c $(PROTO_H)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<
build/%-protocol.o: build/%-protocol.c
	$(CC) $(CFLAGS) -c -o $@ $<

-include $(OBJS:.o=.d)

clean:
	rm -rf build xdg-desktop-portal-sg

.PHONY: clean
