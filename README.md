# win-cache-cleaner

A PowerShell script that clears browser caches and Windows junk files to free
up disk space. Portable — it only uses environment variables
(`$env:LOCALAPPDATA`, `$env:APPDATA`), so it works on any Windows user
account without editing paths or usernames.

## What it clears

**Standard mode (no admin required):**
- Browser caches: Chrome, Brave, Edge, Opera, Opera GX, Vivaldi, Firefox
- `%LOCALAPPDATA%\Temp`
- Crash dumps, D3D shader cache, NVIDIA/AMD driver caches
- Windows thumbnail cache
- Windows Error Reporting dumps
- pip's download cache (`pip cache purge`)

**Aggressive mode (`-Aggressive`, requires Administrator):**
- `C:\Windows\Temp`
- Prefetch
- Windows Update download cache (`SoftwareDistribution\Download`)
- Delivery Optimization cache
- Empties the Recycle Bin
- Flushes DNS cache

Before deleting anything, the script kills the browser's main process *and*
its background helpers (updater, crash handler, WebView, plugin containers)
so files aren't skipped due to file locks. If files are still locked after
3 kill-and-retry attempts, it logs what's left instead of failing silently.

## Usage

```powershell
# Standard cleanup
.\Clear-SystemCache.ps1

# Preview only — nothing is deleted, just shows what would happen
.\Clear-SystemCache.ps1 -DryRun

# Full cleanup including system-level targets (run PowerShell as Administrator first)
.\Clear-SystemCache.ps1 -Aggressive

# Preview what aggressive mode would delete, without touching anything
.\Clear-SystemCache.ps1 -Aggressive -DryRun

# Skip browser cache clearing, junk folders only
.\Clear-SystemCache.ps1 -SkipBrowsers
```

If you get a script-blocked error, allow local scripts once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Output

- Prints progress and estimated space freed as it runs.
- If anything couldn't be deleted (locked by a running process), a
  `cleanup-report.txt` is written next to the script listing each stuck
  folder, item count, remaining size, and example file paths.

## Scheduling (optional)

To run automatically, e.g. every Sunday at 9am:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PWD\Clear-SystemCache.ps1`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 9am
Register-ScheduledTask -TaskName "ClearSystemCache" -Action $action -Trigger $trigger -Description "Weekly cache cleanup"
```

For a scheduled task that includes `-Aggressive`, register it with
`-RunLevel Highest` so it runs elevated without a UAC prompt each time.

## Safety notes

- Only clears `Cache` / `Code Cache` subfolders inside browser profiles —
  never the whole profile, so passwords, bookmarks, extensions, and saved
  logins are untouched.
- `-DryRun` is the safest way to check what a run (especially
  `-Aggressive`) would touch before actually running it.
- Aggressive mode deletes files outside your user profile and empties the
  Recycle Bin — review the dry-run output first if you're unsure.

## License

MIT — see [LICENSE](LICENSE).
