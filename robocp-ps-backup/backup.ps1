<#
.SYNOPSIS
    Daily backup with robocopy /MIR plus rolling deletion tracker.

.DESCRIPTION
    For each configured Source -> Target pair:
      1. Detects files present in Target but missing from Source (deleted at source).
      2. Moves them into <DeletedDir>\<yyyy-MM-dd>\ preserving relative paths.
      3. Mirrors Source -> Target with robocopy /MIR.
      4. Prunes <DeletedDir>\<date> entries older than $RetentionDays.

    Skips automatically if it has already completed successfully today (flag file).
    Use -Force to override.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Backup-WithDeletionTracker.ps1
    powershell.exe -ExecutionPolicy Bypass -File .\Backup-WithDeletionTracker.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ConfigPath
)

# ============================== CONFIG ==============================
# All user-facing config lives in backup.config.psd1 next to this script
# (override with -ConfigPath). See that file for the schema.

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'backup.config.psd1'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "Config file not found: $ConfigPath" -ForegroundColor Red
    Write-Host "Create one based on backup.config.psd1 in the repo." -ForegroundColor Red
    exit 2
}

try {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigPath
} catch {
    Write-Host "Failed to parse $ConfigPath`: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$BackupPairs      = $cfg.BackupPairs
$RetentionDays    = if ($null -ne $cfg.RetentionDays)    { [int]$cfg.RetentionDays }    else { 3 }
$LogDir           = if ($cfg.LogDir)                     { [string]$cfg.LogDir }        else { Join-Path $PSScriptRoot 'logs' }
$LogRetentionDays = if ($null -ne $cfg.LogRetentionDays) { [int]$cfg.LogRetentionDays } else { 14 }
$FlagFile         = if ($cfg.FlagFile)                   { [string]$cfg.FlagFile }      else { Join-Path $LogDir 'last_run.flag' }
$UseDailyFlag     = if ($null -ne $cfg.UseDailyFlag)     { [bool]$cfg.UseDailyFlag }    else { $true }
$LogOpener        = if ($cfg.LogOpener -and -not [string]::IsNullOrWhiteSpace([string]$cfg.LogOpener)) {
                        [string]$cfg.LogOpener
                    } else { $null }

# Each run writes its own timestamped log file inside $LogDir.
$LogFile = Join-Path $LogDir ("backup-{0}.log" -f (Get-Date -Format 'dd-MM-yyyy--HH-mm'))

# Normalize optional per-pair fields so call sites don't have to defend against $null.
foreach ($p in @($BackupPairs)) {
    if (-not $p) { continue }
    if ($null -eq $p.ExcludeDirs)  { $p['ExcludeDirs']  = @() }
    if ($null -eq $p.ExcludeFiles) { $p['ExcludeFiles'] = @() }
    foreach ($t in @($p.Targets)) {
        if (-not $t) { continue }
        if ($null -eq $t.Optional) { $t['Optional'] = $false }
    }
}

# Robocopy options stay inline (developer-tuning, not user config).
# /R:2 = retry twice. /W:5 = 5s between retries (default 30 is painful).
# /NDL /NFL keep the log compact; remove them if you want every file/dir listed.
$RobocopyArgs = @('/MIR', '/Z', '/R:2', '/W:5', '/MT:8', '/NP', '/NDL', '/NFL')

# ============================== HELPERS =============================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Add-RunRecord {
    # Appends one row to runs.md (next to the log file). Header row is written on first use.
    # Only called for real runs - config-invalid and already-ran-today no-ops are intentionally skipped.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OK','OKWARN','WARN','FAIL')]
        [string]$Tier,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        $runsFile = Join-Path $LogDir 'runs.md'

        # UTF-8 without BOM. Set-Content/Add-Content -Encoding UTF8 on Windows PowerShell 5.1
        # is inconsistent (BOM on create, none on append, some viewers then misread as ANSI).
        # Going through .NET directly is reliable across every PS version.
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $nl   = "`r`n"

        if (-not (Test-Path -LiteralPath $runsFile)) {
            $header = '| Script | Status | Date | Time | RC | Log | Message |' + $nl +
                      '| --- | --- | --- | --- | --- | --- | --- |' + $nl
            [System.IO.File]::WriteAllText($runsFile, $header, $utf8)
        }

        $scriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'backup.ps1' }
        $logName    = Split-Path -Leaf $LogFile
        # Built from codepoints so the .ps1 source can stay pure ASCII (PowerShell 5.1
        # reads .ps1 files as ANSI without a BOM, which would corrupt literal glyphs).
        # 0x2705 = WHITE HEAVY CHECK MARK (already emoji-presentation by default).
        # 0x26A0 = WARNING SIGN; 0xFE0F variation selector forces emoji presentation
        #          (without VS-16 it renders as a plain text glyph, not the yellow triangle).
        # 0x274C = CROSS MARK (already emoji-presentation by default).
        $warnGlyph = [string][char]0x26A0 + [string][char]0xFE0F
        $okGlyph   = [string][char]0x2705
        $status = switch ($Tier) {
            'OK'     { $okGlyph }
            'OKWARN' { $okGlyph + $warnGlyph }
            'WARN'   { $warnGlyph }
            'FAIL'   { [string][char]0x274C }
        }
        $date       = Get-Date -Format 'yyyy-MM-dd'
        $time       = Get-Date -Format 'HH:mm:ss'
        # Pipes inside a row would break the table - escape them.
        $msgEsc     = $Message -replace '\|', '\|'

        $row = ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f
                $scriptName, $status, $date, $time, $ExitCode, $logName, $msgEsc) + $nl
        [System.IO.File]::AppendAllText($runsFile, $row, $utf8)
    } catch {
        Write-Log "Failed to append runs.md: $($_.Exception.Message)" 'WARN'
    }
}

