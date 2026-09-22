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

BINS         = bin/sg-prefix-init bin/sg-session-start bin/sg-session-check \
               bin/sg-multiuser-check bin/sg-wineserver bin/sg-services-start \
               bin/sg-install-d3d bin/sg-d3d-check \
               bin/sg-greeter-check
LIBS         = lib/sg-common.sh lib/sg-run-explorer lib/sg-lock-ui

.PHONY: all install lint test test-session test-multiuser deb clean

all:
	@echo "nothing to build; this package is scripts. try 'make test' or 'make deb'."

# Depends on d3d-probe because dpkg-buildpackage runs `dh clean` first: a
# probe built by the deb target is deleted again before install runs. The
# image has no cross-compiler, so if the .deb does not carry the probe then
# nothing in the guest can create a D3D device and the gate proves much less.
install: d3d-probe greeter
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
	@if [ -f build/sg-greeter64.exe ]; then \
	    install -m 0755 build/sg-greeter64.exe build/sg-greeter32.exe \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	install -m 0755 $(LIBS) $(LIBDIR)
	install -m 0644 config/sg-session.env config/greetd-config.toml $(SHAREDIR)
	install -m 0644 systemd/sg-prefix-init.service systemd/sg-wineserver.service $(UNITDIR)
	install -m 0644 tmpfiles/sg-session.conf $(TMPFILESDIR)
	install -m 0644 udev/70-stained-glass-devices.rules $(UDEVDIR)

# Every script is POSIX sh. shellcheck is advisory when absent so a bare
# checkout still lints as far as it can.
lint:
	@for f in $(BINS) $(LIBS); do sh -n $$f || exit 1; done
	@echo "syntax OK"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh $(BINS) $(LIBS) || exit 1; \
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
	rm -f build/sg-greeter32.exe build/sg-greeter64.exe build/sg-greet-bridge build/greetd-stub

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
	@command -v $(MINGW64) >/dev/null 2>&1 || { echo "SKIP: $(MINGW64) not installed"; exit 0; }
	@mkdir -p build
	$(MINGW64) -O2 -o build/d3d-probe64.exe test/d3d-probe.c $(D3D_LIBS)
	$(MINGW32) -O2 -o build/d3d-probe32.exe test/d3d-probe.c $(D3D_LIBS)
	@echo "built: build/d3d-probe64.exe build/d3d-probe32.exe"

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
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-greet-bridge greeter/sg-greet-bridge.c
	$(CC) $(CFLAGS_BRIDGE) -o build/greetd-stub greeter/greetd-stub.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-lockd greeter/sg-lockd.c
	@# The gate looks for its fixtures beside the bridge, because in the image
	@# that is the only place they exist.
	@install -m 0755 greeter/test-greeter.sh build/
	@echo "built: the greeter, its bridge and the protocol stub"

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
# Built when FreeRDP's server library is present, and not installed yet: the
# daemon authenticates but cannot stream a session until sg-compositor exists,
# and a login service that leads nowhere should not be running on machines.
.PHONY: rdp test-rdp
rdp:
	@pkg-config --exists freerdp-server3 winpr3 || { echo "SKIP: freerdp3-dev not installed"; exit 0; }
	@mkdir -p build
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-rdp-authd greeter/sg-rdp-authd.c \
	    $$(pkg-config --cflags --libs freerdp-server3 freerdp3 winpr3)
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-rdp-pamcheck greeter/sg-rdp-pamcheck.c -lpam
	@echo "built the RDP login daemon and its PAM helper"

test-rdp: rdp
	@SG_LIBEXEC=$(CURDIR)/build $(CURDIR)/bin/sg-rdp-check; \
	    rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The lock screen end to end: sg-compositor (beside this repo) + sg-lockd + the
# Wine greeter in lock mode. Needs the session prefix from `make test`.
.PHONY: test-lock
test-lock: greeter rdp
	@sh test/lock-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The login screen end to end, with the real Wine greeter against a greetd stub.
.PHONY: test-login
test-login: greeter
	@sh test/login-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc
