#!/bin/sh
# Plays the greeter: reads the bridge on stdin, answers on stdout, and records
# the outcome where the test can see it.
set -u
: "${SG_TEST_USER:=sguser}"
: "${SG_TEST_PW:=PASS}"
: "${SG_TEST_RESULT:=/tmp/greeter-result}"
: > "$SG_TEST_RESULT"
printf 'HELLO\n'
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$SG_TEST_RESULT"
    case "$line" in
        READY)           printf 'USER %s\n' "$SG_TEST_USER" ;;
        PROMPT_SECRET*)  printf 'REPLY %s\n' "$SG_TEST_PW" ;;
        PROMPT_VISIBLE*) printf 'REPLY %s\n' "$SG_TEST_PW" ;;
        SUCCESS)         exit 0 ;;
        FAILURE*)        exit 0 ;;
    esac
done
