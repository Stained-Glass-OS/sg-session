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

BINS         = bin/sg-install bin/sg-print-check bin/sg-drivers domain/sg-dc-provision domain/sg-domain-join domain/sg-gpupdate bin/sg-prefix-init bin/sg-session-start bin/sg-session-check \
               bin/sg-multiuser-check bin/sg-wineserver bin/sg-services-start \
               bin/sg-install-d3d bin/sg-d3d-check bin/sg-firmware-retry bin/sg-open-windows-file \
               bin/sg-install-apps bin/sg-apps-check \
               bin/sg-update-prepare bin/sg-boot-splash bin/sg-kernel-entries bin/sg-boot-layout bin/sg-file-access-check \
               bin/sg-token-check bin/sg-procagent-check bin/sg-elevate-check bin/sg-policy-check bin/sg-greeter-check
LIBS         = lib/sg-common.sh lib/sg-wine-reload lib/sg-defender-notify lib/sg-restart-notify lib/sg-run-explorer lib/sg-sas-action lib/sg-lock-ui lib/sg-login-ui lib/sg-consent-ui \
               lib/sg-oobe-user lib/sg-oobe-browser lib/sg-ui-scale

.PHONY: all install lint test test-session test-firmware-retry test-multiuser deb clean

all:
	@echo "nothing to build; this package is scripts. try 'make test' or 'make deb'."

