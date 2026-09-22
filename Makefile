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

BINS         = bin/sg-prefix-init bin/sg-session-start bin/sg-session-check \
               bin/sg-multiuser-check
LIBS         = lib/sg-common.sh lib/sg-run-explorer

.PHONY: all install lint test test-session test-multiuser deb clean

all:
	@echo "nothing to build; this package is scripts. try 'make test' or 'make deb'."

install:
	install -d $(BINDIR) $(LIBDIR) $(SHAREDIR) $(UNITDIR) $(TMPFILESDIR)
	install -m 0755 $(BINS) $(BINDIR)
	install -m 0755 $(LIBS) $(LIBDIR)
	install -m 0644 config/sg-session.env config/greetd-config.toml $(SHAREDIR)
	install -m 0644 systemd/sg-prefix-init.service $(UNITDIR)
	install -m 0644 tmpfiles/sg-session.conf $(TMPFILESDIR)

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
