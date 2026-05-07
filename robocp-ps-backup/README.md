# robocp-ps-backup

Robocopy-based mirroring backup for Windows, with deletion tracking, multi-target
mirrors, toast notifications, and a markdown run ledger.

## What it does

For each configured **source**, mirrors it to one or more **target** directories
using `robocopy /MIR`. Around each mirror it adds:

- **Deletion tracker** - files removed from the source aren't immediately erased
  from the target. They're moved to `<DeletedDir>\<yyyy-MM-dd>\` first, so if
  you accidentally delete something at the source, you have a few days to grab
  it back. Old date folders get pruned per `RetentionDays`.
- **Per-pair excludes** - directory names (`/XD`) and file globs (`/XF`) skip
  noisy stuff like `.git`, `node_modules`, `.venv`, etc., on the way out.
- **Per-run timestamped log** - every run gets its own
  `backup-<dd-MM-yyyy--HH-mm>.log` in the log dir. Auto-pruned by `LogRetentionDays`.
- **`runs.md` ledger** - single markdown table file appended on every real run
  with status (✅ / ⚠️ / ❌), date/time, exit code, log filename, and summary.
  Pruned by the same retention.
- **Windows toast notifications** - fired on start, success, warning, and
  failure. Toasts have a clickable button that opens the relevant file.
- **Three-tier outcome** - robocopy rc 0–7 = OK, 8–15 = WARN (locked files etc.,
  not a real failure), 16+ = FAIL. The toast body shows totals upfront:
  `OK: 3  Warn: 1  Fail: 0`.

## Files

| File                  | Purpose                                                    |
|-----------------------|------------------------------------------------------------|
| `backup.ps1`          | The mirroring script                                       |
| `backup.config.psd1`  | User-facing configuration (sources, targets, retention)    |
| `install-task.ps1`    | One-shot installer that registers a Windows scheduled task |
| `run-hidden.vbs`      | Tiny launcher used by the scheduled task to start the script with no console window |
| `logs/`               | Per-run log files + `runs.md` (created on first run)       |

## Quick start

1. Edit `backup.config.psd1` - set your sources, targets, and excludes.
2. Run once manually to verify:
   ```powershell
   .\backup.ps1
   ```
3. Install the scheduled task:
   ```powershell
   .\install-task.ps1
   ```
   Default: fires at 02:00, 14:00, and 21:00 every day.

## Configuration

All user-facing config lives in `backup.config.psd1` next to the script
(override path with `-ConfigPath`).

```powershell
@{
    BackupPairs = @(
        @{
            Source       = 'D:\Repos'
            Targets      = @(
                @{ Path = 'E:\Backup\Repos';      DeletedDir = 'E:\Backup\Repos_deleted' }
                @{ Path = '\\nas\backup\Repos';   DeletedDir = '\\nas\backup\Repos_deleted' }
            )
            ExcludeDirs  = @('.git', 'node_modules', 'venv', '.venv')
            ExcludeFiles = @('*.tmp')
        }
    )

    UseDailyFlag     = $false   # if $true, only first successful run/day mirrors
    RetentionDays    = 3        # dated DeletedDir folders to keep
    LogDir           = 'D:\Repos\wip\robocp-ps-backup\logs'
    LogRetentionDays = 14       # backup-*.log files + runs.md row retention
    FlagFile         = 'D:\Repos\wip\robocp-ps-backup\logs\last_run.flag'
}
```

### Field reference

