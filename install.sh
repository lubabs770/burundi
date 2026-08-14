#!/usr/bin/env bash
# Install moto-sms: symlink the entrypoint onto PATH and (re)point the systemd
# --user units at it. Idempotent — safe to re-run after editing the program.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BIN="$HOME/.local/bin"
UNITS="$HOME/.config/systemd/user"
mkdir -p "$BIN" "$UNITS"

chmod +x "$REPO/bin/moto-sms"
ln -sf "$REPO/bin/moto-sms" "$BIN/moto-sms"
echo "linked $BIN/moto-sms -> $REPO/bin/moto-sms"

for u in moto-sms-relay moto-sms-watchdog; do
	sed "s|@BIN@|$BIN/moto-sms|g" "$REPO/systemd/$u.service" > "$UNITS/$u.service"
	echo "wrote $UNITS/$u.service"
done

systemctl --user daemon-reload
systemctl --user enable --now moto-sms-relay.service moto-sms-watchdog.service
systemctl --user restart moto-sms-relay.service moto-sms-watchdog.service
echo "done. 'moto-sms status' to check."
