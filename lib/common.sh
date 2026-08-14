#!/usr/bin/env bash
# Shared config, paths, and helpers for the moto-sms program.
# Sourced by bin/moto-sms — not meant to be run on its own.
#
# XDG homes (config/state/data stay put; only the CODE lives in the repo):
#   config -> ~/.config/moto-sms/{env,allow}
#   state  -> ~/.local/state/moto-sms/
#   data   -> ~/.local/share/moto-sms/

CFG="${MOTO_SMS_ENV:-${HOME}/.config/moto-sms/env}"
ALLOW="${HOME}/.config/moto-sms/allow"
STATE="${HOME}/.local/state/moto-sms"
THREADS="${STATE}/threads"
SEEN="${STATE}/seen-ids"
LOG_DIR="${HOME}/.local/share/moto-sms"
ALOG="${LOG_DIR}/assistant.log"
INBOX_LOG="${LOG_DIR}/inbox.jsonl"
RECV_LOG="${LOG_DIR}/received.log"
WLOG="${LOG_DIR}/watchdog.log"
mkdir -p "$THREADS" "$LOG_DIR"

# shellcheck source=/dev/null
[ -f "$CFG" ] && . "$CFG"

DEFMODEL="${CLAUDE_SMS_MODEL:-haiku}"   # default model ALIAS for new threads
# Reply cap. Measured limits on THIS SIM/carrier (2026-08-14): GSM-7 messages
# deliver up to ~4076 chars (multipart, reassembled to one bubble); ANY non-GSM-7
# char forces UCS-2 and the message FAILS entirely (even 1 emoji, 0 delivered).
# So outbound is transliterated to GSM-7 (gsm7 below) and capped just under 4076.
MAXCHARS="${CLAUDE_SMS_MAXCHARS:-3800}"

log()  { printf '%s  %s\n' "$(date -Is)" "$*" >> "$ALOG"; }
wlog() { printf '%s  %s\n' "$(date -Is)" "$*" >> "$WLOG"; }

# Normalize a phone number to its trailing 10 digits (so +1XXXXXXXXXX / 1XXXX / XXXX all match).
norm() { printf '%s' "$1" | tr -cd '0-9' | tail -c 10; }

# Allow-list gate. $1 = 10-digit key. Returns 0 if allowed (fail closed).
allow_check() {
	local key="$1" line
	[ -z "$key" ] && return 1
	[ -f "$ALLOW" ] || return 1
	while IFS= read -r line; do
		line="${line%%#*}"; [ -z "${line// /}" ] && continue
		[ "$(norm "$line")" = "$key" ] && return 0
	done < "$ALLOW"
	return 1
}

# Map a friendly alias to a real model id (pass through unknown = already an id).
resolve_model() {
	case "$1" in
		haiku)  echo claude-haiku-4-5-20251001 ;;
		sonnet) echo claude-sonnet-4-6 ;;
		opus)   echo claude-opus-4-8 ;;
		fable)  echo claude-fable-5 ;;
		*)      echo "$1" ;;
	esac
}

# Transliterate to the GSM 03.38 charset. This SIM/carrier cannot send UCS-2 at
# all, so any non-GSM-7 char (emoji, em/en-dash, curly quotes, ellipsis, bullets,
# arrows, backtick, accents, PUA icon glyphs) must be folded to a GSM-7 equivalent
# or dropped — otherwise the whole SMS silently fails. Backtick (`) is notably NOT
# in GSM-7, so it maps to an apostrophe.
gsm7() {
	if command -v perl >/dev/null 2>&1; then
		perl -CSD -pe '
			s/[\x{2012}-\x{2015}\x{2212}]/-/g;                 # dashes -> -
			s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}]/'"'"'/g; # curly single -> '"'"'
			s/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}]/"/g;   # curly double -> "
			s/\x{2026}/.../g;                                   # ellipsis
			s/[\x{2022}\x{2023}\x{25CF}\x{25E6}\x{00B7}]/-/g;   # bullets -> -
			s/\x{2192}/->/g; s/\x{2190}/<-/g; s/\x{21D2}/=>/g;  # arrows
			s/[\x{00A0}\x{2007}\x{202F}\x{2009}\x{200A}\x{200B}]/ /g; # spaces -> space
			s/\x{2122}/(TM)/g; s/[\x{00A9}\x{00AE}]//g;         # tm/(c)/(r)
			s/[\x{FE00}-\x{FE0F}]//g;                            # variation selectors
			s/[\x{E000}-\x{F8FF}\x{F0000}-\x{10FFFD}]//g;        # PUA (nerd-font icons)
			tr/`/'"'"'/;                                         # backtick -> apostrophe (not in GSM-7)
			s/[\x{00E0}-\x{00E5}]/a/g; s/[\x{00E8}-\x{00EB}]/e/g; # fold Latin-1 accents to ASCII
			s/[\x{00EC}-\x{00EF}]/i/g; s/[\x{00F2}-\x{00F6}]/o/g;
			s/[\x{00F9}-\x{00FC}]/u/g; s/\x{00F1}/n/g; s/\x{00E7}/c/g; s/[\x{00FD}\x{00FF}]/y/g;
			s/[\x{00C0}-\x{00C5}]/A/g; s/[\x{00C8}-\x{00CB}]/E/g; s/[\x{00CC}-\x{00CF}]/I/g;
			s/[\x{00D2}-\x{00D6}]/O/g; s/[\x{00D9}-\x{00DC}]/U/g; s/\x{00D1}/N/g; s/\x{00C7}/C/g;
			s/\x{00DF}/ss/g; s/\x{00E6}/ae/g; s/\x{00C6}/AE/g; s/\x{0153}/oe/g; s/\x{0152}/OE/g;
			s/[^\n\r\x20-\x7E]//g;                               # drop anything else non-ASCII (emoji, etc.)
		'
	else
		iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr '`' "'" || LC_ALL=C tr -cd '\11\12\15\40-\176'
	fi
}

# Send an SMS out the gateway (or print, when SMS_DRYRUN=1). $1=body $2=to
send_sms() {
	local body="$1" to="$2"
	body=$(printf '%s' "$body" | gsm7)   # carrier rejects UCS-2; force GSM-7
	body=${body:0:$MAXCHARS}
	[ -z "$body" ] && return 0
	if [ "${SMS_DRYRUN:-0}" = "1" ]; then
		printf '[DRYRUN reply -> %s] %s\n' "$to" "$body"; return 0
	fi
	log "reply to ${to}: ${body}"
	[ -n "${GATEWAY_URL:-}" ] || return 0
	local code
	code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
		-u "${GATEWAY_USER}:${GATEWAY_PASS}" -H 'Content-Type: application/json' \
		-d "$(jq -n --arg m "$body" --arg p "$to" '{message:$m, phoneNumbers:[$p]}')" \
		"${GATEWAY_URL}/message" 2>>"$ALOG")
	log "gateway POST /message -> HTTP ${code}"
}
