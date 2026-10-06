[CmdletBinding()]
param(
    [ValidateSet('Static', 'Smoke')]
    [string]$Mode = 'Static'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$monitorPath = Join-Path $projectRoot 'Monitor.ps1'
$dataPath = Join-Path $projectRoot 'data'
$profileRoot = Join-Path $dataPath 'auto-profiles'
$reportPath = Join-Path $dataPath ('validation-{0}.txt' -f $Mode.ToLowerInvariant())
$outputPath = Join-Path $dataPath ('validation-{0}-output.txt' -f $Mode.ToLowerInvariant())
$errorPath = Join-Path $dataPath ('validation-{0}-error.txt' -f $Mode.ToLowerInvariant())
$lines = New-Object System.Collections.Generic.List[string]
$validationExitCode = 0

if (-not (Test-Path -LiteralPath $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}

function Get-TestChromeProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.CommandLine).IndexOf($profileRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Get-ProjectMonitorProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessId -ne $PID) -and
        (([string]$_.CommandLine).IndexOf($monitorPath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}

function Get-PolicyText {
    $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome'
    if (-not (Test-Path -LiteralPath $path)) { return '<key missing>' }
    $key = Get-Item -LiteralPath $path
    if (-not (@($key.GetValueNames()) -contains 'DeveloperToolsAvailability')) { return '<not set>' }
    return '{0} ({1})' -f $key.GetValue('DeveloperToolsAvailability'), $key.GetValueKind('DeveloperToolsAvailability')
}

function Stop-TestChrome {
    $processes = @(Get-TestChromeProcesses)
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $profileRoot) {
        Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $processes.Count
}

$lines.Add('StartedLocal=' + [DateTime]::Now.ToString('o'))
$lines.Add('Mode=' + $Mode)
$registryBefore = Get-PolicyText
$lines.Add('RegistryBefore=' + $registryBefore)

$preexistingMonitor = @(Get-ProjectMonitorProcesses)
$preexistingChrome = @(Get-TestChromeProcesses)
$preexistingProfiles = @((Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue)).Count
$lines.Add('PreexistingMonitorProcesses=' + $preexistingMonitor.Count)
$lines.Add('PreexistingTestChrome=' + $preexistingChrome.Count)
$lines.Add('PreexistingProfiles=' + $preexistingProfiles)
if (($preexistingMonitor.Count -gt 0) -or ($preexistingChrome.Count -gt 0) -or ($preexistingProfiles -gt 0)) {
    $lines.Add('PrecheckError=另一個測量或未清理的隔離 Chrome/Profile 仍存在。請先完成該測量或執行 Recover.cmd；驗證不會自動中斷其他工作。')
    $lines.Add('ValidationExitCode=2')
    $lines.Add('FinishedLocal=' + [DateTime]::Now.ToString('o'))
    $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
    exit 2
}

if ($Mode -eq 'Static') {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($monitorPath, [ref]$tokens, [ref]$errors)
    $lines.Add('ParserErrorCount=' + $errors.Count)
    foreach ($error in $errors) { $lines.Add('ParserError=' + $error.Message) }
    if ($errors.Count -gt 0) { $validationExitCode = 1 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitorPath -SelfTest *> $outputPath
    $selfTestExitCode = $LASTEXITCODE
    $lines.Add('SelfTestExitCode=' + $selfTestExitCode)
    if ($selfTestExitCode -ne 0) { $validationExitCode = 1 }
}
else {
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -AutomationSmokeTest' -f $monitorPath) `
        -RedirectStandardOutput $outputPath `
        -RedirectStandardError $errorPath `
        -PassThru
    $finished = $process.WaitForExit(45000)
    if (-not $finished) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if ($finished) {
        $process.WaitForExit()
        $process.Refresh()
    }
    $lines.Add('FinishedWithin45Seconds=' + $finished)
    $smokeExitCode = $(if ($finished) { [int]$process.ExitCode } else { -999 })
    $lines.Add('ExitCode=' + $smokeExitCode)
    if ((-not $finished) -or ($smokeExitCode -ne 0)) { $validationExitCode = 1 }
    $lines.Add('TestChromeStopped=' + (Stop-TestChrome))
}

$remaining = @(Get-TestChromeProcesses)
$lines.Add('RemainingTestChrome=' + $remaining.Count)
$remainingProfiles = @((Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue)).Count
$lines.Add('RemainingProfiles=' + $remainingProfiles)
$registryAfter = Get-PolicyText
$lines.Add('RegistryAfter=' + $registryAfter)
if ($remaining.Count -ne 0) { $validationExitCode = 1 }
if ($remainingProfiles -ne 0) { $validationExitCode = 1 }
if ($registryAfter -ne $registryBefore) { $validationExitCode = 1 }
$lines.Add('ValidationExitCode=' + $validationExitCode)
$lines.Add('FinishedLocal=' + [DateTime]::Now.ToString('o'))
$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
exit $validationExitCode
