#!/bin/sh
. "$(dirname "$0")/scratch-home.sh"
# What the permission prompt says about the program (greeter/sg-consent.c), as Windows' does:
#  1. a program signed by a publisher whose chain ends in a root trusted for code signing:
#     its own description in bold, "Verified publisher: <the signer>"
#  2. an unsigned program: its file name -- not the description it gives itself -- and
#     "Publisher: Unknown"
#  3. signed, but by a CA no root vouches for: as unsigned
#  4. an unquoted path with spaces and arguments is read as CreateProcess reads it
#  5. one of the system's own programs: "Publisher: Stained Glass (part of the system)"
#  6. msiexec /i <package>: the package is what is checked
#  7. a Linux program (pkexec): no publisher line
# Mutant SG_MUTANT_CONSENT_TRUSTS_UNSIGNED (an unsigned program shown as verified) must fail 2.
#   SG_WINE_DIR=/opt/wine-sg sh test/consent-describe-test.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WD="${SG_WINE_DIR:-/opt/wine-sg}"
WINE="$WD/bin/wine"; WINESERVER="$WD/bin/wineserver"
MINGW="${MINGW64:-x86_64-w64-mingw32-gcc}"
command -v "$MINGW" >/dev/null && command -v x86_64-w64-mingw32-windres >/dev/null || { echo "SKIP: no mingw"; exit 77; }
command -v openssl >/dev/null && command -v osslsigncode >/dev/null || { echo "SKIP: no openssl/osslsigncode"; exit 77; }
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
T=$(mktemp -d /var/tmp/sg-consent-describe.XXXXXX)
unset DISPLAY WAYLAND_DISPLAY
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" WINESERVER
mkdir -p "$HOME"
cleanup() { "$WINESERVER" -k 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
cd "$T" || exit 1
L="-lgdi32 -luser32 -lwintrust -lcrypt32 -lversion -lshlwapi"
"$MINGW" -O2 -mwindows -Wall -o consent.exe "$HERE/greeter/sg-consent.c" $L || { echo "FAIL  build"; exit 1; }
"$MINGW" -O2 -mwindows -Wall -DSG_MUTANT_CONSENT_TRUSTS_UNSIGNED -o mutant.exe "$HERE/greeter/sg-consent.c" $L || exit 1

# a small program that says it is "SG Gate Tool"
printf 'int main(void){return 0;}\n' > tool.c
cat > tool.rc <<'EOR'
1 VERSIONINFO
FILEVERSION 1,0,0,0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "FileDescription", "SG Gate Tool"
      VALUE "ProductName", "SG Gate Tool"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
EOR
x86_64-w64-mingw32-windres tool.rc -O coff -o tool.res && "$MINGW" -O2 -o tool.exe tool.c tool.res || { echo "FAIL  tool"; exit 1; }
# a root for code signing, a publisher it vouches for, and a stranger no root vouches for
mk_ca() { openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.pem" -days 3650 -subj "/CN=$2" \
          -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1; }
mk_leaf() { openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$3" >/dev/null 2>&1 &&
            printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' > "$1.ext" &&
            openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial -days 3650 -extfile "$1.ext" -out "$1.pem" >/dev/null 2>&1; }
sign() { osslsigncode sign -certs "$1.pem" -key "$1.key" -n "SG Gate Tool" -in tool.exe -out "$2" >/dev/null 2>&1; }
mk_ca root "SG Gate Code Root" && mk_leaf pub root "SG Gate Publisher" && mk_ca other "SG Gate Other Root" && mk_leaf stranger other "SG Gate Stranger" \
    || { echo "FAIL  certificates"; exit 1; }
sign pub signed.exe && sign stranger stranger.exe || { echo "FAIL  signing"; exit 1; }
cp tool.exe unsigned.exe
openssl x509 -in root.pem -outform DER -out root.der
cat > addroot.c <<'EOC'
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
int wmain(int argc, WCHAR **argv)
{
    BYTE buf[8192]; DWORD n = 0; HANDLE f; HCERTSTORE s;
    if (argc < 2) return 2;
    f = CreateFileW(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE || !ReadFile(f, buf, sizeof(buf), &n, NULL)) return 3;
    CloseHandle(f);
    if (!(s = CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_LOCAL_MACHINE, L"Root"))) return 4;
    if (!CertAddEncodedCertificateToStore(s, X509_ASN_ENCODING, buf, n, CERT_STORE_ADD_REPLACE_EXISTING, NULL)) return 5;
    return CertCloseStore(s, 0) ? 0 : 6;   /* the registry store writes on close */
}
EOC
"$MINGW" -O2 -municode -o addroot.exe addroot.c -lcrypt32 || { echo "FAIL  addroot"; exit 1; }

timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1
"$WINESERVER" -w
w() { timeout -s KILL 60 "$WINE" "$@" 2>/dev/null | tr -d '\r'; }
timeout -s KILL 60 "$WINE" addroot.exe 'Z:'"$T/root.der" >/dev/null 2>&1 || { echo "FAIL  the gate's root was not added"; exit 1; }
D="$WINEPREFIX/drive_c/gate"
mkdir -p "$D" "$WINEPREFIX/drive_c/Program Files/Gate Tool"
cp signed.exe unsigned.exe stranger.exe "$D/"
cp signed.exe "$WINEPREFIX/drive_c/Program Files/Gate Tool/gate tool.exe"
printf 'not a real package' > "$D/pkg.msi"
v() { printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1; }
desc() { w "$1" /describe "$2"; }

out=$(desc consent.exe 'C:\gate\signed.exe /S')
[ "$(v "$out" name)" = "SG Gate Tool" ] && [ "$(v "$out" publisher)" = "Verified publisher: SG Gate Publisher" ] \
    && pass "signed, trusted: its description, \"Verified publisher: SG Gate Publisher\"" || fail "signed: $out"
out=$(desc consent.exe 'C:\gate\unsigned.exe')
[ "$(v "$out" name)" = "unsigned.exe" ] && [ "$(v "$out" publisher)" = "Publisher: Unknown" ] \
    && pass "unsigned: its file name, not what it says it is; \"Publisher: Unknown\"" || fail "unsigned: $out"
out=$(desc consent.exe 'C:\gate\stranger.exe')
[ "$(v "$out" name)" = "stranger.exe" ] && [ "$(v "$out" publisher)" = "Publisher: Unknown" ] \
    && pass "signed by a CA no root vouches for: as unsigned" || fail "stranger: $out"
out=$(desc consent.exe 'C:\Program Files\Gate Tool\gate tool.exe /quiet')
[ "$(v "$out" publisher)" = "Verified publisher: SG Gate Publisher" ] \
    && pass "an unquoted path with spaces and arguments is read as CreateProcess reads it" || fail "spaces: $out"
out=$(desc consent.exe 'C:\windows\system32\cmd.exe /c echo')
[ "$(v "$out" name)" = "cmd.exe" ] && [ "$(v "$out" publisher)" = "Publisher: Stained Glass (part of the system)" ] \
    && pass "one of the system's own programs: the system's" || fail "system: $out"
out=$(desc consent.exe 'msiexec.exe /i C:\gate\pkg.msi /qn')
[ "$(v "$out" publisher)" = "Publisher: Unknown" ] \
    && pass "msiexec /i: the (unsigned) package is checked, not msiexec" || fail "msiexec: $out"
out=$(desc consent.exe '/usr/sbin/gsmartcontrol')
[ "$(v "$out" name)" = "gsmartcontrol" ] && [ -z "$(v "$out" publisher)" ] \
    && pass "a Linux program: no publisher line" || fail "linux: $out"
out=$(desc mutant.exe 'C:\gate\unsigned.exe')
[ "$(v "$out" publisher)" != "Publisher: Unknown" ] \
    && pass "MUTANT CONSENT_TRUSTS_UNSIGNED: unsigned shown as verified (gate catches it)" || fail "mutant: $out"
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
