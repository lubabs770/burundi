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
MAXCHARS="${CLAUDE_SMS_MAXCHARS:-4000}" # reply cap. Transport is SMS (SmsManager,
# not RCS): auto-split into 153-char GSM-7 segments (67 if any non-GSM char), and
# the phone reassembles them into one message (confirmed). So this is only a
# cost/runaway guard, not a protocol limit; override with CLAUDE_SMS_MAXCHARS.

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

# Send an SMS out the gateway (or print, when SMS_DRYRUN=1). $1=body $2=to
send_sms() {
	local body="$1" to="$2"
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
