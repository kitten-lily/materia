# BUG-003 — storageBoxSshKey "error in libcrypto" — three layers, one symptom

**status:** fixed — production backup verified end-to-end 2026-07-12
(snapshot `1b66a668`, 7.111 KiB, `flutterina` host, daily+weekly+monthly
retention applied, clean exit)
**found:** 2026-07-12, across multiple production runs on flutterina
**severity:** P0 (backup component completely non-functional against the
real Storage Box until all three layers were resolved)
**epic:** e01-restic-backup (already closed — post-ship discovered defects,
not reopened stories)

## Symptom

After BUG-001 (ssh_config path) and BUG-002 (secret mount permissions) got
`ssh` past host key verification and key-permission checks, it still
failed:

```
subprocess ssh: Load key "/run/secrets/ssh_key": error in libcrypto
subprocess ssh: Permission denied, please try again.
subprocess ssh: u630269-sub1@u630269-sub1.your-storagebox.de: Permission denied (publickey,password).
```

`error in libcrypto` means OpenSSH found something key-shaped but the
cryptographic material didn't decode. `ssh-keygen -y` sometimes accepted
the same file and sometimes didn't (depending on the corruption variant),
making this much harder to diagnose than BUG-001/BUG-002.

## Root cause — three distinct layers

### Layer 1: manual paste corruption (original task design)

`.mise/tasks/hz/storagebox/install-key` originally `cat`'d the freshly
generated private key to the terminal with instructions to manually
copy-paste it into an interactive `sops edit` session under a YAML `|-`
block scalar. Terminal scrollback reflow, clipboard managers, or one
misindented line could silently corrupt a multi-line key while leaving it
looking plausible (BEGIN/END markers intact).

**Fix:** rewrote the task to inject the key programmatically via
`jq -Rs .` (JSON-encodes raw bytes exactly) + `sops --set` (decrypts, sets,
re-encrypts in place) — no human ever retypes the value. Also automated
`resticRepository` the same way (deterministic from subaccount lookup, no
`jq -Rs .` needed — single-line value).

### Layer 2: missing trailing newline (the real "error in libcrypto" trigger)

After the `sops --set` automation, the key was still failing. Root cause:
OpenSSH's `ssh_config` `IdentityFile` loader fails with `error in libcrypto`
on an ed25519 key whose final line (`-----END OPENSSH PRIVATE KEY-----`) has
no trailing newline — even though `ssh-keygen -y` accepts the same file.
This is a known OpenSSH limitation (bug #3849). Some `ssh-keygen` builds
produce a key file without the final newline; `jq -Rs .` faithfully
captured those 410 bytes, reproducing the bug.

**Fix attempt 1 (broken):** `sed '$a\'` to append a newline if missing.
This *corrupted* the key on some `sed` implementations (BSD/GNU portability
issue with the `$a\` syntax without a trailing newline in the sed script).
The "fix" made the key worse — `ssh-keygen -y` went from passing to failing.

**Fix attempt 2 (working):** portable bash approach — `tail -c 1 | wc -l`
detects whether the file ends with a newline (0 = no, 1 = yes), `printf
'\n' >>` appends one in-place if missing. No external tool pipes through
the key content, so no risk of mangling. Verified: a no-newline key becomes
loadable after the append; an already-has-newline key is left untouched.

### Layer 3: stale podman secret

After the key was correctly stored in the SOPS vault (verified:
`sops -d | yq -r` → 411 bytes, `ssh-keygen -y` succeeds), the podman secret
on flutterina *still* had the old broken key (410 bytes, `ssh-keygen -y`
fails). Materia didn't recreate the secret because the attribute name
hadn't changed — only its value had, and the existing podman secret wasn't
detected as needing replacement.

**Fix:** `sudo podman secret rm materia-storageBoxSshKey` then
`sudo systemctl start materia-update.service` — removing the stale secret
forced materia to recreate it from the current (valid) vault value. After
that, `restic-backup.service` ran successfully end-to-end.

## Verification (production, 2026-07-12 18:28 UTC)

```
1b66a668  2026-07-12 18:28:40  flutterina  flutterina  daily snapshot    /var/lib/materia/components  7.111 KiB
                                                       weekly snapshot
                                                       monthly snapshot
1 snapshots
Finished restic-backup.service - Restic backup.
```

Full cycle: `restic init` (fresh repo on the Storage Box), `restic backup`
(snapshot created), `restic forget --prune` (retention policy applied),
clean exit. The backup timer is now running daily against the real Storage
Box.

## Key lessons

1. **`ssh -G` resolves config but doesn't load keys.** BUG-001's
   verification used `ssh -G` (which only prints effective config) — it
   couldn't catch key-loading failures. Only a real connection attempt
   (`ssh -v` against a real or test sshd) exercises the key load path.
2. **`ssh-keygen -y` and `ssh` use different key-loading code paths.**
   `ssh-keygen -y` is more tolerant — it accepts keys with missing trailing
   newlines that `ssh`'s `IdentityFile` loader rejects with `error in
   libcrypto`. Don't trust `ssh-keygen -y` alone as a "key is valid" check.
3. **`sed '$a\'` is not portable.** The `$a\` syntax without a trailing
   newline in the sed script behaves differently on GNU vs BSD sed and can
   silently corrupt piped content. Use `tail -c 1 | wc -l` + `printf '\n'
   >>` for portable "ensure trailing newline" logic.
4. **Podman secrets can go stale.** Materia doesn't always detect that a
   secret's *value* changed (vs. its *name*). After rotating a secret
   value in the vault, if the container still sees the old value, `podman
   secret rm` the stale one and re-run `materia-update` to force
   recreation.
5. **Command substitution `$(...)` strips trailing newlines.** My
   diagnostic `$(jq -r '.[0].SecretData')` lost the key's trailing newline,
   making the podman secret look broken (410 bytes) when it might have been
   fine. Use `jq -rj` (raw, no trailing newline added) piped directly to a
   file to preserve exact bytes.

## Related

- BUG-001 (`specs/bugs/BUG-001-restic-backup-ssh-config-wrong-path.md`) —
  host key verification (ssh_config mounted at wrong sysconfdir path).
- BUG-002 (`specs/bugs/BUG-002-restic-backup-secret-mount-permissions.md`) —
  secret mount permissions (0444 too open for SSH private keys).
- This was the third and final layer of the sftp-auth onion: config wiring
  → permission bits → key content integrity + staleness.
