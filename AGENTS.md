# BackMeUp

A free, open-source macOS menu bar app that runs Time Machine backups on a schedule. The spec is issue #1.

## Rules

- Nothing personal goes in this repo: no real names, Wi-Fi names, IP or hardware addresses, hostnames, or volume names. The GitHub username in URLs and the bundle ID is the only exception. Replace personal values in saved command output before committing it.

## Building and testing

`scripts/test.sh` runs the tests and `scripts/build-app.sh` builds `build/BackMeUp.app`, with the Command Line Tools only. See `docs/agents/building.md` for the layout, how to write tests and toolchain quirks.

## Agent skills

### Issue tracker

GitHub Issues on `Blowoffvalve/BackMeUp`, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root, created only when they're first needed. See `docs/agents/domain.md`.
