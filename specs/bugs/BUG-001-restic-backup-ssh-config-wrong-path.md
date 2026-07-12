# BUG-001 — restic-backup ssh_config mounted at wrong path, host key verification fails

**status:** fixed
**found:** 2026-07-12, first real `materia update` + manual `systemctl start
restic-backup.service` run on flutterina (production)
**severity:** P0 (backup component completely non-functional against the
real Storage Box)
**epic:** e01-restic-backup (already closed — this is a post-ship
discovered defect, not a reopened story)

## Symptom

Real production run against the actual Storage Box failed immediately:

```
restic-backup[446829]: subprocess ssh: Host key verification failed.
restic-backup[446829]: Fatal: unable to open repository at sftp://u630269-sub1@u630269-sub1.your-storagebox.de:23/restic: unable to start the sftp session, error: error receiving version packet from server: read |0: file already closed
```

`ensureRepo` then tried `restic init`, which failed the same way, and the
service exited 1.

## Root cause

`images/restic-backup/Dockerfile` builds the static `ssh` client with:

```
./configure LDFLAGS=-static --with-privsep-path=/tmp
```

No `--prefix`/`--sysconfdir` flag. OpenSSH's `configure` defaults
`sysconfdir` to `${prefix}/etc` and `prefix` to `/usr/local` when neither is
given — so this specific binary's **compiled-in system-wide config path is
`/usr/local/etc/ssh_config`**, not the conventional `/etc/ssh/ssh_config`
most distro packages use. Confirmed directly via `strings` on the extracted
binary:

```
/usr/local/etc/ssh_config
/usr/local/etc/ssh_known_hosts
/usr/local/etc/ssh_known_hosts2
```

e01s05's `.container.gotmpl` mounted the `ssh_config` data resource at
`/etc/ssh/ssh_config` — a path this binary never reads. With no system
config applied and no `$HOME` (scratch has none, so
`~/.ssh/config`/`~/.ssh/known_hosts` don't exist either), `ssh` fell back to
its compiled-in defaults: `StrictHostKeyChecking ask`. With no TTY to
prompt (running under systemd/podman), "ask" auto-denies —
"Host key verification failed", exactly as observed.

## Fix

Retargeted the `Volume=` mount in `restic-backup.container.gotmpl` from
`/etc/ssh/ssh_config` to `/usr/local/etc/ssh_config`. No image rebuild
needed — the fix is purely in where the existing, already-correct
`ssh_config` content gets mounted.

## Verification (before landing)

1. `strings` on the extracted `ssh` binary from the published image —
   confirmed `/usr/local/etc/ssh_config` is the only compiled-in
   system-wide config path (no `/etc/ssh/...` variant present).
2. `ssh -G somehost` (prints effective resolved config without connecting)
   with `HOME` unset and the file mounted at the OLD path
   (`/etc/ssh/ssh_config`) — reproduced the bug: `stricthostkeychecking
   ask`, default `~/.ssh/known_hosts`.
3. Same test with the file mounted at the CORRECTED path
   (`/usr/local/etc/ssh_config`), via the real published image through
   `podman run --entrypoint /usr/bin/ssh ... -G somehost` (not a chroot
   simulation — the actual container filesystem and binary) — resolved
   correctly: `stricthostkeychecking true`, `identityfile
   /run/secrets/ssh_key`, `userknownhostsfile /run/secrets/known_hosts`.

Real sftp authentication against the actual Storage Box still needs to be
re-verified on flutterina (this environment has no access to the production
repository/secrets) — that's the next step, not something provable from
local tooling alone.

## Follow-up considered, not done

Adding `--sysconfdir=/etc/ssh` to the Dockerfile's `./configure` invocation
would make the image use the conventional path and avoid this class of
surprise for any future config mount. Not done here — would require an
image rebuild + new digest + re-verification cycle, and the mount-path fix
alone fully resolves the bug without touching the image. Worth doing in a
future housekeeping pass if another `ssh`-path surprise shows up.