function ConvertTo-FileUri {
    # Turns an absolute Windows path into a properly-encoded file:/// URI.
    # Spaces, &, and other special chars are escaped via System.Uri.
    param([Parameter(Mandatory)][string]$Path)
    return [System.Uri]::new($Path).AbsoluteUri
}

function Send-Toast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message = '',
        # Each action is a hashtable: @{ Content = 'View log'; Url = 'file:///...' }.
        # Clicking the button hands the URL to the OS protocol handler -
        # file:/// opens the path with the registered default app.
        [hashtable[]]$Actions = @()
    )

    # Piggyback on the built-in PowerShell AppUserModelID so toasts actually show
    # without registering a Start Menu shortcut. Attribution will read "Windows PowerShell".
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotification,        Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,     ContentType=WindowsRuntime] | Out-Null

        $titleXml = [System.Security.SecurityElement]::Escape($Title)
        $msgXml   = [System.Security.SecurityElement]::Escape($Message)

        $actionsXml = ''
        if ($Actions -and $Actions.Count -gt 0) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append('<actions>')
            foreach ($a in $Actions) {
                $c = [System.Security.SecurityElement]::Escape([string]$a.Content)
                $u = [System.Security.SecurityElement]::Escape([string]$a.Url)
                [void]$sb.Append("<action content=`"$c`" activationType=`"protocol`" arguments=`"$u`" />")
            }
            [void]$sb.Append('</actions>')
            $actionsXml = $sb.ToString()
        }

        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml(@"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$titleXml</text>
            <text>$msgXml</text>
        </binding>
    </visual>
    $actionsXml
</toast>
"@)

        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        # Toasts need an interactive desktop session - under SYSTEM / Task Scheduler "run whether
        # logged on or not" this will fail. Don't let it kill the backup.
        Write-Log "Toast notification failed: $($_.Exception.Message)" 'WARN'
    }
}

