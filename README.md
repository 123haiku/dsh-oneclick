# dsh-oneclick

Unattended installer for the DSH desktop patch set. One command, no global toolchain.

```
Install.cmd            double-click entry (no admin)
Install.ps1            orchestrator; -DryRun / -NoRestart / -Force
Uninstall.ps1          revert, restore app.asar, unwire the profile
payload/               vendored plugin + prompt injection (works offline)
```

## What it does

1. locates the DSH install and its bundled Node runtime
2. closes DSH
3. stages the plugin into `~/.dsh/plugins/dsh-purge` and the desktop profile
4. wires the profile (`dependencies` + `dsh.profile.bundles`)
5. installs `~/.dsh/prompt-inject.md`
6. runs `dsh-purge --apply` with the host's own Node
7. moves `app.asar` aside so the host loads the patched tree
8. snapshots the drift baseline
9. restarts DSH

## Use

```powershell
.\Install.cmd
.\Install.ps1 -DryRun         # stage only, nothing applied
.\Install.ps1 -NoRestart      # keep your current session alive
.\Uninstall.ps1               # back to stock
```

Logs land in `%TEMP%\dsh-oneclick-<timestamp>.log`.

## Notes

- Re-running is safe: the plugin stage is replaced, the profile edit is idempotent.
- `app.asar` is never deleted — it becomes `app.asar.dshpurge-backup`, which `Uninstall.ps1` restores.
- Upstream updates overwrite the patched tree. Keep the drift check scheduled (see the sibling `dsh-prompt-layer-notes` repo).
