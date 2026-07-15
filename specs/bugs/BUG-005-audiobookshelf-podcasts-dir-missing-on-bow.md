# BUG-005 — audiobookshelf.service crash-looped on bow: Podcasts bind-mount source missing

**status:** fixed
**found:** 2026-07-15, while investigating an unrelated finding surfaced
during BUG-004 testing (`materia-update` failing on bow blocked
verification of that fix attempt)
**severity:** P1 (blocked `materia-update` entirely on bow — any future
repo change, not just audiobookshelf, would fail to apply on that host
until fixed, same "one component blocks the whole host" pattern as
other incidents in this file)
**epic:** standalone (audiobookshelf component, recently merged — commit
`411c11f`, issue #36/#37)

## Symptom

`materia-update.service` failed on bow:

```
FATA service audiobookshelf.service unhealthy: error applying service change for audiobookshelf.service: service state change failed
```

`systemctl status audiobookshelf.service` showed a crash loop (`Start
request repeated too quickly`, restart counter hitting systemd's rate
limit) with the actual error on each attempt:

```
Error: statfs /var/lib/materia-data/Podcasts: no such file or directory
```

Exit code 125 — a podman-level failure (bad `podman run` invocation),
not an application error inside the container.

## Root cause

`audiobookshelf.container.gotmpl` bind-mounts two host paths from bow's
LVM data disk:

```
Volume=/var/lib/materia-data/AudioBooks:/audiobooks:ro,z
Volume=/var/lib/materia-data/Podcasts:/podcasts:z
```

`/var/lib/materia-data/AudioBooks` (along with sibling `Books` and
`Music`, owned by other components) already existed on bow — presumably
created when those libraries' existing media was copied onto the data
disk. `/var/lib/materia-data/Podcasts` never existed; podcasts are a
new content type with no pre-existing files to seed a directory
creation, and provisioning never created an empty one. Podman does not
auto-create rootful bind-mount source directories that don't exist —
it fails the `run` outright.

This is host state (the LVM data disk under `/var/lib/materia-data`,
provisioned per-server, not managed by materia — see
`provisioning/BARE-METAL.md` and the LVM setup script), not a defect in
the component's `.container.gotmpl` itself. The component correctly
expects the directory to exist; nothing in this repo currently creates
it automatically.

## Fix

```
sudo mkdir -p /var/lib/materia-data/Podcasts
sudo chown 1000:1000 /var/lib/materia-data/Podcasts
```
(UID/GID 1000 matching the ownership of the sibling `AudioBooks`/
`Books`/`Music` directories — audiobookshelf runs as UID 1000 per the
minimus-images gotcha in AGENTS.md, and needs write access to download
new podcast episodes into this path.)

Then `sudo systemctl restart materia-update.service` — confirmed green
(`Finished materia-update.service`, no FATA), `audiobookshelf.service`
`active (running)`.

## Follow-up considered, not done

This class of bug (a component's `.container.gotmpl` assumes a host
path exists, but nothing provisions it) could recur for any future
bind-mounted library path. Not fixing generally here — no existing
mechanism in this repo's Butane templates or LVM setup script creates
per-component library subdirectories (they're populated by the
operator copying media onto the disk, not by IaC). Worth a documented
convention (e.g. "new bind-mount library components must state their
expected host directory and confirm it exists before merging the
component") if this pattern bites again, but not urgent enough to
block on for a single occurrence.