function Resolve-LogOpener {
    # Resolves a config 'LogOpener' value to an absolute exe/cmd path, or $null
    # if not configured / not found. A WARN is logged when a value was supplied
    # but couldn't be resolved so the silent fall-back is visible in the log.
    # Accepts a bare name to look up on PATH ('notepad', 'code', 'subl') or an
    # absolute path to an executable.
    param([string]$Opener)

    if ([string]::IsNullOrWhiteSpace($Opener)) { return $null }

    if ([System.IO.Path]::IsPathRooted($Opener)) {
        if (Test-Path -LiteralPath $Opener -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Opener).Path
        }
        Write-Log "LogOpener '$Opener' not found - falling back to default app" 'WARN'
        return $null
    }

    $cmd = Get-Command -Name $Opener -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    Write-Log "LogOpener '$Opener' not found on PATH - falling back to default app" 'WARN'
    return $null
}

function Get-OpenerActionUri {
    # Returns a URI for a toast 'protocol' action that opens $TargetFile.
    # When $OpenerExe is set, writes a small WSH (.vbs) launcher beside the logs
    # that runs that program with the file as argument and returns its file:///
    # URI - Windows resolves .vbs to wscript.exe (silent), no console flash for
    # GUI exes; .cmd-based openers (e.g. code.cmd) flash briefly while the cmd
    # wrapper exits, which is acceptable for a click-to-open path.
    # Without an opener, returns the file's own URI so Windows uses the
    # registered default app - matching the original behavior.
    # If wrapper-write fails for any reason, falls back to the file URI.
    param(
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$WrapperName,
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$OpenerExe
    )

    if ([string]::IsNullOrWhiteSpace($OpenerExe)) {
        return (ConvertTo-FileUri $TargetFile)
    }

    $wrapperPath = Join-Path $LogDirectory $WrapperName
    $exeEsc      = $OpenerExe.Replace('"', '""')
    $fileEsc     = $TargetFile.Replace('"', '""')

    $body = @"
Set sh = CreateObject("WScript.Shell")
sh.Run """$exeEsc"" ""$fileEsc""", 1, False
"@

    try {
        # UTF-16 LE with BOM is the unicode encoding WSH auto-detects for .vbs.
        # UTF-8 BOM here causes 800A0408 ("invalid character") at line 1, char 1
        # because WSH doesn't recognize the BOM bytes and parses them as source.
        [System.IO.File]::WriteAllText($wrapperPath, $body, [System.Text.Encoding]::Unicode)
        return (ConvertTo-FileUri $wrapperPath)
    } catch {
        Write-Log "Failed to write opener wrapper '$wrapperPath' - using default app: $($_.Exception.Message)" 'WARN'
        return (ConvertTo-FileUri $TargetFile)
    }
}

