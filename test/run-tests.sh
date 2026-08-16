#!/usr/bin/env bash
# Unit tests for the pure helpers in lib/common.sh (norm, resolve_model,
# allow_check, gsm7). No network, no systemd, no gateway — runs against a
# throwaway $HOME so it never touches real config/state.
#
#   test/run-tests.sh        run all, print PASS/FAIL, exit non-zero on failure
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# Isolate: point HOME + config at a temp dir so sourcing common.sh (which mkdirs
# state and reads the allow-list) can't hit or create real files.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" MOTO_SMS_ENV="$TMP/env"
mkdir -p "$TMP/.config/moto-sms"
printf '+17326642170\n# a comment line\n555-000-1234\n' > "$TMP/.config/moto-sms/allow"

# shellcheck source=/dev/null
. "$REPO/lib/common.sh"

pass=0 fail=0
# ok <desc> <got> <want>
ok() {
	if [ "$2" = "$3" ]; then pass=$((pass+1))
	else fail=$((fail+1)); printf 'FAIL: %s\n  got:  [%s]\n  want: [%s]\n' "$1" "$2" "$3"; fi
}
# check <desc> <cmd...> — passes if the command succeeds (exit 0)
yes_check() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s (expected success)\n' "$1"; fi; }
no_check()  { if "${@:2}"; then fail=$((fail+1)); printf 'FAIL: %s (expected failure)\n' "$1"; else pass=$((pass+1)); fi; }

# ── norm: keep trailing 10 digits, strip everything else ──────────────────────
ok "norm formatted"   "$(norm '+1 (732) 664-2170')" "7326642170"
ok "norm plain"       "$(norm '17326642170')"        "7326642170"
ok "norm short"       "$(norm '2170')"               "2170"
ok "norm letters"     "$(norm 'abc123def4567890xy')" "1234567890"
ok "norm intl >10"    "$(norm '+447911123456')"       "7911123456"

# ── resolve_model: alias table + passthrough for unknown ids ──────────────────
ok "resolve haiku"    "$(resolve_model haiku)"   "claude-haiku-4-5-20251001"
ok "resolve sonnet"   "$(resolve_model sonnet)"  "claude-sonnet-4-6"
ok "resolve opus"     "$(resolve_model opus)"    "claude-opus-4-8"
ok "resolve fable"    "$(resolve_model fable)"   "claude-fable-5"
ok "resolve passthru" "$(resolve_model claude-custom-id)" "claude-custom-id"

# ── allow_check: fail-closed gate, comment + blank tolerant ───────────────────
yes_check "allow listed number"    allow_check "$(norm '+17326642170')"
yes_check "allow number w/ dashes"  allow_check "$(norm '555-000-1234')"
no_check  "deny unlisted number"    allow_check "9999999999"
no_check  "deny empty key"          allow_check ""

# ── gsm7: transliterate common non-GSM-7 chars, drop the rest ─────────────────
ok "gsm7 curly quote"  "$(printf 'it\xe2\x80\x99s' | gsm7)"      "it's"
ok "gsm7 em dash"      "$(printf 'a \xe2\x80\x94 b' | gsm7)"     "a - b"
ok "gsm7 arrow"        "$(printf 'x \xe2\x86\x92 y' | gsm7)"     "x -> y"
ok "gsm7 accent fold"  "$(printf 'caf\xc3\xa9' | gsm7)"          "cafe"
ok "gsm7 backtick"     "$(printf 'a \x60b\x60' | gsm7)"          "a 'b'"
ok "gsm7 ellipsis"     "$(printf 'wait\xe2\x80\xa6' | gsm7)"     "wait..."
ok "gsm7 drop emoji"   "$(printf 'hi\xf0\x9f\x98\x80!' | gsm7)"  "hi!"
ok "gsm7 upper accent" "$(printf 'CAF\xc3\x89' | gsm7)"          "CAFE"
ok "gsm7 eszett"       "$(printf 'stra\xc3\x9fe' | gsm7)"        "strasse"
ok "gsm7 ae ligature"  "$(printf 'encyclop\xc3\xa6dia' | gsm7)"  "encyclopaedia"
ok "gsm7 bullet"       "$(printf 'a\xe2\x80\xa2b' | gsm7)"       "a-b"
ok "gsm7 ascii passthru" "$(printf 'ok ~!@#$%%^&*()' | gsm7)"    'ok ~!@#$%^&*()'

# ── send_sms: DRYRUN path — gsm7 folding + MAXCHARS cap, no network ────────────
# SMS_DRYRUN=1 makes send_sms echo "[DRYRUN reply -> <to>] <body>" instead of
# hitting the gateway, so we can assert the outbound body without any curl.
unwrap() { sed 's/^\[DRYRUN[^]]*\] //'; }   # strip the DRYRUN prefix, keep body
ok "send folds curly quote" \
	"$(SMS_DRYRUN=1 send_sms "$(printf 'it\xe2\x80\x99s')" x | unwrap)" "it's"
ok "send caps at MAXCHARS" \
	"$( ( MAXCHARS=10; SMS_DRYRUN=1 send_sms "$(printf 'a%.0s' {1..50})" x ) | unwrap)" \
	"aaaaaaaaaa"
ok "send drops emoji-only to nothing" \
	"$(SMS_DRYRUN=1 send_sms "$(printf '\xf0\x9f\x98\x80')" x)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