| Field                     | Required | Default            | Notes                                                |
|---------------------------|----------|--------------------|------------------------------------------------------|
| `BackupPairs[].Source`    | yes      | -                  | Absolute path or UNC                                 |
| `BackupPairs[].Targets[]` | yes      | -                  | Each: `@{ Path = ...; DeletedDir = ...; Optional = $false }` |
| `BackupPairs[].Targets[].Optional` | no | `$false`        | Skip this target with a runs.md note when the drive/share root is unreachable (USB, flaky NAS) |
| `BackupPairs[].ExcludeDirs`  | no    | `@()`              | Directory names matched anywhere in tree (`/XD`)     |
| `BackupPairs[].ExcludeFiles` | no    | `@()`              | File names / wildcards matched anywhere (`/XF`)      |
| `UseDailyFlag`            | no       | `$true`            | If `$true`, run skipped after first daily success    |
| `RetentionDays`           | no       | `3`                | Per-target deletion-tracker retention                |
| `LogDir`                  | no       | `<script>\logs`    | Where per-run logs + `runs.md` live                  |
| `LogRetentionDays`        | no       | `14`               | Days of log files + `runs.md` rows to keep           |
| `FlagFile`                | no       | `<LogDir>\last_run.flag` | Daily-flag state file (only used if `UseDailyFlag`) |
| `LogOpener`               | no       | `$null`            | Program for the toast "View log / View runs" buttons. Bare name on `PATH` (`notepad`, `code`) or absolute exe path. Unresolved -> falls back to the default app. |

Validation runs before any state mutation. Bad config exits with code 2 and a
"Backup config invalid" toast - distinct from runtime failure (exit 1).

## Running

```powershell
.\backup.ps1                              # honors UseDailyFlag
.\backup.ps1 -Force                       # bypass the daily-flag gate
.\backup.ps1 -ConfigPath C:\other.psd1    # use a different config file
```

## Scheduling

```powershell
.\install-task.ps1                                       # default times
.\install-task.ps1 -Times '07:00','13:00','19:00'        # custom times
.\install-task.ps1 -TaskName 'Backup-Mirror-Home'        # custom task name
.\install-task.ps1 -Uninstall                            # remove
```

Scheduled task settings:

- Runs as the current user with **interactive logon** (so toast notifications
  appear).
- `-StartWhenAvailable`: missed triggers (PC asleep) catch up on next wake.
- `-AllowStartIfOnBatteries`: laptops back up too.
- `-MultipleInstances IgnoreNew`: a long-running mirror won't get clobbered by
  the next trigger.
- **No console window.** The task invokes `wscript.exe run-hidden.vbs`, which
  in turn starts `powershell.exe` hidden. Calling `powershell.exe -WindowStyle
  Hidden` directly still flashes a black window for a fraction of a second on
  task start; the `.vbs` wrapper avoids that entirely. Exit code from
  `backup.ps1` is propagated through, so the task's *Last Run Result* stays
  meaningful.

## Output

### Per-run log

```
logs/backup-29-04-2026--14-32.log
```

Holds both the script's own status lines (timestamp + level + message) and
robocopy's output for every target.

### Run ledger (`runs.md`)

One row per real run, e.g.:

```
| Script     | Status | Date       | Time     | RC | Log                              | Message                       |
| ---        | ---    | ---        | ---      | ---| ---                              | ---                           |
| backup.ps1 | ✅     | 2026-04-29 | 14:32:01 | 0  | backup-29-04-2026--14-32.log     | OK: 2  Warn: 0  Fail: 0       |
| backup.ps1 | ⚠️     | 2026-04-29 | 22:00:03 | 0  | backup-29-04-2026--22-00.log     | OK: 1  Warn: 1  Fail: 0       |
| backup.ps1 | ❌     | 2026-04-30 | 02:00:00 | 1  | backup-30-04-2026--02-00.log     | OK: 0  Warn: 0  Fail: 2       |
```

Config-invalid runs and "already ran today" no-ops are intentionally not
recorded - only real backup attempts.

### Toasts

| Trigger | Title                       | Body                          | Button       |
|---------|-----------------------------|-------------------------------|--------------|
| Start   | Backup starting             | `N source(s) -> M target(s)`  | View log     |
| OK      | Backup OK                   | `OK: x  Warn: y  Fail: z`     | View runs    |
| Warning | Backup OK with warnings     | `OK: x  Warn: y  Fail: z`     | View runs    |
| Fail    | Backup FAILED               | `OK: x  Warn: y  Fail: z`     | View runs    |

The "View log / View runs" button uses `activationType="protocol"` with a
`file:///` URI, so the file opens with whatever app is registered as the
default for that extension.

