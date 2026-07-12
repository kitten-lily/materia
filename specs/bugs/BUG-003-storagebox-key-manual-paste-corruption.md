# BUG-003 — storageBoxSshKey manual paste corrupted the key (error in libcrypto)

**status:** fixed (tooling) / **needs user action** (flutterina's current
key value must be regenerated — the corrupted content can't be recovered)
**found:** 2026-07-12, third real production run on flutterina (after
BUG-001 and BUG-002 fixes got past host key verification and permission
checks)
**severity:** P0 (backup component still non-functional against the real
Storage Box)
**epic:** e01-restic-backup (already closed — this is a post-ship
discovered defect, not a reopened story)

## Symptom

With BUG-001 and BUG-002 fixed, `ssh` finds the key file, at the right
permissions — and fails to decode it:

```
subprocess ssh: Load key "/run/secrets/ssh_key": error in libcrypto
subprocess ssh: Permission denied, please try again.
subprocess ssh: u630269-sub1@u630269-sub1.your-storagebox.de: Permission denied (publickey,password).
```

`error in libcrypto` means OpenSSH found something key-shaped but the
cryptographic material itself doesn't decode — the file's content is
corrupted, not merely misplaced or mis-permissioned (those were BUG-001 and
BUG-002).

## Root cause

`.mise/tasks/hz/storagebox/install-key` generates a fresh ed25519 keypair
into a `mktemp -d` directory, installs the *public* key on the Storage Box,
then — for the *private* key — just `cat`s it to the terminal with an
instruction to manually copy-paste it into an interactive `sops edit`
session, indented under a YAML `|-` block scalar. The temp directory is
deleted (`trap 'rm -rf "$_tmpdir"' EXIT`) as soon as the task exits, so the
only surviving copy of the private key is whatever made it through that
manual paste.

This is the most fragile step in the whole install flow: terminal
scrollback reflow, clipboard managers, tmux/screen re-wrapping, or a
single misindented line in the YAML block scalar can all silently corrupt
a multi-line private key while leaving it *looking* plausible (BEGIN/END
markers intact, roughly the right shape) — exactly consistent with
`error in libcrypto` rather than an outright "not a key" rejection.

No way to inspect the actual corrupted value from this environment (SOPS
vault, no age key here) to confirm the exact corruption mechanism, but the
manual-paste step is the only place in the entire pipeline where the key's
raw bytes pass through unversioned, unvalidated human interaction.

## Fix (tooling)

Rewrote `install-key` to inject the private key straight into the vault
programmatically, removing the manual paste entirely:

```sh
_key_json=$(jq -Rs . < "$_tmpdir/id_ed25519")
sops --set "[\"components\"][\"restic-backup\"][\"storageBoxSshKey\"] ${_key_json}" "$_vault"
```

`jq -Rs .` JSON-encodes the raw key file's exact bytes (embedded `\n`
escapes, no reflow risk); `sops --set` decrypts the vault, sets the value,
and re-encrypts in place — all without a human ever seeing or retyping the
key material.

**Verified locally** with a throwaway age key + throwaway ed25519 key (not
production values): encrypted a test vault, ran the exact `jq -Rs .` +
`sops --set` sequence, decrypted, extracted the value, `diff`'d against the
original key file (byte-identical modulo a harmless trailing newline from
the test's own extraction method — not present in the stored value), and
confirmed `ssh-keygen -y -f <recovered>` successfully derives the public
key — proof the round-tripped value is a valid, loadable private key.

## Required follow-up: flutterina's current key must be regenerated

The already-corrupted `storageBoxSshKey` value in `attributes/flutterina.yml`
can't be un-corrupted — the original key material only ever existed in a
now-deleted `mktemp -d`. **You need to re-run the (now-fixed) task:**

```sh
mise hz:storagebox:install-key --box-name backup --server-name flutterina
```

This generates a *new* keypair, installs the new public key on the Storage
Box (safe — doesn't require removing the old, now-orphaned public key
first, though cleaning it up from `authorized_keys` is reasonable
housekeeping), and writes the new private key into the vault via the fixed
`sops --set` path. Needs to be run interactively (subaccount SSH password
prompt) — not something this environment can do.

## Related

- BUG-001 (`specs/bugs/BUG-001-restic-backup-ssh-config-wrong-path.md`) —
  host key verification.
- BUG-002 (`specs/bugs/BUG-002-restic-backup-secret-mount-permissions.md`) —
  secret mount permissions.
- This is the third and (pending re-running `install-key`) hopefully final
  layer of the same sftp-auth onion: config wiring → permission bits → key
  content integrity.
