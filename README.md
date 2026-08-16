# moto-sms

Claude-over-SMS + remote shell, driven through the Moto G7 headless SMS gateway.
Text the phone; the omarchy box relays each message, routes it to Claude or a live
shell, and texts the reply back.

## Layout

    bin/moto-sms        single entrypoint (subcommands below)
    lib/common.sh       shared config, paths, allow-list, model table, gateway I/O
    systemd/*.service   unit templates (@BIN@ is filled in by install.sh)
    install.sh          symlink onto PATH + (re)point the --user units

Config/state/data keep their XDG homes (only the code lives here):

    config  ~/.config/moto-sms/{env,allow}
    state   ~/.local/state/moto-sms/          threads/, seen-ids
    data    ~/.local/share/moto-sms/          *.log, inbox.jsonl

## Subcommands

    moto-sms relay            poll gateway /inbox, dispatch each new SMS  (systemd)
    moto-sms watchdog         revive phone over adb if the tailnet dies    (systemd)
    moto-sms handle           process ONE message (raw JSON on stdin) — the router
    moto-sms send <to> <msg>  send an SMS out the gateway
    moto-sms status           gateway health + service states + threads
    moto-sms threads          list threads per sender
    moto-sms tail [n]         tail the assistant log

## SMS command grammar (what you text the phone)

    <plain text>              talk to Claude on the active thread
    .new [name]               fresh thread (also clears a context-overflowed one)
    .stop                     detach current thread
    .resume <name>            switch threads  (.resume alone lists them)
    .convos                   list threads (*=active) with model
    !<cmd>                    run ONE raw shell command (any mode)
    .sh                       sticky raw-shell mode (plain text -> live tmux shell)
    .aish                     sticky shell-assist (Claude runs the commands)
    .ai                       back to conversation
    .model [haiku|sonnet|opus|fable]   per-thread model (no arg = show)
    .status .help
    .ccstatus                 Claude Code account + git identity + active 5h usage

Commands use a leading '.' (easier to reach than '/' on phone keyboards).
Unknown '.'-tokens aren't intercepted, so shell paths (./run.sh, ., .bashrc)
still work in shell mode.

Raw shell runs in a per-sender tmux session (`sms-<10digits>`), so `cd`/env
persist across texts.

## Install / update

    ./install.sh

Idempotent. Edits to `bin/moto-sms` take effect immediately (systemd runs the
symlink); only unit changes need a re-run.

## Tests

    ./test/run-tests.sh

Unit tests for the pure helpers in `lib/common.sh` (`norm`, `resolve_model`,
`allow_check`, `gsm7`, and `send_sms` via `SMS_DRYRUN=1`). No network/systemd —
runs against a throwaway `$HOME`.

## Security

Past the allow-list (`~/.config/moto-sms/allow`, matched on trailing 10 digits,
fail-closed) a text has FULL control of this box: raw shell including `rm`, and
Claude with `--dangerously-skip-permissions`. SMS sender IDs are spoofable — the
allow-list is the only boundary. Keep it to trusted numbers.
