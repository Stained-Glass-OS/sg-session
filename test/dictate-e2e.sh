#!/bin/sh
# Voice typing with the real model (make test-dictate): speech made by
# espeak-ng goes through sg-dictate --transcribe-file, and through the
# microphone path (--listen, the WAV standing in for the microphone, real-time
# VAD). The words must be there, spoken punctuation must come out as marks,
# fillers must be gone, and two utterances with a pause between them must
# come out as two.
#
# The model: SG_SPEECH_MODEL (a directory), else the machine's, else it is
# downloaded into ~/.cache/stained-glass-speech. Exits 77 (skip) without
# espeak-ng, python3-onnxruntime, or a model that can be had.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SPEECH="$HERE/../speech"
DICTATE="$SPEECH/sg-dictate"
export SG_SPEECH_LIB="$SPEECH"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; exit 77; }

command -v espeak-ng >/dev/null 2>&1 || skip "espeak-ng is not installed"
python3 -c 'import numpy, onnxruntime' 2>/dev/null || skip "python3-numpy/python3-onnxruntime missing"

if [ -z "${SG_SPEECH_MODEL:-}" ]; then
    if [ -e /var/lib/stained-glass-speech/parakeet-tdt-0.6b-v3-int8/.verified ]; then
        SG_SPEECH_MODEL=/var/lib/stained-glass-speech/parakeet-tdt-0.6b-v3-int8
    else
        cache="${XDG_CACHE_HOME:-$HOME/.cache}/stained-glass-speech"
        if ! SG_SPEECH_DIR="$cache" "$DICTATE" --download >/dev/null; then
            skip "the speech model could not be downloaded"
        fi
        SG_SPEECH_MODEL="$cache/parakeet-tdt-0.6b-v3-int8"
    fi
fi
export SG_SPEECH_MODEL
[ -e "$SG_SPEECH_MODEL/encoder-model.int8.onnx" ] || skip "no model at $SG_SPEECH_MODEL"

work=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-dictate-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT
say() { espeak-ng -v en-us -s 150 -w "$work/$1.wav" "$2"; }
say words  "hello world this is a test of voice typing"
say punct  "um I think we should meet tomorrow comma and then go home period"
say lines  "what time is it question mark new line see you soon"
say number "I bought twenty three apples"
say first  "the first sentence is here"
say second "and this is the second one"

out=$(SG_DICTATE_TIMING=1 "$DICTATE" --transcribe-file "$work/words.wav" "$work/punct.wav" \
      "$work/lines.wav" "$work/number.wav" 2>"$work/timing")
printf '%s\n' "$out"
sed 's/^/      /' "$work/timing"
get() { printf '%s\n' "$out" | grep -F "$work/$1.wav" | cut -f2-; }

t=$(get words | tr 'A-Z' 'a-z')
ok=1
for w in hello world test voice typing; do
    case "$t" in *"$w"*) ;; *) ok=0 ;; esac
done
[ $ok = 1 ] && pass "the words are there: $t" || fail "expected words missing: $t"

t=$(get punct)
case "$t" in *"tomorrow, and"*".\"") pass "spoken comma and period are marks: $t" ;;
             *) fail "spoken comma/period not marks: $t" ;; esac
case "$t" in *[Uu]m\ *|*comma*|*period*) fail "a filler or command word was typed: $t" ;;
             *) pass "no filler, no command words" ;; esac

t=$(get lines)
case "$t" in *'it?\n'*) pass "question mark and new line: $t" ;;
             *) fail "question mark/new line missing: $t" ;; esac

t=$(get number)
case "$t" in *23*) pass "a spoken number is digits: $t" ;; *) fail "number not formatted: $t" ;; esac

# The microphone path: a WAV played at real time into the VAD and segmenter.
# Two sentences a pause apart are two utterances, typed with a space between.
python3 - "$work" <<'EOF'
import sys, wave
d = sys.argv[1]
def read(n):
    w = wave.open(f"{d}/{n}.wav"); r = w.getframerate(); b = w.readframes(w.getnframes()); w.close(); return r, b
r, a = read("first"); _, b = read("second")
out = wave.open(f"{d}/two.wav", "wb"); out.setnchannels(1); out.setsampwidth(2); out.setframerate(r)
out.writeframes(a + b"\0\0" * int(r * 1.5) + b); out.close()
EOF
t=$(SG_DICTATE_TIMING=1 SG_DICTATE_AUDIO_FILE="$work/two.wav" timeout 120 \
    "$DICTATE" --listen --seconds 8 2>"$work/listen.log")