function Test-Configuration {
    # Validates $BackupPairs / $RetentionDays before anything mutates state.
    # Returns $true if config is usable, $false otherwise (errors logged).
    $errs = @()

    if ($RetentionDays -lt 1) {
        $errs += "RetentionDays must be >= 1 (got $RetentionDays)"
    }
    if (-not $BackupPairs -or @($BackupPairs).Count -eq 0) {
        $errs += 'BackupPairs is empty - nothing to back up'
    }

    $seenTargets = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $seenDeletedDirs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt @($BackupPairs).Count; $i++) {
        $p   = $BackupPairs[$i]
        $tag = "BackupPairs[$i]"

        if ([string]::IsNullOrWhiteSpace($p.Source)) {
            $errs += "$tag.Source is required"
        }
        foreach ($prop in 'ExcludeDirs','ExcludeFiles') {
            if ($null -ne $p.$prop -and $p.$prop -isnot [array]) {
                $errs += "$tag.$prop must be an array (got $($p.$prop.GetType().Name))"
            }
        }

        $targets = @($p.Targets)
        if ($targets.Count -eq 0) {
            $errs += "$tag.Targets must be a non-empty array"
            continue
        }

        for ($j = 0; $j -lt $targets.Count; $j++) {
            $t    = $targets[$j]
            $ttag = "$tag.Targets[$j]"

            if ([string]::IsNullOrWhiteSpace($t.Path))       { $errs += "$ttag.Path is required" }
            if ([string]::IsNullOrWhiteSpace($t.DeletedDir)) { $errs += "$ttag.DeletedDir is required" }
            if ($null -ne $t.Optional -and $t.Optional -isnot [bool]) {
                $errs += "$ttag.Optional must be a boolean (got $($t.Optional.GetType().Name))"
            }

            if ($t.Path) {
                $key = $t.Path.TrimEnd('\')
                if (-not $seenTargets.Add($key)) {
                    $errs += "$ttag.Path duplicates another target: '$($t.Path)'"
                }
                # Source under target (or vice versa) would cause robocopy to chew its own input.
                if ($p.Source) {
                    $src = $p.Source.TrimEnd('\')
                    if ($key -ieq $src -or
                        $key.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase) -or
                        $src.StartsWith($key + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        $errs += "$ttag.Path overlaps Source '$($p.Source)'"
                    }
                }
            }
            if ($t.DeletedDir) {
                $dkey = $t.DeletedDir.TrimEnd('\')
                if (-not $seenDeletedDirs.Add($dkey)) {
                    $errs += "$ttag.DeletedDir duplicates another DeletedDir: '$($t.DeletedDir)'"
                }
            }
        }
    }

    if ($errs.Count -gt 0) {
        Write-Log 'Configuration invalid:' 'ERROR'
        foreach ($e in $errs) { Write-Log "  - $e" 'ERROR' }
        return $false
    }
    return $true
}

function Test-TargetReachable {
    # Returns $true if the path's drive/share root is currently mounted/reachable.
    # Used to gate Optional targets (e.g. external USB drive) before any I/O - a
    # missing drive root would otherwise blow up at New-Item with a noisy error.
    # GetPathRoot returns 'F:\' for 'F:\foo\bar' and '\\srv\share' for UNC paths.
    param([Parameter(Mandatory)][string]$Path)

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    return Test-Path -LiteralPath $root
}

function Test-RanToday {
    if (-not (Test-Path $FlagFile)) { return $false }
    $last = (Get-Content $FlagFile -Raw -ErrorAction SilentlyContinue).Trim()
    return $last -eq (Get-Date -Format 'yyyy-MM-dd')
}

function Set-RanToday {
    Set-Content -Path $FlagFile -Value (Get-Date -Format 'yyyy-MM-dd') -Force
}

function Test-RelPathExcluded {
    param(
        [string]$RelPath,
        [string[]]$ExcludeDirs,
        [string[]]$ExcludeFiles
    )

    $segments = $RelPath -split '\\'
    $fileName = $segments[-1]
    $dirSegs  = if ($segments.Count -gt 1) { $segments[0..($segments.Count - 2)] } else { @() }

    foreach ($d in $ExcludeDirs)  { if ($dirSegs -contains $d) { return $true } }
    foreach ($f in $ExcludeFiles) { if ($fileName -like $f)    { return $true } }
    return $false
}

# Returns relative paths of files that exist in Target but NOT in Source.
# Excluded paths are skipped on both sides so we don't deletion-track files robocopy is also ignoring.
function Get-DeletedRelPaths {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExcludeDirs  = @(),
        [string[]]$ExcludeFiles = @()
    )

    if (-not (Test-Path $Target)) { return @() }
    if (-not (Test-Path $Source)) {
        Write-Log "Source not found: $Source" 'WARN'
        return @()
    }

    $srcRoot = $Source.TrimEnd('\')
    $tgtRoot = $Target.TrimEnd('\')

    $srcSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = $_.FullName.Substring($srcRoot.Length + 1)
            if (-not (Test-RelPathExcluded $rel $ExcludeDirs $ExcludeFiles)) {
                [void]$srcSet.Add($rel)
            }
        }

    Get-ChildItem -LiteralPath $tgtRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = $_.FullName.Substring($tgtRoot.Length + 1)
            if (Test-RelPathExcluded $rel $ExcludeDirs $ExcludeFiles) { return }
            if (-not $srcSet.Contains($rel)) { $rel }
        }
}

function Move-DeletedToTracker {
    param(
        [string]$Target,
        [string]$DeletedDir,
        [string[]]$RelPaths
    )

    if (-not $RelPaths -or $RelPaths.Count -eq 0) {
        Write-Log "No source-side deletions detected for $Target"
        return
    }

    $todayDir = Join-Path $DeletedDir (Get-Date -Format 'yyyy-MM-dd')
    $moved = 0; $failed = 0

    foreach ($rel in $RelPaths) {
        $src = Join-Path $Target $rel
        $dst = Join-Path $todayDir $rel
        $dstParent = Split-Path $dst -Parent

        try {
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
            }
            Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            $moved++
        } catch {
            Write-Log "Move failed '$src' -> '$dst': $($_.Exception.Message)" 'ERROR'
            $failed++
        }
    }

    Write-Log "Tracker: moved $moved file(s), $failed failure(s) into $todayDir"
}

