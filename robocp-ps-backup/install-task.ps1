<#
.SYNOPSIS
    Registers (or unregisters) backup.ps1 with Windows Task Scheduler.

.DESCRIPTION
    Schedules backup.ps1 to fire at multiple times a day, running as the current
    user with an interactive logon (so toast notifications work). Missed triggers
    (PC asleep) catch up via -StartWhenAvailable. Concurrent runs are suppressed.

    The task invokes run-hidden.vbs (via wscript.exe), which launches powershell
    with no console window. Calling powershell.exe directly with -WindowStyle
    Hidden still flashes a black window for a fraction of a second; the .vbs
    wrapper avoids that entirely.

    With UseDailyFlag = $true (default in backup.config.psd1), only the first
    successful run each day actually mirrors; later triggers exit early. Set
    UseDailyFlag = $false in config to have every scheduled fire mirror the
    latest state.

.PARAMETER TaskName
    Name of the scheduled task. Default: 'Backup-Mirror'.

.PARAMETER Times
    HH:mm times (24h) to fire. Default: 02:00, 14:00, 22:00.

.PARAMETER Uninstall
    Remove the task instead of installing it.

.EXAMPLE
    .\install-task.ps1
    .\install-task.ps1 -Times '07:00','13:00','19:00'
    .\install-task.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]   $TaskName = 'Backup-Mirror',
    [string[]] $Times    = @("02:00", '14:00', '21:00'),
    [switch]   $Uninstall
)

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Unregistered scheduled task '$TaskName'."
    } else {
        Write-Host "No task named '$TaskName' to remove."
    }
    return
}

$launcherPath = Join-Path $PSScriptRoot 'run-hidden.vbs'
if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "run-hidden.vbs not found next to install-task.ps1 (expected: $launcherPath)"
}

$action = New-ScheduledTaskAction `
    -Execute          'wscript.exe' `
    -Argument         "`"$launcherPath`"" `
    -WorkingDirectory $PSScriptRoot

# One Daily trigger per time. Each fires once a day at the specified clock time.
$triggers = foreach ($t in $Times) { New-ScheduledTaskTrigger -Daily -At $t }

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $triggers `
    -Settings    $settings `
    -Description 'Mirror configured source dirs to their backup targets via backup.ps1.' `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName'."
Write-Host "Triggers: $($Times -join ', ')"
Write-Host "Launcher: $launcherPath"
