# sg-session -- session glue for Stained Glass OS.
#
# Targets that matter:
#   make test     lint + a real headless session gate on this machine
#   make deb      build the .deb
#   make install  install into $(DESTDIR) (used by the deb and by sg-image)

PREFIX      ?= /usr
DESTDIR     ?=
BINDIR       = $(DESTDIR)$(PREFIX)/bin
LIBDIR       = $(DESTDIR)$(PREFIX)/lib/stained-glass
SHAREDIR     = $(DESTDIR)$(PREFIX)/share/stained-glass
UNITDIR      = $(DESTDIR)$(PREFIX)/lib/systemd/system
TMPFILESDIR  = $(DESTDIR)$(PREFIX)/lib/tmpfiles.d
UDEVDIR      = $(DESTDIR)$(PREFIX)/lib/udev/rules.d

BINS         = bin/sg-install domain/sg-dc-provision domain/sg-domain-join domain/sg-gpupdate bin/sg-prefix-init bin/sg-session-start bin/sg-session-check \
               bin/sg-multiuser-check bin/sg-wineserver bin/sg-services-start \
               bin/sg-install-d3d bin/sg-d3d-check \
               bin/sg-install-apps bin/sg-apps-check \
               bin/sg-update-prepare bin/sg-file-access-check \
               bin/sg-token-check bin/sg-procagent-check bin/sg-elevate-check bin/sg-policy-check bin/sg-greeter-check
LIBS         = lib/sg-common.sh lib/sg-run-explorer lib/sg-lock-ui lib/sg-login-ui lib/sg-consent-ui

.PHONY: all install lint test test-session test-multiuser deb clean

all:
	@echo "nothing to build; this package is scripts. try 'make test' or 'make deb'."