# Depends on d3d-probe because dpkg-buildpackage runs `dh clean` first: a
# probe built by the deb target is deleted again before install runs. The
# image has no cross-compiler, so if the .deb does not carry the probe then
# nothing in the guest can create a D3D device and the gate proves much less.
install: d3d-probe greeter token-probe procagent polkitagent rdp
	install -d $(BINDIR) $(LIBDIR) $(SHAREDIR) $(UNITDIR) $(TMPFILESDIR) $(UDEVDIR)
	install -m 0755 $(BINS) $(BINDIR)
	@# Python, so not in BINS (which lint checks as sh).
	install -m 0755 bin/sg-netctl bin/sg-sysinfo bin/sg-firmware-initrd $(BINDIR)
	@# SG PDF's Linux half: MuPDF (python3-pymupdf) and its engine.
	install -m 0755 bin/sg-pdf $(BINDIR)
	install -m 0755 bin/powershell $(BINDIR)
	install -m 0755 bin/sg-defender $(BINDIR)
	install -d $(LIBDIR)/pdf
	install -m 0644 pdf/sgpdf.py pdf/sgpdf_content.py pdf/sgpdf_docx.py $(LIBDIR)/pdf/
	@# Settings' native half: sound, Bluetooth, display, night light, idle, updates.
	install -m 0755 bin/sg-settingsctl $(BINDIR)
	@# the volume chime, made here (sounds/make-chime.py: our own, no recording)
	install -d $(DESTDIR)$(PREFIX)/share/sounds/stained-glass
	python3 sounds/make-chime.py $(DESTDIR)$(PREFIX)/share/sounds/stained-glass/volume-change.wav
	@# Voice typing: the engine (sgspeech.py) and its command. The model is
	@# downloaded per machine by sg-speechd, never packaged.
	install -m 0755 speech/sg-dictate $(BINDIR)
	install -d $(LIBDIR)/speech
	install -m 0644 speech/sgspeech.py $(LIBDIR)/speech/
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
	@# that runs sg-install, behind a socket only the login screen and the
	@# live session may use; and the live session's setup.
	@if [ -f build/sg-setup-bridge ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-setup-bridge $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@if [ -f build/sg-setup64.exe ]; then \
	    install -m 0755 build/sg-setup64.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The first-run setup (OOBE): the wizard, and the root service behind the
	@# bridge's --oobe mode, which applies what it asks for.
	@if [ -f build/sg-oobe64.exe ]; then \
	    install -m 0755 build/sg-oobe64.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass
	install -m 0755 setup/sg-oobed $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass
	install -m 0755 setup/sg-installd setup/sg-live-setup $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	install -m 0755 bin/sg-eject bin/sg-netbrowse $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@if [ -f build/sg-polimport ]; then \
	    install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass; \
	    install -m 0755 build/sg-polimport $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	@# The per-user process agent (ADR 0014). sg-session-start launches it.
	install -d $(DESTDIR)$(PREFIX)/libexec/stained-glass
	install -m 0755 build/sg-procagent build/sg-brokerd build/sg-elevate build/sg-elevated-run build/sg-netmountd \
	    $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@# The session's polkit agent and the broker monitor's answer to polkitd.
	install -m 0755 build/sg-polkit-agent build/sg-polkit-respond $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@# What sg-elevate can do, for Wine's ShellExecuteEx (wine-sg 0625: --ready).
	install -d $(DESTDIR)$(PREFIX)/share/stained-glass
	install -m 0644 config/sg-elevate.features $(DESTDIR)$(PREFIX)/share/stained-glass/sg-elevate.features
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
	@# The Windows identity probe for the domain gate (a domain account's SID).
	@if [ -f build/sg-sid-probe.exe ]; then \
	    install -m 0755 build/sg-sid-probe.exe $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
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
	@# One home: /home/<user> is a link to the Windows profile (sg-shared-home.service, and at sign-in).
	install -m 0755 bin/sg-shared-home $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	install -m 0644 config/pam-configs/stained-glass-profile $(DESTDIR)$(PREFIX)/share/pam-configs/
	@# The Security log's sign-in/sign-out events (sg-audit, pam_exec at session open and close).
	install -m 0755 bin/sg-audit $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@# The Print to PDF printer (sg-print-setup.service).
	install -m 0755 bin/sg-print-setup $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@# A DYMO LabelWriter 5xx's queue when it is plugged in (sg-dymo-queue.service, udev).
	install -m 0755 bin/sg-dymo-queue $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@# Windows' printers follow CUPS's (sg-printers-refresh.path).
	install -m 0755 bin/sg-printers-refresh $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	install -m 0644 config/pam-configs/stained-glass-audit $(DESTDIR)$(PREFIX)/share/pam-configs/
	@# Off until sg-domain-join turns it on: a domain user's local groups.
	install -m 0644 config/pam-configs/stained-glass-domain-groups $(DESTDIR)$(PREFIX)/share/pam-configs/
	install -m 0755 domain/sg-domain-groups domain/sg-domain-logon domain/sg-gpo-user domain/sg-gpo-machine $(DESTDIR)$(PREFIX)/libexec/stained-glass/
	@if [ -f build/sg-greeter64.exe ]; then \
	    install -m 0755 build/sg-greeter64.exe build/sg-greeter32.exe build/sg-consent64.exe \
	        $(DESTDIR)$(PREFIX)/libexec/stained-glass/; \
	fi
	install -m 0755 $(LIBS) $(LIBDIR)
	install -m 0755 lib/sg-fetch $(LIBDIR)
	install -m 0644 lib/sg-mklnk.js $(LIBDIR)
	install -m 0644 config/sg-session.env config/greetd-config.toml $(SHAREDIR)
	@# Windows programs opened from Linux programs (Firefox's downloads): sg-open-windows-file
	install -D -m 0644 config/applications/sg-windows-file.desktop $(DESTDIR)$(PREFIX)/share/applications/sg-windows-file.desktop
	install -D -m 0644 config/applications/sg-mimeapps.list $(DESTDIR)$(PREFIX)/share/applications/mimeapps.list
	@# The registry.pol fixture for sg-policy-check's .pol clause.
	install -m 0644 test/fixtures/machine.pol $(SHAREDIR)/machine.pol
	install -m 0644 systemd/sg-shared-home.service $(DESTDIR)$(PREFIX)/lib/systemd/system/
	@# The boot splash (splash/): our Plymouth theme, its pictures drawn here;
	@# when Plymouth quits and starts at shutdown; the recovery entries of new
	@# kernels. sg-boot-splash (postinst) makes it the machine's.
	install -d $(DESTDIR)$(PREFIX)/share/plymouth/themes/stained-glass
	install -m 0644 splash/stained-glass.plymouth splash/stained-glass.script $(DESTDIR)$(PREFIX)/share/plymouth/themes/stained-glass/
	python3 splash/make-splash.py $(DESTDIR)$(PREFIX)/share/plymouth/themes/stained-glass/diamond.png 192
	python3 splash/make-splash.py --bar $(DESTDIR)$(PREFIX)/share/plymouth/themes/stained-glass/bar-fill.png 8a2be2
	python3 splash/make-splash.py --bar $(DESTDIR)$(PREFIX)/share/plymouth/themes/stained-glass/bar-track.png 3a3a44
	for d in systemd/plymouth/*.service.d; do \
	    install -d $(DESTDIR)$(PREFIX)/lib/systemd/system/$${d#systemd/plymouth/}; \
	    install -m 0644 $$d/*.conf $(DESTDIR)$(PREFIX)/lib/systemd/system/$${d#systemd/plymouth/}/; \
	done
	install -D -m 0644 systemd/system.conf.d/60-sg-quiet-reboot.conf $(DESTDIR)$(PREFIX)/lib/systemd/system.conf.d/60-sg-quiet-reboot.conf
	install -D -m 0644 config/portal/stainedglass-portals.conf $(DESTDIR)$(PREFIX)/share/xdg-desktop-portal/stainedglass-portals.conf
	install -D -m 0644 config/portal/wlr/config $(DESTDIR)/etc/xdg/xdg-desktop-portal-wlr/config
	@# A Surface kernel's boot entry counts its tries (sg-drivers --install-platform).
	install -D -m 0644 systemd/systemd-bless-boot.service.d/50-sg-recovery.conf $(UNITDIR)/systemd-bless-boot.service.d/50-sg-recovery.conf
	install -D -m 0755 kernel/90-sg-boot-tries.install $(DESTDIR)$(PREFIX)/lib/kernel/install.d/90-sg-boot-tries.install
	@# The linux-surface archive's key: used (Signed-By) on Surface PCs only.
	install -D -m 0644 config/keyrings/linux-surface.gpg $(DESTDIR)$(PREFIX)/share/stained-glass/keyrings/linux-surface.gpg
	install -D -m 0755 kernel/91-sg-recovery.install $(DESTDIR)$(PREFIX)/lib/kernel/install.d/91-sg-recovery.install
	install -D -m 0755 kernel/92-sg-firmware.install $(DESTDIR)$(PREFIX)/lib/kernel/install.d/92-sg-firmware.install
	install -D -m 0755 kernel/93-sg-reboot-required.install $(DESTDIR)$(PREFIX)/lib/kernel/install.d/93-sg-reboot-required.install
	install -m 0644 systemd/sg-brokerd.service \
	    systemd/sg-prefix-init.service systemd/sg-wineserver.service \
	    systemd/sg-lockd.service systemd/sg-update-prepare.service systemd/sg-defender.service \
	    systemd/sg-update-prepare.timer systemd/sg-installd.socket \
	    systemd/sg-installd@.service systemd/sg-rdpd.service \
	    systemd/sg-netmountd.socket systemd/sg-netmountd@.service \
	    systemd/sg-netd.socket systemd/sg-netd@.service \
	    systemd/sg-sysinfod.socket systemd/sg-sysinfod@.service systemd/sg-devices-apply.service \
    systemd/sg-speechd.socket systemd/sg-speechd@.service \
	    systemd/sg-gpupdate.service systemd/sg-gpupdate.timer systemd/sg-live.service systemd/sg-drivers.service systemd/sg-hwsupport.service systemd/sg-boot-layout.service \
	    systemd/sg-oobed.socket systemd/sg-oobed@.service systemd/sg-oobe-browser.service \
	    systemd/sg-automount@.service \
	    systemd/sg-print-setup.service systemd/sg-dymo-queue.service systemd/sg-printers-refresh.path systemd/sg-printers-refresh.service systemd/sg-firmware-retry.service systemd/sg-firmware-initrd.service $(UNITDIR)
	install -D -m 0644 systemd/systemd-timesyncd.service.d/50-sg-initrd-network.conf \
	    $(UNITDIR)/systemd-timesyncd.service.d/50-sg-initrd-network.conf
	install -D -m 0644 systemd/clamav-daemon.service.d/50-sg-background.conf $(UNITDIR)/clamav-daemon.service.d/50-sg-background.conf
	install -D -m 0644 systemd/clamav-freshclam.service.d/50-sg-background.conf $(UNITDIR)/clamav-freshclam.service.d/50-sg-background.conf
	install -d $(DESTDIR)$(PREFIX)/lib/systemd/system-preset
	install -m 0644 config/preset/50-stained-glass.preset $(DESTDIR)$(PREFIX)/lib/systemd/system-preset/
	install -m 0644 tmpfiles/sg-session.conf tmpfiles/sg-audit.conf $(TMPFILESDIR)
	install -d $(UNITDIR)/user-runtime-dir@.service.d
	install -m 0644 systemd/user-runtime-dir@.service.d/50-stained-glass-drives.conf \
	    $(UNITDIR)/user-runtime-dir@.service.d/
	install -m 0644 udev/70-stained-glass-devices.rules $(UDEVDIR)
	install -m 0644 udev/71-stained-glass-media.rules $(UDEVDIR)
	install -m 0644 udev/72-stained-glass-usb-writes.rules $(UDEVDIR)
	install -m 0644 udev/73-stained-glass-dymo.rules $(UDEVDIR)
	install -d $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d
	install -m 0644 config/polkit/50-stained-glass-network.rules $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d/
	install -m 0644 config/polkit/50-stained-glass-power.rules $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d/
	install -m 0644 config/polkit/50-stained-glass-updates.rules $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d/
	install -m 0644 config/polkit/50-stained-glass-media.rules $(DESTDIR)$(PREFIX)/share/polkit-1/rules.d/
	install -D -m 0644 config/sysctl/60-stained-glass-ping.conf $(DESTDIR)$(PREFIX)/lib/sysctl.d/60-stained-glass-ping.conf
	install -D -m 0644 logind/60-stained-glass-vts.conf $(DESTDIR)$(PREFIX)/lib/systemd/logind.conf.d/60-stained-glass-vts.conf
	install -D -m 0644 config/ssh/05-stained-glass.conf $(DESTDIR)/etc/ssh/sshd_config.d/05-stained-glass.conf
	install -d $(DESTDIR)/etc/udisks2
	install -m 0644 config/udisks2/mount_options.conf $(DESTDIR)/etc/udisks2/mount_options.conf

# Every script is POSIX sh. shellcheck is advisory when absent so a bare
# checkout still lints as far as it can.
# Every test that runs Wine sources test/scratch-home.sh first (a HOME of its
# own: a prefix links its Desktop, Documents... into HOME).
lint:
	@for f in $$(grep -l WINEPREFIX test/*.sh); do \
	    sed -n 2p "$$f" | grep -q '^\. "$$(dirname "$$0")/scratch-home.sh"$$' || \
	    { echo "$$f: line 2 must be: . \"\$$(dirname \"\$$0\")/scratch-home.sh\""; exit 1; }; done
	@for f in $(BINS) $(LIBS) bin/sg-profile-create bin/sg-shared-home bin/sg-rdp-cert setup/sg-installd setup/sg-live-setup setup/sg-oobed domain/sg-domain-groups domain/sg-domain-logon; do sh -n $$f || exit 1; done
	@echo "syntax OK"
	@sh test/shell-supervisor-test.sh
	@sh test/desktop-follow-test.sh
	@sh test/update-prepare-test.sh
	@sh test/prefix-current-test.sh
	@# 77: skipped (it must run as an ordinary user; CI builds as root)
	@sh test/shared-home-test.sh || [ $$? -eq 77 ]
	@sh test/cursor-env-test.sh
	@sh test/display-scale-test.sh
	@sh test/systemroot-temp-test.sh
	@sh test/ssh-migrate-test.sh
	@sh test/oobe-browser-linux-test.sh
	@sh test/workarea-test.sh || [ $$? -eq 77 ]
	@sh test/programdata-test.sh || [ $$? -eq 77 ]
	@sh test/device-rules-test.sh || [ $$? -eq 77 ]
	@sh test/dotnet-support-test.sh || [ $$? -eq 77 ]
	@sh test/mono-support-refresh-test.sh
	@sh test/backdrop-first-test.sh
	@sh test/keep-running-test.sh
	@sh test/wineserver-wait-test.sh
	@sh test/powershell-cmd-test.sh
	@sh test/wine-reload-test.sh
	@sh test/defender-test.sh
	@sh test/defender-notify-test.sh
	@sh test/restart-notify-test.sh
	@sh test/polimport-test.sh
	@sh test/detattoo-test.sh
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-netctl
	@python3 test/netctl-test.py
	@sh test/print-setup-test.sh
	@sh test/dymo-queue-test.sh
	@! sh test/dymo-queue-test.sh --mutant >/dev/null
	@sh test/printers-refresh-test.sh
	@! sh test/printers-refresh-test.sh --mutant >/dev/null
	@! sh test/printers-refresh-test.sh --mutant-session >/dev/null
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-sysinfo
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-defender
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-firmware-initrd
	@python3 test/sysinfo-test.py
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-audit
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' speech/sg-dictate
	@python3 test/dictate-test.py
	@python3 test/settingsctl-test.py
	@sh test/vdagent-test.sh
	@sh test/windows-file-test.sh
	@sh test/greeter-selectall-test.sh || [ $$? -eq 77 ]   # 77: skipped (no X, Wine or the PE build)
	@sh test/greeter-lastuser-test.sh || [ $$? -eq 77 ]
	@sh test/greeter-lastuser-ui-test.sh || [ $$? -eq 77 ]
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' bin/sg-pdf
	@for f in pdf/sgpdf.py pdf/sgpdf_content.py pdf/sgpdf_docx.py; do python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' $$f || exit 1; done
	@/usr/bin/python3 test/pdf-test.py; rc=$$?; [ $$rc = 0 ] || [ $$rc = 77 ]
	@/usr/bin/python3 test/pdf-edit-test.py; rc=$$?; [ $$rc = 0 ] || [ $$rc = 77 ]
	@python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' lib/sg-fetch
	@python3 test/fetch-test.py; rc=$$?; [ $$rc = 0 ] || [ $$rc = 77 ]
	@sh test/drivers-test.sh
	@! sh test/drivers-test.sh --mutant >/dev/null 2>&1
	@sh test/kernel-entries-test.sh
	@sh test/boot-layout-test.sh
	@for m in verify live bootroot marker; do ! sh test/boot-layout-test.sh --mutant $$m >/dev/null 2>&1 || { echo "boot-layout-test: mutant $$m passed"; exit 1; }; done
	@for m in layout tries configured newer platformoff; do ! sh test/kernel-entries-test.sh --mutant $$m >/dev/null 2>&1 || { echo "kernel-entries-test: mutant $$m passed"; exit 1; }; done
	@sh test/surface-test.sh
	@for m in dmi pin key tries twin; do ! sh test/surface-test.sh --mutant $$m >/dev/null 2>&1 || { echo "surface-test: mutant $$m passed"; exit 1; }; done
	@sh test/oobe-fallback-test.sh; rc=$$?; [ $$rc = 0 ] || [ $$rc = 77 ]
	@sh test/oobe-user-test.sh
	@sh test/media-test.sh
	@# no user-visible "Windows" as our name (Microsoft's trademark); tools/trademark-allow.txt for exceptions
	@python3 tools/trademark-check.py --allow tools/trademark-allow.txt greeter setup bin lib pdf speech domain rdp broker admin procagent config systemd
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh -e SC1091 $(BINS) $(LIBS) bin/sg-profile-create bin/sg-shared-home bin/sg-eject bin/sg-netbrowse bin/sg-rdp-cert setup/sg-installd setup/sg-live-setup setup/sg-oobed domain/sg-domain-groups domain/sg-domain-logon test/setup-e2e.sh test/oobe-e2e.sh test/oobe-fallback-test.sh test/oobe-user-test.sh test/media-test.sh test/netmount-guest-test.sh test/netmount-logon-test.sh test/netmount-listing-test.sh test/netmount-signout-test.sh \
		    test/rdp-stream-e2e.sh test/scratch-home.sh || exit 1; \
		echo "shellcheck OK"; \
	else \
		echo "shellcheck not installed; skipping (advisory)"; \
	fi

test: lint test-linuxappenv test-deskcomp-start test-firmware-retry test-session test-notify-helper

# The session's polkit agent and the broker's polkit path, on a private bus
# with a stand-in polkitd: pkexec's request through the consent (mutants: the
# broker or the monitor checks skipped).
.PHONY: test-polkit
test-polkit: procagent polkitagent
	@sh test/polkit-test.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The session starts the desktop's compositor (sg_start_deskcomp), and the
# test fails without the launch (its --mutant).
test-deskcomp-start:
	@sh test/deskcomp-start-test.sh
	@! sh test/deskcomp-start-test.sh --mutant >/dev/null

# The sound firmware the initrd could not load, and the clock timesyncd could
# not set (fake sysfs; the test fails without the rebind, its --mutant).
test-firmware-retry:
	@sh test/firmware-retry-test.sh
	@! sh test/firmware-retry-test.sh --mutant >/dev/null
	@sh test/firmware-initrd-test.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc
	@! sh test/firmware-initrd-test.sh --mutant >/dev/null

# Linux programs go through Xwayland (sg_linux_app_env): native Wayland ones
# were shown full screen over the taskbar. Stand-in systemctl/D-Bus.
test-linuxappenv:
	@sh test/linux-app-env-test.sh

# Voice typing with the real model: espeak-ng speech through --transcribe-file
# and the microphone path. Skips (77) without the model or espeak-ng; set
# SG_SPEECH_MODEL to a downloaded model directory.
test-dictate:
	@sh test/dictate-e2e.sh

# The real gate: start a headless compositor on this machine, run the session
# inside it, and let sg-session-check decide. Exits non-zero on failure.
test-session:
	@test/run-session-test.sh

# the notification centre's icon among the shell's helpers
test-notify-helper:
	@sh test/notify-helper-test.sh

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
	rm -f build/sg-setup64.exe build/sg-setup-bridge build/sg-setup.ico build/sg-setup-res.o build/sg-oobe64.exe

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
	    $(MINGW64) -O2 -o build/sg-sid-probe.exe test/sg-sid-probe.c -ladvapi32 -lsecur32 && \
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
	$(MINGW64) -O2 -mwindows -o build/sg-greeter64.exe greeter/sg-greeter.c -lole32 -luuid -lgdi32 -luser32
	$(MINGW32) -O2 -mwindows -o build/sg-greeter32.exe greeter/sg-greeter.c -lole32 -luuid -lgdi32 -luser32
	$(MINGW64) -O2 -mwindows -Wall -o build/sg-consent64.exe greeter/sg-consent.c -lgdi32 -luser32
	python3 setup/make-icon.py build/sg-setup.ico
	$(MINGW64:gcc=windres) -o build/sg-setup-res.o setup/sg-setup.rc
	$(MINGW64) -O2 -mwindows -Wall -Wextra -o build/sg-setup64.exe setup/sg-setup.c build/sg-setup-res.o -lcomctl32 -lgdi32 -luser32
	$(MINGW64) -O2 -mwindows -Wall -Wextra -o build/sg-oobe64.exe setup/sg-oobe.c -lgdi32 -luser32
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

# --- the session's polkit agent: pkexec and the rest through the broker's ---
# consent (sg-polkit-agent as the user; sg-polkit-respond for the broker's
# root monitor). GIO only.
.PHONY: polkitagent
polkitagent:
	@mkdir -p build
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-polkit-agent broker/sg-polkit-agent.c $$(pkg-config --cflags --libs gio-2.0)
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-polkit-respond broker/sg-polkit-respond.c $$(pkg-config --cflags --libs gio-2.0)

# --- the per-user process agent (ADR 0014, debt D16/D19) -------------------
# Native: it delegates ptrace/signal/affinity for the wineserver on the user's
# own processes. Always buildable (no cross-compiler needed).
.PHONY: procagent
procagent:
	@mkdir -p build
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-procagent procagent/sg-procagent.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-brokerd broker/sg-brokerd.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-elevate broker/sg-elevate.c
	$(CC) $(CFLAGS_BRIDGE) -o build/sg-elevated-run broker/sg-elevated-run.c
	$(CC) $(CFLAGS_BRIDGE) -Wno-format-truncation -o build/sg-netmountd domain/sg-netmountd.c -lresolv
	@# The cross-process probe for sg-procagent-check (Windows PE, optional).
	@if command -v $(MINGW64) >/dev/null 2>&1; then \
	    $(MINGW64) -O2 -o build/sg-procmem-probe.exe test/sg-procmem-probe.c && \
	    echo "built: build/sg-procagent build/sg-procmem-probe.exe"; \
	else echo "built: build/sg-procagent (SKIP probe: no mingw)"; fi

# High-resolution screens: Setup, the first-run setup and GTK programs at
# 2736x1824 (Xvfb, a real Wine; SG_WINE_DIR for another one).
.PHONY: test-hidpi
test-hidpi: greeter
	@sh test/hidpi-ui-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

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
# Blank passwords: refused remotely, allowed at the lock screen (the console).
# The Ctrl+Alt+Del screen's choices run in the session (sg-sas-action).
# An elevated program looks like the user's others (sg-elevated-run).
.PHONY: test-elevate-look
test-elevate-look:
	@sh test/elevate-look-test.sh

# Elevated console programs (PowerShell, cmd) get a console window.
.PHONY: test-elevate-console
test-elevate-console:
	@sh test/elevate-console-test.sh

# "Run with debugging" keeps logging when the program elevates.
# The quiet boot on installed machines, and its recovery-mode entries.
.PHONY: test-boot-splash
test-boot-splash:
	@sh test/boot-splash-test.sh

.PHONY: test-elevate-debug
test-elevate-debug: procagent
	@sh test/elevate-debug-test.sh

.PHONY: test-sas-action
test-sas-action:
	@sh test/sas-action-test.sh

.PHONY: test-pamcheck
test-pamcheck: rdp
	@sh test/pamcheck-test.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

test-lock: greeter rdp vkbd
	@sh test/lock-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The lock screen's picture and clock: Settings' published choice, sg-lockd's
# checks, and the greeter's curtain and sign-in pane, by pixels under Xvfb.
.PHONY: test-lockpic
test-lockpic: greeter
	@sh test/lockpic-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

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

# The first-run setup (OOBE) end to end: the real wizard, bridge and sg-oobed,
# with stand-ins for the network, the account tools and HKLM.
.PHONY: test-oobe
test-oobe: greeter
	@sh test/oobe-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The login screen end to end, with the real Wine greeter against a greetd stub.
.PHONY: test-login
test-login: greeter
	@sh test/login-e2e.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The profile service plants Windows' Send to items once per profile (needs root).
.PHONY: test-profile
test-profile:
	sudo sh test/profile-sendto-test.sh

# Disk Management's partition changes for real, on a loop device only (needs sudo).
.PHONY: test-diskops
test-diskops:
	@sh test/diskops-test.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc

# The Security log's Linux side: sg-audit, the broker's events, the log files'
# modes; SG_WINE=<a wine-sg with 0187> adds the end to end (needs sudo, sgconf).
.PHONY: test-audit
test-audit:
	@sh test/audit-test.sh; rc=$$?; [ $$rc -eq 77 ] && exit 0 || exit $$rc
