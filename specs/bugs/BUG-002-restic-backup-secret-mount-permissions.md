# BUG-002 — storageBoxSshKey secret mount too permissive for OpenSSH

**status:** fixed
**found:** 2026-07-12, second real production run on flutterina (after
BUG-001's fix landed and got past host key verification)
**severity:** P0 (backup component still completely non-functional against
the real Storage Box)
**epic:** e01-restic-backup (already closed — this is a post-ship
discovered defect, not a reopened story)

## Symptom

With BUG-001 fixed, `ssh` now reads our `ssh_config` and gets to the point
of actually loading the private key — and rejects it:

```
subprocess ssh: Permissions 0444 for '/run/secrets/ssh_key' are too open.
subprocess ssh: It is required that your private key files are NOT accessible by others.
subprocess ssh: This private key will be ignored.
subprocess ssh: Load key "/run/secrets/ssh_key": bad permissions
subprocess ssh: Permission denied, please try again.
```

## Root cause

`restic-backup.container.gotmpl` used the `secretMount` macro:

```
{{ secretMount "storageBoxSshKey" "/run/secrets/ssh_key" }}
```

Pulled materia's actual source
(`internal/materia/snippet.go`,
[stryan/materia](https://github.com/stryan/materia)) to check what this
macro can actually emit:

```go
"secretMount": func(args ...string) string {
    if len(args) == 0 {
        return ""
    }
    if len(args) == 1 {
        return fmt.Sprintf("Secret=%v,type=mount,target=%v", host.SecretName(args[0]), args[0])
    }
    return fmt.Sprintf("Secret=%v,type=mount,target=%v", host.SecretName(args[0]), args[1])
},
```

It **only ever** produces `Secret=<name>,type=mount,target=<value>` — there
is no way to pass `mode=`, `uid=`, or `gid=` through this macro, despite the
[materia-templates(5) docs](https://primamateria.systems/documentation/latest/reference/materia-templates.5.html)
prose ("Optionally, provide additional arguments as defined in the Podman
manual") implying otherwise. Podman's `type=mount` secret default mode
(confirmed `0444` in this Podman version, via the observed error) is
group/other-readable — OpenSSH's strict private-key permission check
refuses to load any key file where group or other has any access bit set.

## Fix

Bypassed the `secretMount` macro for this one secret and hand-wrote the
`Secret=` line with an explicit `mode=0400`:

```
Secret=materia-storageBoxSshKey,type=mount,target=/run/secrets/ssh_key,mode=0400
```

The `materia-` prefix is confirmed via materia's `SecretName()` (test mock:
`SecretName("mysecret") → "materia-mysecret"`, plain string concatenation,
no case transforms) and this repo's `materia-update.container` config has
no `secrets_prefix` override, so the default applies. No image rebuild
needed — same digest, only the manifest line changes.

`resticPassword`'s `secretEnv` (env-var secret, not a file mount) is
unaffected — permission bits don't apply to env vars the same way, no fix
needed there.

## Verification (before landing)

Reproduced the exact mechanism locally with `podman secret create` +
`podman run --secret name,type=mount,target=...,mode=0400 alpine stat ...`:
confirmed the resulting file is `400 root:root` (owner-read-only, matches
the container's UID 0 runtime context — no `USER` in the Dockerfile) —
within OpenSSH's accepted range (no group/other bits set). Default (no
`mode=`) reproduced the observed `0444` bug.

Real sftp authentication against the actual Storage Box still needs to be
re-verified on flutterina — this environment has no access to the
production repository/secrets to prove that leg locally.

## Related

- BUG-001 (`specs/bugs/BUG-001-restic-backup-ssh-config-wrong-path.md`) —
  the host-key-verification bug this fix builds on top of.