# Depends on d3d-probe because dpkg-buildpackage runs `dh clean` first: a
# probe built by the deb target is deleted again before install runs. The
# image has no cross-compiler, so if the .deb does not carry the probe then
# nothing in the guest can create a D3D device and the gate proves much less.
install: d3d-probe greeter token-probe procagent rdp
	install -d $(BINDIR) $(LIBDIR) $(SHAREDIR) $(UNITDIR) $(TMPFILESDIR) $(UDEVDIR)
	install -m 0755 $(BINS) $(BINDIR)
	@# The D3D probe, when a cross-compiler is available. Optional on purpose:
	@# the package must still build on a machine without mingw, and the gate
	@# reports "not built" rather than failing.
	@if [ -f build/d3d-probe64.exe ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/d3d-probe64.exe build/d3d-probe32.exe \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The greeter, its bridge, and the fixtures the gate needs in the image.
	@if [ -f build/sg-greet-bridge ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-greet-bridge build/greetd-stub \
	        greeter/test-greeter.sh $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The lock service and its helpers. sg-rdp-pamcheck is the PAM check the
	@# lock service's root monitor runs; it has no setuid bit and is only of
	@# use to root.
	@if [ -f build/sg-lockd ]; then \
	    install -m 0755 build/sg-lockd build/sg-lockctl build/sg-rdp-pamcheck \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# Remote Desktop (ADR 0010): the daemon and its certificate helper. The
	@# unit is installed disabled, as Remote Desktop is on Windows.
	@if [ -f build/sg-rdp-authd ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-rdp-authd bin/sg-rdp-cert $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# Setup (live boots only): the wizard, its bridge, and the root service
	@# that runs sg-install, behind a socket only the login screen may use.
	@if [ -f build/sg-setup-bridge ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-setup-bridge $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@if [ -f build/sg-setup64.exe ]; then \
	    install -m 0755 build/sg-setup64.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass
	install -m 0755 setup/sg-installd $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@if [ -f build/sg-polimport ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-polimport $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The per-user process agent (ADR 0014). sg-session-start launches it.
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass
	install -m 0755 build/sg-procagent build/sg-brokerd build/sg-elevate build/sg-netmountd \
	    $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@if [ -f build/sg-procmem-probe.exe ]; then \
	    install -m 0755 build/sg-procmem-probe.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The token probe, for sg-token-check (debt D17). Optional like d3d-probe.
	@if [ -f build/sg-token-probe.exe ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-token-probe.exe build/sg-token-probe-admin.exe \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@if [ -f build/sg-policy-probe.exe ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-policy-probe.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The single-sign-on probe for the domain gate (sg-image make domain-test).
	@if [ -f build/sg-sspi-probe.exe ]; then \
	    install -m 0755 build/sg-sspi-probe.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# Machine policy drop-in directory (Group Policy). Ships the README and a
	@# disabled example; an administrator adds .reg files here.
	install -d $(DESTDIR)/etc/stained-glass/policy.d
	install -m 0644 config/policy.d/README config/policy.d/10-example.reg.example \
	    $(DESTDIR)/etc/stained-glass/policy.d/
	install -d $(DESTDIR)/etc/pam.d
	install -m 0644 config/pam/stained-glass-lock config/pam/stained-glass-remote \
	    config/pam/stained-glass-elevate $(DESTDIR)/etc/pam.d/
	@# The profile service (sg-profile-create), run at login by pam_exec;
	@# the deb's postinst registers it with pam-auth-update.
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass $(DESTDIR)$(PREFIX)/share/pam-configs
	install -m 0755 bin/sg-profile-create $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	install -m 0644 config/pam-configs/stained-glass-profile $(DESTDIR)$(PREFIX)/share/pam-configs/
	@# Off until sg-domain-join turns it on: a domain user's local groups.
	install -m 0644 config/pam-configs/stained-glass-domain-groups $(DESTDIR)$(PREFIX)/share/pam-configs/
	install -m 0755 domain/sg-domain-groups domain/sg-domain-logon domain/sg-gpo-user domain/sg-gpo-machine $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@if [ -f build/sg-greeter64.exe ]; then \
	    install -m 0755 build/sg-greeter64.exe build/sg-greeter32.exe build/sg-consent64.exe \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	install -m 0755 $(LIBS) $(LIBDIR)
	install -m 0644 lib/sg-mklnk.js $(LIBDIR)
	install -m 0644 config/sg-session.env config/greetd-config.toml $(SHAREDIR)
	@# The registry.pol fixture for sg-policy-check's .pol clause.
	install -m 0644 test/fixtures/machine.pol $(SHAREDIR)/machine.pol
	install -m 0644 systemd/sg-brokerd.service \
	    systemd/sg-prefix-init.service systemd/sg-wineserver.service \
	    systemd/sg-lockd.service systemd/sg-update-prepare.service \
	    systemd/sg-update-prepare.timer systemd/sg-installd.socket \
	    systemd/sg-installd@.service systemd/sg-rdpd.service \
	    systemd/sg-netmountd.socket systemd/sg-netmountd@.service \
	    systemd/sg-gpupdate.service systemd/sg-gpupdate.timer $(UNITDIR)
	install -d $(DESTDIR)$(PREFIX)/lib/systemd/system-preset
	install -m 0644 config/preset/50-stained-glass.preset $(DESTDIR)$(PREFIX)/lib/systemd/system-preset/
	install -m 0644 tmpfiles/sg-session.conf $(TMPFILESDIR)
	install -d $(UNITDIR)/user-runtime-dir@.service.d
	install -m 0644 systemd/user-runtime-dir@.service.d/50-stained-glass-drives.conf \
	    $(UNITDIR)/user-runtime-dir@.service.d/
	install -m 0644 udev/70-stained-glass-devices.rules $(UDEVDIR)

# Every script is POSIX sh. shellcheck is advisory when absent so a bare
# checkout still lints as far as it can.
lint:
	@for f in $(BINS) $(LIBS) bin/sg-profile-create bin/sg-rdp-cert setup/sg-installd domain/sg-domain-groups domain/sg-domain-logon; do sh -n $$f || exit 1; done
	@echo "syntax OK"
	@sh test/shell-supervisor-test.sh
	@sh test/polimport-test.sh
	@sh test/detattoo-test.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh $(BINS) $(LIBS) bin/sg-profile-create bin/sg-rdp-cert setup/sg-installd domain/sg-domain-groups domain/sg-domain-logon test/setup-e2e.sh \
		    test/rdp-stream-e2e.sh || exit 1; \
		echo "shellcheck OK"; \
	else \
		echo "shellcheck not installed; skipping (advisory)"; \
	fi

test: lint test-session

# The real gate: start a headless compositor on this machine, run the session
# inside it, and let sg-session-check decide. Exits non-zero on failure.
test-session:
	@test/run-session-test.sh

# The S2 gate. Expected to fail until S2 lands -- see bin/sg-multiuser-check.
# Deliberately not part of 'make test': a known-red gate wired into CI would
# mask real regressions. Run it on purpose, as root.
test-multiuser:
	@SG_LIB=$(CURDIR)/lib sudo -E env PATH="$$PATH" $(CURDIR)/bin/sg-multiuser-check

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf debian/sg-session debian/.debhelper debian/files debian/*.substvars debian/debhelper-build-stamp
	rm -rf test/tmp
	rm -f build/d3d-probe32.exe build/d3d-probe64.exe
	rm -f build/sg-greeter32.exe build/sg-greeter64.exe build/sg-consent64.exe build/sg-greet-bridge build/greetd-stub
	rm -f build/sg-setup64.exe build/sg-setup-bridge

# --- the D3D probe ---------------------------------------------------------
#
# A real device-creation test, built as a Windows PE for both architectures.
# Checking that the DXVK and VKD3D-Proton DLLs are present proves very little:
# Wine falls back to its own builtins silently, and the installation looks
# identical either way. Creating a device says which implementation answered.
MINGW64 := x86_64-w64-mingw32-gcc
MINGW32 := i686-w64-mingw32-gcc
D3D_LIBS := -ld3d11 -ld3d12 -ldxgi -luuid

.PHONY: d3d-probe
d3d-probe:
	@# One shell for the whole recipe: each recipe line runs in its own shell,
	@# so an `exit 0` on its own line would skip nothing.
	@if ! command -v $(MINGW64) >/dev/null 2>&1; then \
	    echo "SKIP: $(MINGW64) not installed"; \
	else \
	    mkdir -p build && \
	    $(MINGW64) -O2 -o build/d3d-probe64.exe test/d3d-probe.c $(D3D_LIBS) && \
	    $(MINGW32) -O2 -o build/d3d-probe32.exe test/d3d-probe.c $(D3D_LIBS) && \
	    echo "built: build/d3d-probe64.exe build/d3d-probe32.exe"; \
	fi

# The token probe (debt D17): plain, and with a requireAdministrator manifest.
.PHONY: token-probe
token-probe:
	@if ! command -v $(MINGW64) >/dev/null 2>&1; then \
	    echo "SKIP: $(MINGW64) not installed"; \
	else \
	    mkdir -p build && \
	    $(MINGW64) -O2 -o build/sg-token-probe.exe test/sg-token-probe.c -ladvapi32 && \
	    x86_64-w64-mingw32-windres test/sg-token-probe-admin.rc -O coff -o build/sg-token-probe-admin.res && \
	    $(MINGW64) -O2 -o build/sg-token-probe-admin.exe test/sg-token-probe.c \
	        build/sg-token-probe-admin.res -ladvapi32 && \
	    $(MINGW64) -O2 -o build/sg-policy-probe.exe test/sg-policy-probe.c -lshell32 && \
	    $(MINGW64) -O2 -municode -o build/sg-sspi-probe.exe test/sg-sspi-probe.c -lsecur32 && \
	    echo "built: build/sg-token-probe.exe build/sg-token-probe-admin.exe build/sg-policy-probe.exe"; \
	fi

# --- the greeter -----------------------------------------------------------
#
# sg-greeter is a Windows program on purpose: remote-support tools can only see
# a Windows login screen (ADR 0008). It decides nothing -- sg-greet-bridge
# hands what it collects to greetd, and PAM remains the only authority.
#
# greetd-stub and test-greeter.sh are test fixtures. They speak the protocol so
# the gate can exercise the real wire format, and they are installed beside the
# bridge because the gate runs in the image, where there is no source tree.
CFLAGS_BRIDGE := -O2 -Wall -Wextra

.PHONY: greeter
greeter:
	@command -v $(MINGW64) >/dev/null 2>&1 || { echo "SKIP: $(MINGW64) not installed"; exit 0; }
	@mkdir -p build
	$(MINGW64) -O2 -mwindows -o build/sg-greeter64.exe greeter/sg-greeter.c -lgdi32 -luser32
	$(MINGW32) -O2 -mwindows -o build/sg-greeter32.exe greeter/sg-greeter.c -lgdi32 -luser32
	$(MINGW64) -O2 -mwindows -Wall -o build/sg-consent64.exe greeter/sg-consent.c -lgdi32 -luser32
	$(MINGW64) -O2 -mwindows -Wall -Wextra -o build/sg-setup64.exe setup/sg-setup.c -lgdi32 -luser32
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-setup-bridge setup/sg-setup-bridge.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-greet-bridge greeter/sg-greet-bridge.c
	$(CC) $(CFLAGS_BRIDGE) -o build/greetd-stub greeter/greetd-stub.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-lockd greeter/sg-lockd.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-polimport greeter/sg-polimport.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-lockctl greeter/sg-lockctl.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-rdp-pamcheck greeter/sg-rdp-pamcheck.c -lpam
	@# The gate looks for its fixtures beside the bridge, because in the image
	@# that is the only place they exist.
	@install -m 0755 greeter/test-greeter.sh build/
	@echo "built: the greeter, its bridge and the protocol stub"

# --- the per-user process agent (ADR 0014, debt D16/D19) -------------------
# Native: it delegates ptrace/signal/affinity for the wineserver on the user's
# own processes. Always buildable (no cross-compiler needed).
.PHONY: procagent
procagent:
	@mkdir -p build
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-procagent procagent/sg-procagent.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-brokerd broker/sg-brokerd.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-elevate broker/sg-elevate.c
	$(CC) $(CFLAGS_BRIDGE) -Wno-format-truncation -o build/sg-netmountd domain/sg-netmountd.c -lresolv
	@# The cross-process probe for sg-procagent-check (Windows PE, optional).
	@if command -v $(MINGW64) >/dev/null 2>&1; then \
	    $(MINGW64) -O2 -o build/sg-procmem-probe.exe test/sg-procmem-probe.c && \
	    echo "built: build/sg-procagent build/sg-procmem-probe.exe"; \
	else echo "built: build/sg-procagent (SKIP probe: no mingw)"; fi

.PHONY: test-greeter
test-greeter: greeter
	@# 77 is "skipped", not "failed" -- the gate says so when a cross-compiler
	@# or a fixture is missing, and that must not fail a build on a machine
	@# that simply cannot build a PE.
	@SG_LIB=$(CURDIR)/lib SG_LIBEXEC=$(CURDIR)/build $(CURDIR)/bin/sg-greeter-check; \
	    rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# --- credential-UI security gate (CI only, never installed) ----------------
#
# sg-keylog-adversary is a keylogger. It exists to be defeated by the isolation
# ADR 0009 requires, and it is a TEST FIXTURE: built under build/, run from
# there by the gate, and NEVER installed into the image. Shipping a keylogger
# in a product would be indefensible; `install` deliberately omits it.
.PHONY: security test-security
security:
	@command -v $(MINGW64) >/dev/null 2>&1 || { echo "SKIP: $(MINGW64) not installed"; exit 0; }
	@mkdir -p build
	$(MINGW64) -O2 -mwindows -o build/sg-keylog-adversary.exe greeter/sg-keylog-adversary.c -luser32 -lgdi32
	@echo "built the adversarial keylogger fixture (CI only)"

test-security: security
	@SG_LIB=$(CURDIR)/lib SG_LIBEXEC=$(CURDIR)/build \
	 SG_PREFIX=$(CURDIR)/test/tmp/state/prefix $(CURDIR)/bin/sg-lock-security-check; \
	    rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# --- remote login over RDP (ADR 0010, pattern B) ---------------------------
#
# Built when FreeRDP's server library is present. Installed with its unit
# disabled: Remote Desktop is off until an administrator turns it on.
.PHONY: rdp test-rdp test-rdp-stream
rdp:
	@pkg-config --exists freerdp-server3 winpr3 || { echo "SKIP: freerdp3-dev not installed"; exit 0; }
	@mkdir -p build
	@pkg-config --exists wayland-client xkbcommon || { echo "SKIP: wayland-client/xkbcommon dev files missing"; exit 0; }
	for p in wlr-screencopy-unstable-v1 wlr-virtual-pointer-unstable-v1; do \
	    wayland-scanner client-header rdp/protocol/$$p.xml build/$$p-client-protocol.h && \
	    wayland-scanner private-code rdp/protocol/$$p.xml build/$$p-protocol.c || exit 1; \
	done
	wayland-scanner client-header test/protocol/virtual-keyboard-unstable-v1.xml build/virtual-keyboard-unstable-v1-client-protocol.h
	wayland-scanner private-code test/protocol/virtual-keyboard-unstable-v1.xml build/virtual-keyboard-unstable-v1-protocol.c
	$(CC) $(CFLAGS_BRIDGE) -Ibuild -Irdp -o build/sg-rdp-authd greeter/sg-rdp-authd.c rdp/sg-rdp-stream.c \
	    build/wlr-screencopy-unstable-v1-protocol.c build/wlr-virtual-pointer-unstable-v1-protocol.c \
	    build/virtual-keyboard-unstable-v1-protocol.c \
	    $$(pkg-config --cflags --libs freerdp-server3 freerdp3 winpr3 wayland-client xkbcommon)
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-rdp-pamcheck greeter/sg-rdp-pamcheck.c -lpam
	@echo "built the RDP login daemon and its PAM helper"

test-rdp: rdp
	@SG_LIBEXEC=$(CURDIR)/build $(CURDIR)/bin/sg-rdp-check; \
	    rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# Streaming: a real FreeRDP client into a headless sg-compositor session (the
# compositor checkout beside this repo), lossless, typed into and clicked.
test-rdp-stream: rdp
	@sh test/rdp-stream-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The lock screen end to end: sg-compositor (beside this repo) + sg-lockd + the
# Wine greeter in lock mode. Needs the session prefix from `make test`.
.PHONY: test-lock
test-lock: greeter rdp vkbd
	@sh test/lock-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# sg-vkbd: a virtual-keyboard test fixture with a stable keymap (see its
# header for why wtype is not enough to drive a Wine prompt). Never installed.
.PHONY: vkbd
vkbd:
	@pkg-config --exists wayland-client xkbcommon || { echo "SKIP: wayland-client/xkbcommon dev files missing"; exit 0; }
	@mkdir -p build
	wayland-scanner client-header test/protocol/virtual-keyboard-unstable-v1.xml build/virtual-keyboard-unstable-v1-client-protocol.h
	wayland-scanner private-code test/protocol/virtual-keyboard-unstable-v1.xml build/virtual-keyboard-unstable-v1-protocol.c
	$(CC) $(CFLAGS_BRIDGE) -Ibuild -o build/sg-vkbd test/sg-vkbd.c build/virtual-keyboard-unstable-v1-protocol.c \
	    $$(pkg-config --cflags --libs wayland-client xkbcommon)

# Elevation consent end to end (ADR 0012): sg-compositor's SECURE mode +
# sg-brokerd + sg-consent.exe, driven over the privileged virtual keyboard.
.PHONY: test-consent
test-consent: greeter rdp procagent vkbd
	@sh test/consent-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# Setup end to end: the real wizard, bridge and sg-installd, with a stand-in
# for sg-install (sg-image's install-test erases a real disk).
.PHONY: test-setup
test-setup: greeter
	@sh test/setup-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The login screen end to end, with the real Wine greeter against a greetd stub.
.PHONY: test-login
test-login: greeter
	@sh test/login-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc
