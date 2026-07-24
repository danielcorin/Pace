---
name: try-it
description: Builds the current Pace working tree and installs it to /Applications so the user can try it as a real app — replaces any running copy and relaunches it. Use when the user says "try it", "try it out", "let me try", or asks to run or install the changes.
---

# Try It: build, install, and relaunch Pace

Run the installer from the repo root:

```sh
bash .agents/skills/try-it/scripts/try-it.sh
```

(The script may also be invoked by absolute path from any directory — it
resolves the repo root itself.)

The script regenerates the Xcode project if `project.yml` changed, builds
Release with manual Developer ID signing, quits any running copy, atomically
replaces `/Applications/Pace.app`, resets Pace's TCC records only when the
code signature actually changed, relaunches, and verifies the app is running.
Do not build or install by hand instead — the signing identity and the
TCC-reset comparison are load-bearing (see comments in the script).

## After it runs

- Tell the user the new build is running. Pace is a menu-bar app with no Dock
  icon — point them at the clipboard icon in the menu bar.
- If the script printed "clearing stale permission records", tell the user to
  re-grant Accessibility: System Settings → Privacy & Security →
  Accessibility. Current macOS won't self-register the app there, so they may
  need the + button with /Applications/Pace.app.

## Failure notes

- Build failure leaves the installed copy untouched; report the tail of the
  build log and stop.
- Writing to /Applications can be denied by a sandboxed shell — rerun the
  script with the sandbox disabled.
- Local builds are not distributable; use `scripts/publish-release.sh` for
  notarized releases.
