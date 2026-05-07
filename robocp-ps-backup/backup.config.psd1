@{
    # ----- Required -----
    # One entry per source. Each can mirror to one or more targets.
    BackupPairs = @(
        @{
            Source       = 'D:\Repos'

            # One or more {Path, DeletedDir} destinations.
            #   Path       = where the mirror lives.
            #   DeletedDir = where files removed from the source get parked, dated <yyyy-MM-dd>.
            #   Optional   = if $true, the target is skipped (with a note in runs.md)
            #                when its drive/share root isn't mounted. Use for external
            #                USB drives or flaky network shares. Default: $false.
            Targets      = @(
                @{ Path = 'E:\Backup\Repos'; DeletedDir = 'E:\Backup\Repos_deleted' }
                @{ Path = 'F:\Backup\Repos'; DeletedDir = 'F:\Backup\Repos_deleted'; Optional = $true }
            )

            # Directory names matched anywhere in the tree (passed to robocopy /XD).
            ExcludeDirs  = @('.git', 'node_modules', 'venv', '.venv', 'logs')

            # File names / wildcards matched anywhere in the tree (passed to robocopy /XF).
            # E.g. @('*.tmp', 'Thumbs.db')
            ExcludeFiles = @('*.log')
        }

        # UNC / network share targets. Use UNC paths directly - mapped drives
        # are per-session and may not exist when the scheduled task fires.
        # The offsite NAS is marked Optional so the run still succeeds when
        # it's offline (e.g. VPN down).
        @{
            Source       = 'C:\Users\MyUser\Documents'
            Targets      = @(
                @{ Path = '\\nas\backup\Documents';         DeletedDir = '\\nas\backup\Documents_deleted' }
                @{ Path = '\\offsite-nas\backup\Documents'; DeletedDir = '\\offsite-nas\backup\Documents_deleted'; Optional = $true }
            )
            ExcludeDirs  = @()
            ExcludeFiles = @('~$*', '*.tmp')
        }

        @{
            Source       = 'C:\Users\MyUser\Desktop'
            Targets      = @(
                @{ Path = 'E:\Backup\Desktop'; DeletedDir = 'E:\Backup\Desktop_deleted' }
                @{ Path = 'F:\Backup\Desktop'; DeletedDir = 'F:\Backup\Desktop_deleted'; Optional = $true }
            )
            ExcludeDirs  = @('.git', 'node_modules', 'venv', '.venv', 'logs')
            ExcludeFiles = @('*.log')
        }
    )

    # ----- Optional (defaults shown in comments) -----

    # If $true, the script writes a "ran today" flag on success and skips on
    # subsequent runs the same day (useful for safety on manual invocation).
    # If $false, every run mirrors the current state regardless - the right
    # setting when you want a scheduled task to fire multiple times a day.
    # Default: $true
    UseDailyFlag = $false

    # How many dated <DeletedDir>\<yyyy-MM-dd> folders to keep. Default: 3
    RetentionDays = 3

    # Directory for per-run log files. Each run writes a separate
    # backup-<dd-MM-yyyy--HH-mm>.log here, plus the persistent runs.md ledger.
    # Default: <script dir>\logs
    # LogDir = 'C:\path\to\logs'

    # How many days of run logs (backup-*.log) to keep. runs.md is never pruned.
    # Default: 14
    LogRetentionDays = 14

    # "Already ran today" flag file. Default: <LogDir>\last_run.flag
    # FlagFile = 'C:\path\to\last_run.flag'

    # Optional. Program used to open the per-run log and runs.md from the toast
    # notification buttons. Either a bare command name resolved against PATH
    # ('notepad', 'code', 'subl') or an absolute path to an executable
    # ('C:\Tools\Notepad++\notepad++.exe').
    # If the value can't be resolved at runtime the script falls back to the
    # default behavior (file:// URI -> registered default app).
    # Default: $null (use the OS default app for each file extension).
    LogOpener = 'notepad'
}