function Invoke-RobocopyMirror {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExcludeDirs  = @(),
        [string[]]$ExcludeFiles = @()
    )

    $rcArgs = @($Source, $Target) + $RobocopyArgs + @("/LOG+:$LogFile")
    if ($ExcludeDirs.Count  -gt 0) { $rcArgs += @('/XD') + $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += @('/XF') + $ExcludeFiles }

    Write-Log "robocopy /MIR: $Source -> $Target"

    # Pipe to Out-Host so robocopy's stdout doesn't get captured into the function's
    # return value - otherwise the caller sees an array of strings + int, not a clean rc.
    & robocopy @rcArgs | Out-Host
    $code = $LASTEXITCODE

    # Robocopy exit code is a bitmask. Tiers:
    #   0-7  : success (any combination of "files copied / extras / mismatches")
    #   8-15 : warning - some files failed (locked, in-use, etc.) but no fatal error
    #   16+  : failure - fatal, source unreachable, out of disk, etc.
    if ($code -ge 16) {
        Write-Log "robocopy FAILED (exit $code) for $Source" 'ERROR'
    } elseif ($code -ge 8) {
        Write-Log "robocopy WARNING (exit $code, some files failed) for $Source" 'WARN'
    } else {
        Write-Log "robocopy OK (exit $code) for $Source"
    }
    return $code
}

function Remove-OldRunRecords {
    # Drops rows from runs.md whose Date column is older than $RetentionDays.
    # Header is preserved; rows that fail to parse (manual edits, blank lines, etc.) are kept.
    param([string]$LogDir, [int]$RetentionDays)

    $runsFile = Join-Path $LogDir 'runs.md'
    if (-not (Test-Path -LiteralPath $runsFile)) { return }

    $utf8 = [System.Text.UTF8Encoding]::new($false)

    try {
        $lines = [System.IO.File]::ReadAllLines($runsFile, $utf8)
    } catch {
        Write-Log "Could not read runs.md for pruning: $($_.Exception.Message)" 'WARN'
        return
    }

    if ($lines.Count -le 2) { return }   # header only, nothing to prune

    $header     = $lines[0..1]
    $dataLines  = $lines[2..($lines.Count - 1)]
    $cutoff     = (Get-Date).Date.AddDays(-$RetentionDays)
    $kept       = New-Object System.Collections.Generic.List[string]
    $pruned     = 0

    foreach ($line in $dataLines) {
        $drop = $false

        if (-not [string]::IsNullOrWhiteSpace($line)) {
            # Row format: | Script | Status | Date | Time | RC | Log | Message |
            # Splitting on | gives an empty leading element + the columns + an empty trailing element.
            $cols = $line -split '\|' | ForEach-Object { $_.Trim() }
            if ($cols.Count -ge 4) {
                $rowDate = [datetime]::MinValue
                $parsed  = [datetime]::TryParseExact(
                    $cols[3], 'yyyy-MM-dd', $null,
                    [System.Globalization.DateTimeStyles]::None, [ref]$rowDate)
                if ($parsed -and $rowDate -lt $cutoff) { $drop = $true }
            }
        }

        if ($drop) { $pruned++ } else { $kept.Add($line) }
    }

    if ($pruned -eq 0) { return }

    $nl      = "`r`n"
    $content = (($header + $kept.ToArray()) -join $nl) + $nl
    [System.IO.File]::WriteAllText($runsFile, $content, $utf8)

    Write-Log "Pruned $pruned old run record(s) from runs.md"
}

function Remove-OldRunLogs {
    param([string]$LogDir, [int]$RetentionDays)

    if (-not (Test-Path -LiteralPath $LogDir)) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)

    Get-ChildItem -LiteralPath $LogDir -File -Filter 'backup-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-Log "Pruned old log: $($_.Name)"
            } catch {
                Write-Log "Prune failed for log $($_.Name): $($_.Exception.Message)" 'WARN'
            }
        }
}

function Remove-OldDeletionTrackers {
    param([string]$DeletedDir, [int]$RetentionDays)

    if (-not (Test-Path $DeletedDir)) { return }

    # With RetentionDays=3 and today=2026-04-28, cutoff=2026-04-25.
    # Delete folders dated <= cutoff -> keeps today, today-1, today-2 (3 folders).
    $cutoff = (Get-Date).Date.AddDays(-$RetentionDays)

    Get-ChildItem -LiteralPath $DeletedDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $d = [datetime]::MinValue
            $ok = [datetime]::TryParseExact(
                $_.Name, 'yyyy-MM-dd', $null,
                [System.Globalization.DateTimeStyles]::None, [ref]$d)
            if ($ok -and $d -le $cutoff) {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    Write-Log "Pruned old tracker: $($_.FullName)"
                } catch {
                    Write-Log "Prune failed $($_.FullName): $($_.Exception.Message)" 'ERROR'
                }
            }
        }
}

# =============================== MAIN ===============================

