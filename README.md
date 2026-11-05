# dsh-oneclick

Unattended installer for the DSH desktop patch set. One command, no global toolchain.

```
Install.cmd            double-click entry (no admin)
Install.ps1            orchestrator; -DryRun / -NoRestart / -Force / -NoGuard
Uninstall.ps1          revert, restore app.asar, unwire the profile, disarm the guard
Install-Guard.ps1      arms / disarms the update guard
Guard.ps1              drift detector + healer; -Detect / -DryRun / -Watch
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
9. arms the update guard (step 10 skips it with `-NoGuard`)
10. restarts DSH

## Surviving DSH updates

An official update replaces `resources\app` and re-seals `app.asar`. The plugin cannot repair
that from inside the host — `autoApplyOnStart` defaults to `false`, and `settleMayReapply()`
refuses while the asar is sealed ("sealed desktop: skip startup reapply"). After an update the
patch set stays off until someone clicks Apply.

`Guard.ps1` is that someone. It runs outside the host, so nothing holds the asar lock:

```powershell
.\Install-Guard.ps1            # arm: startup launcher (or a scheduled task if elevated)
.\Guard.ps1 -Detect            # report drift, change nothing (exit 3 when drift exists)
.\Guard.ps1 -DryRun            # show the heal command, touch nothing
.\Guard.ps1                    # heal once, now
.\Install-Guard.ps1 -Unregister
```

Drift signals, any one of which triggers a heal:

| signal | meaning |
|---|---|
| `resources\app.asar` exists | update re-sealed the package |
| `resources\dsh-purge-reapply-asar` | the official-update handoff left its marker |
| `prompt-inject.md` or plugin dir missing | user layer wiped |
| patch markers absent in `resources\app\dsh\...` | extracted tree replaced |
| recorded host version != current | the build moved |

Heal = stop DSH -> `node lib\reapply-cli.js` (the plugin's own revert-and-reapply, fresh
extraction from the new asar) -> retire `app.asar` -> start DSH. It stands down while an
installer or another reapply is running, and backs off for 10 minutes after a failure.
It fails **closed**: if the plugin cannot apply to the new build, `app.asar` is left intact and
DSH runs stock instead of a half-patched tree.

Which arming mode you get depends on the shell: an elevated one registers the
`DSH-Purge-Guard` scheduled task (logon + startup + every 5 min); a normal user gets
`%APPDATA%\...\Startup\dsh-purge-guard.vbs`, which starts `Guard.ps1 -Watch` hidden (45 s
polling, single instance via a pid lock). Same loop either way.

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
- Upstream updates overwrite the patched tree; the guard armed in step 9 puts it back. If the patch anchors themselves stop matching a new build, the guard logs `heal: FAILED closed` and leaves the host stock — that is the signal to refresh `payload/`, not to disable the guard.
