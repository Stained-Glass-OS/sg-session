#!/bin/sh
# Who polkit asks for an administrator (config/polkit/49-stained-glass-admins.rules):
# the rules run as polkitd runs them -- every rules file in name order, the
# first admin rule that answers wins -- beside Debian's 50-default.rules
# (unix-group:sudo). pkexec (GParted, GSmartControl) must ask sg-admins, or
# the person's Yes on the consent screen is refused (qa4 2026-10-25).
# Needs node; skips (77) without it. SG_MUTANT=LATE files the rule after
# 50-default.rules, as a 50- name would sort.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
R="$HERE/config/polkit/49-stained-glass-admins.rules"
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v node >/dev/null || { echo "SKIP: node missing"; exit 77; }
[ -f "$R" ] || { echo "FAIL  $R missing"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
# Debian's default, as polkit 126 ships it
printf 'polkit.addAdminRule(function(action, subject) {\n    return ["unix-group:sudo"];\n});\n' > "$T/50-default.rules"
name=$(basename "$R"); [ "${SG_MUTANT:-}" = LATE ] && name=50-stained-glass-admins.rules
cp "$R" "$T/$name"
ids=$(node -e '
const fs = require("fs"), path = require("path"), dir = process.argv[1];
const admin = [];
const polkit = { addAdminRule: f => admin.push(f), addRule: () => {}, Result: {}, log: () => {} };
for (const f of fs.readdirSync(dir).filter(n => n.endsWith(".rules")).sort())
    new Function("polkit", fs.readFileSync(path.join(dir, f), "utf8"))(polkit);
const subject = { user: "bob", isInGroup: () => false, local: true, active: true };
for (const f of admin) { const r = f({ id: "org.gnome.gparted" }, subject); if (r && r.length) { console.log(r.join(" ")); break; } }
' "$T")
case " $ids " in *" unix-group:sg-admins "*) pass "pkexec asks the administrators (sg-admins): $ids" ;; *) fail "polkit asks '$ids', not sg-admins" ;; esac
case " $ids " in *" unix-group:sudo "*) pass "sudo's members still count" ;; *) fail "sudo dropped: '$ids'" ;; esac
if [ "$(printf '%s\n' "$(basename "$R")" 50-default.rules | LC_ALL=C sort | head -1)" = "$(basename "$R")" ]; then
    pass "the rule sorts before Debian's 50-default.rules"
else fail "the rule sorts after 50-default.rules"; fi
if grep -q 'config/polkit/49-stained-glass-admins.rules' "$HERE/Makefile"; then pass "installed"; else fail "not installed"; fi
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