foreach ($d in @($LogDir, (Split-Path -Parent $FlagFile))) {
    if ($d -and -not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

if (-not (Test-Configuration)) {
    Send-Toast -Title 'Backup config invalid' -Message 'See backup.log for details'
    exit 2
}

if ($UseDailyFlag -and (Test-RanToday) -and -not $Force) {
    Write-Log "Already ran today. Skipping (use -Force to override)."
    exit 0
}

Write-Log "===== Backup run starting ====="
$targetCount       = ($BackupPairs | ForEach-Object { @($_.Targets).Count } | Measure-Object -Sum).Sum
$ResolvedLogOpener = Resolve-LogOpener $LogOpener
$logUri            = Get-OpenerActionUri -TargetFile $LogFile `
                        -WrapperName 'open-log.vbs' -LogDirectory $LogDir -OpenerExe $ResolvedLogOpener
$runsUri           = Get-OpenerActionUri -TargetFile (Join-Path $LogDir 'runs.md') `
                        -WrapperName 'open-runs.vbs' -LogDirectory $LogDir -OpenerExe $ResolvedLogOpener

Send-Toast `
    -Title   'Backup starting' `
    -Message "$($BackupPairs.Count) source(s) -> $targetCount target(s)" `
    -Actions @(@{ Content = 'View log'; Url = $logUri })

$okCount      = 0
$warnCount    = 0
$failCount    = 0
$skipCount    = 0
$skippedPaths = New-Object System.Collections.Generic.List[string]

foreach ($pair in $BackupPairs) {
    Write-Log "=== Source: $($pair.Source) ==="

    if (-not (Test-Path $pair.Source)) {
        Write-Log "Source missing, skipping: $($pair.Source)" 'ERROR'
        # Every target in this pair didn't get backed up -> count each as a failure.
        $failCount += @($pair.Targets).Count
        continue
    }

    foreach ($target in $pair.Targets) {
        Write-Log "--- Target: $($target.Path) ---"

        # Optional targets (typically external/USB drives or flaky shares) are
        # skipped silently when their drive root isn't mounted - the run still
        # records the skip in runs.md so it's visible. Required targets fall
        # through and let New-Item / robocopy fail loudly as before.
        if ($target.Optional -and -not (Test-TargetReachable $target.Path)) {
            Write-Log "Optional target unreachable, skipping: $($target.Path)" 'WARN'
            $skippedPaths.Add($target.Path)
            $skipCount++
            continue
        }

        foreach ($d in @($target.Path, $target.DeletedDir)) {
            if (-not (Test-Path $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
        }

        # 1. Detect source-side deletions and move them out of target into the tracker.
        $deleted = @(Get-DeletedRelPaths `
            -Source       $pair.Source `
            -Target       $target.Path `
            -ExcludeDirs  $pair.ExcludeDirs `
            -ExcludeFiles $pair.ExcludeFiles)
        Write-Log "Detected $($deleted.Count) file(s) deleted from source"
        if ($deleted.Count -gt 0) {
            Move-DeletedToTracker -Target $target.Path -DeletedDir $target.DeletedDir -RelPaths $deleted
        }

        # 2. Mirror source -> target. Tier the rc: 0-7 ok, 8-15 warning, 16+ fail.
        $rc = Invoke-RobocopyMirror `
            -Source       $pair.Source `
            -Target       $target.Path `
            -ExcludeDirs  $pair.ExcludeDirs `
            -ExcludeFiles $pair.ExcludeFiles
        if     ($rc -ge 16) { $failCount++ }
        elseif ($rc -ge 8)  { $warnCount++ }
        else                { $okCount++ }

        # 3. Prune old deletion-tracker folders.
        Remove-OldDeletionTrackers -DeletedDir $target.DeletedDir -RetentionDays $RetentionDays
    }
}

Remove-OldRunLogs    -LogDir $LogDir -RetentionDays $LogRetentionDays
Remove-OldRunRecords -LogDir $LogDir -RetentionDays $LogRetentionDays

# Final tier from the per-target tally:
#   any FAIL                        -> FAIL  (toast says 'Backup FAILED')
#   any WARN                        -> WARN  (toast 'Backup OK with warnings'; flag still set)
#   only skips (no targets ran)     -> WARN  (nothing was actually backed up)
#   else                            -> OK    (skips alongside successful targets are fine)
$tier = if     ($failCount -gt 0)                          { 'FAIL' }
        elseif ($warnCount -gt 0)                          { 'WARN' }
        elseif ($okCount -eq 0 -and $skipCount -gt 0)      { 'WARN' }
        else                                               { 'OK' }

$summary = "OK: $okCount  Warn: $warnCount  Fail: $failCount"
if ($skipCount -gt 0) {
    $summary += "  Skip: $skipCount ($($skippedPaths -join ', ') unreachable)"
}

switch ($tier) {
    'OK' {
        if ($UseDailyFlag) { Set-RanToday }
        Write-Log "===== Backup run completed OK ====="
        Send-Toast `
            -Title   'Backup OK' `
            -Message $summary `
            -Actions @(@{ Content = 'View runs'; Url = $runsUri })
        Add-RunRecord -Tier 'OK' -ExitCode 0 -Message $summary
        exit 0
    }
    'WARN' {
        if ($UseDailyFlag) { Set-RanToday }
        Write-Log "===== Backup run completed with WARNINGS =====" 'WARN'
        Send-Toast `
            -Title   'Backup OK with warnings' `
            -Message $summary `
            -Actions @(@{ Content = 'View runs'; Url = $runsUri })
        $warnTier = if ($okCount -gt 0) { 'OKWARN' } else { 'WARN' }
        Add-RunRecord -Tier $warnTier -ExitCode 0 -Message $summary
        exit 0
    }
    'FAIL' {
        Write-Log "===== Backup run completed WITH ERRORS =====" 'ERROR'
        Send-Toast `
            -Title   'Backup FAILED' `
            -Message $summary `
            -Actions @(@{ Content = 'View runs'; Url = $runsUri })
        Add-RunRecord -Tier 'FAIL' -ExitCode 1 -Message $summary
        exit 1
    }
}