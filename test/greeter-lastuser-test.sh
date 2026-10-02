#!/bin/sh
# The login screen offers the last account first (David 2026-10-02):
# sg-greet-bridge keeps the account of each sign-in and tells the next
# greeter "LASTUSER <name>"; CANCEL ends a sign-in begun ("Other user").
# Natively, against greetd-stub, with a scripted greeter; the window's side
# is test/greeter-lastuser-ui-test.sh. Mutant: -DSG_MUTANT_NO_LAST_USER.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BRIDGE="${SG_BRIDGE:-$HERE/build/sg-greet-bridge}"
for f in "$BRIDGE" "$HERE/build/greetd-stub"; do [ -x "$f" ] || { echo "SKIP: $f not built"; exit 77; }; done
T=$(mktemp -d); SP=; RC=0
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
ME=$(id -un)
export SG_GREETER_LAST_USER="$T/last-user"
run() {   # greeter script -> the lines the greeter got
    rm -f "$T/greetd.sock"
    "$HERE/build/greetd-stub" "$T/greetd.sock" PASS >"$T/stub.out" 2>&1 & SP=$!
    i=0; while [ ! -S "$T/greetd.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    : > "$T/got"
    GREETD_SOCK="$T/greetd.sock" timeout 20 "$BRIDGE" /bin/true "$1" >/dev/null 2>&1
    kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SP=
}
cat > "$T/signin.sh" <<EOS
#!/bin/sh
printf 'HELLO\n'
while IFS= read -r line; do
    printf '%s\n' "\$line" >> "$T/got"
    case "\$line" in
        READY) printf 'USER %s\n' "$ME" ;;
        PROMPT_*) printf 'REPLY PASS\n' ;;
        SUCCESS|FAILURE*) exit 0 ;;
    esac
done
EOS
cat > "$T/look.sh" <<EOS
#!/bin/sh
printf 'HELLO\n'
while IFS= read -r line; do
    printf '%s\n' "\$line" >> "$T/got"
    case "\$line" in
        LASTUSER*) printf 'USER %s\n' "\${line#LASTUSER }" ;;
        PROMPT_*) printf 'CANCEL\n'; sleep 0.5; printf 'USER someone\n' ;;
        SUCCESS|FAILURE*) exit 0 ;;
    esac
done
EOS
chmod +x "$T/signin.sh" "$T/look.sh"
run "$T/signin.sh"
grep -q '^SUCCESS' "$T/got" && pass "a sign-in through the stand-in greetd" || fail "no sign-in: $(tr '\n' '|' < "$T/got")"
[ "$(cat "$T/last-user" 2>/dev/null)" = "$ME" ] && pass "the bridge keeps its account" || fail "last-user: $(cat "$T/last-user" 2>/dev/null)"
run "$T/look.sh"
grep -qx "LASTUSER $ME" "$T/got" && pass "the next login screen is offered it (LASTUSER)" || fail "no LASTUSER: $(tr '\n' '|' < "$T/got")"
grep -q 'stub: cancel_session' "$T/stub.out" && pass "CANCEL ends the sign-in begun (Other user)" || fail "no cancel_session: $(tail -3 "$T/stub.out")"
echo root > "$T/last-user"
run "$T/look.sh"
grep -q '^LASTUSER' "$T/got" && fail "a system account was offered" || pass "a system account (root) is never offered"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