printf '      %s\n' "$(tr '\n' ' ' < "$work/listen.log")"
n=$(grep -c 'recognised' "$work/listen.log")
[ "$n" = 2 ] && pass "a pause splits two utterances (VAD)" || fail "expected 2 utterances, got $n"
case "$t" in *[Ff]irst\ sentence*.\ *[Ss]econd*) pass "streamed and joined: $t" ;;
             *) fail "streamed text wrong: $t" ;; esac

# Not continuous: listening stops by itself once the speaker pauses.
t=$(SG_DICTATE_AUDIO_FILE="$work/words.wav" timeout 60 "$DICTATE" --listen --once 2>/dev/null)
case "$(printf '%s' "$t" | tr 'A-Z' 'a-z')" in *hello*) pass "--once stops after the utterance: $t" ;;
    *) fail "--once: $t" ;; esac

# Spoken punctuation in German, French and Spanish (Control Panel's
# language, --language here). espeak-ng's German "Komma" is heard as "Toma";
# "Kommar" is what it says recognisably.
sayv() { espeak-ng -v "$1" -s 120 -w "$work/$2.wav" "$3"; }
sayv de de "Das ist gut, Kommar, und das auch, Punkt"
sayv fr-fr fr "Merci beaucoup, virgule, à bientôt"
sayv es es "Creo que sí, signo de exclamación, nuevo párrafo, nos vemos mañana, punto"
for l in de:de-DE fr:fr-FR es:es-ES de:auto; do
    f=${l%%:*}; lang=${l#*:}
    t=$("$DICTATE" --transcribe-file "$work/$f.wav" --language "$lang" 2>/dev/null)
    case "$f:$t" in
        de:'"Das ist gut, und das auch."') pass "German ($lang): Komma and Punkt are marks: $t" ;;
        fr:*'beaucoup, à bientôt'*) case "$t" in *[Vv]irgule*) fail "French ($lang): $t" ;;
                                        *) pass "French ($lang): virgule is a comma: $t" ;; esac ;;
        es:*'¡Creo que sí!\n\nNos vemos mañana."') pass "Spanish ($lang): exclamation (both marks), paragraph, punto: $t" ;;
        *) fail "$f ($lang): $t" ;;
    esac
done
t=$("$DICTATE" --transcribe-file "$work/de.wav" --language en-US 2>/dev/null)
case "$t" in *Punkt*) pass "German marks are not applied as English: $t" ;; *) fail "en-US on German: $t" ;; esac

# Partial results while speaking: a long sentence at real time into the VAD
# (the interval grows to twice what a partial costs, so a busy machine gets fewer),
# --partials shows what the toolbar would. Several come before the final,
# they grow, and none is typed.
say long "this is a much longer sentence that keeps going for a while so that the partial results have time to show up before the speaker stops"
t=$(SG_DICTATE_AUDIO_FILE="$work/long.wav" timeout 120 "$DICTATE" --listen --once --partials 2>"$work/partial.log")
n=$(grep -c '^partial: ' "$work/partial.log")
printf '      %s partials, last: %s\n' "$n" "$(grep '^partial: ' "$work/partial.log" | tail -1)"
[ "$n" -ge 3 ] && pass "partial results while speaking ($n; fewer on a loaded machine, by design)" || fail "only $n partial results"
first=$(grep '^partial: ' "$work/partial.log" | head -1 | wc -c)
last=$(grep '^partial: ' "$work/partial.log" | tail -1 | wc -c)
[ "$last" -gt "$first" ] && pass "the partial text grows ($first -> $last bytes)" || fail "partials did not grow"
case "$(printf '%s' "$t" | tr 'A-Z' 'a-z')" in *"longer sentence"*"speaker stops"*) pass "the final text is typed once: $t" ;;
    *) fail "final: $t" ;; esac
t=$(SG_DICTATE_AUDIO_FILE="$work/long.wav" timeout 120 "$DICTATE" --listen --once --partials --no-partials 2>"$work/partial.log")
[ "$(grep -c '^partial: ' "$work/partial.log")" = 0 ] && pass "--no-partials: none" || fail "partials despite --no-partials"

# A spoken command is a command, not text.
say del-en "delete that"
t=$("$DICTATE" --transcribe-file "$work/del-en.wav" 2>/dev/null)
[ "$t" = '"<command delete>"' ] && pass "\"delete that\" is a command" || fail "delete that: $t"

[ $fails = 0 ] && { echo "dictate-e2e: OK"; exit 0; }
echo "dictate-e2e: $fails FAILED"
exit 1