Set `LogOpener` in the config to override that  e.g. `LogOpener = 'code'`
opens both files in VS Code, `LogOpener = 'notepad'` forces Notepad. The
script resolves the value against `PATH` (or treats it as an absolute path)
on each run; if it can't be resolved the buttons silently fall back to the
default-app behavior and a `WARN` line lands in the run log. Implementation
detail: when an opener is resolved the script writes `open-log.vbs` and
`open-runs.vbs` next to the logs as tiny WSH launchers, and the toast
buttons point at those.

## Exit codes

| Code | Meaning                                                         |
|------|-----------------------------------------------------------------|
| 0    | Run completed (OK or WARN - warnings don't fail the run)        |
| 1    | Runtime failure (one or more targets had robocopy rc >= 16)     |
| 2    | Config invalid                                                  |

## Robocopy exit code tiers

| RC range | Tier | Meaning                                                  |
|----------|------|----------------------------------------------------------|
| 0–7      | OK   | Combinations of "files copied / extras / mismatches"     |
| 8–15     | WARN | Some files failed (locked/in-use); rest succeeded        |
| 16+      | FAIL | Fatal: source unreachable, out of disk, root access, etc.|

Most "warning" outcomes you'll actually see are **9** (copies + locked files)
and **11** (copies + extras + locked files), both very common with `/MIR` against
trees containing IDE indexes, git internals, browser caches, etc.

## External / USB drive targets

Mark a target `Optional = $true` so the script gracefully skips it when the
drive isn't plugged in:

```powershell
@{ Path = 'F:\Backup\Repos'; DeletedDir = 'F:\Backup\Repos_deleted'; Optional = $true }
```

Before any I/O, the script checks the path's drive root (`F:\` here, or the
share root for UNC paths). If it isn't mounted/reachable, the target is
skipped, the run log records a `WARN` line, and the `runs.md` row's message
column gets a `Skip: N (<paths> unreachable)` suffix so you can see at a
glance what didn't run. A skip alongside successful targets keeps the run
✅ OK; if *every* target was skipped (e.g. USB-only config and nothing
plugged in), the run is marked ⚠️ WARN to make it obvious nothing actually
backed up.

Required (non-optional) targets are unchanged - a missing drive root is
still treated as a hard failure there.

## Network targets

Use UNC paths directly - don't rely on mapped drives:

```powershell
@{ Path = '\\nas\backup\Repos'; DeletedDir = '\\nas\backup\Repos_deleted' }
```

Drive mappings are per-session and may not exist when Task Scheduler fires.
UNC paths don't depend on any mapping state.

If the share requires credentials, save them once with `cmdkey`:

```powershell
cmdkey /add:nas /user:youruser /pass:yourpass
```

Stored in Windows Credential Manager, picked up automatically by scheduled tasks.

## Notes / gotchas

- **Locked files are normal.** With `/MIR` against active source trees you'll
  see rc=9 / rc=11 occasionally. The script counts these as warnings, not
  failures, and the target retains the previous version of the locked files
  until they're free.
- **`/Z` is on by default.** Restartable mode adds slight overhead on local
  copies but is genuinely useful for network/UNC targets - partial transfers
  resume instead of starting over.
- **Toast notifications need an interactive desktop session.** If you ever
  switch the scheduled task to run as `SYSTEM` or "whether logged on or not",
  toasts will silently fail (logged as `WARN`) but the backup itself continues.
- **PowerShell 5.1 reads `.ps1` files as ANSI without a UTF-8 BOM**, which is
  why the script source is pure ASCII; emoji glyphs in `runs.md` are built
  at runtime via `[char]` casts. Don't paste em-dashes / emoji directly into
  string literals in the script unless you save the file with a BOM.
- **`runs.md` is written via .NET (`[System.IO.File]::WriteAllText` with
  UTF-8-no-BOM)**, not `Set-Content`/`Add-Content`, because the latter are
  inconsistent on PS 5.1 (BOM on create, none on append, mixed encodings on
  some viewers).
