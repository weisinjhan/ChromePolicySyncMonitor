[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$DirectStart,
    [switch]$Auto,
    [switch]$AutomationSmokeTest,
    [switch]$RecoverOnly,
    [ValidateRange(1, 1000)]
    [int]$Iterations = 10,
    [ValidateRange(5, 7200)]
    [int]$TimeoutSeconds = 1800
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = $PSScriptRoot
$script:DataDirectory = Join-Path $PSScriptRoot 'data'
$script:ResultsPath = Join-Path $script:DataDirectory 'results.csv'
$script:LogPath = Join-Path $script:DataDirectory 'monitor.log'
$script:RegistryPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome'
$script:RegistryValueName = 'DeveloperToolsAvailability'
$script:DefaultTimeoutSeconds = $TimeoutSeconds
$script:AutoProbeIntervalMilliseconds = 500
$script:AutoRequiredConsecutiveFailures = 3
$script:AutoChromeStartupTimeoutSeconds = 30
$script:AutoProfileRoot = Join-Path $script:DataDirectory 'auto-profiles'
$script:CdpProbeSourcePath = Join-Path $script:ProjectRoot 'CdpProbeHelper.cs'
$script:CdpProbeHelperPath = Join-Path $script:ProjectRoot 'CdpProbeHelper.exe'
$script:SessionId = [Guid]::NewGuid().ToString('N')

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    if (-not (Test-Path -LiteralPath $script:DataDirectory)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }

    $line = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedCopy {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DirectStart) {
        $arguments += ' -DirectStart'
    }
    if ($Auto) {
        $arguments += ' -Auto -Iterations {0} -TimeoutSeconds {1}' -f $Iterations, $TimeoutSeconds
    }
    if ($RecoverOnly) {
        $arguments += ' -RecoverOnly'
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList $arguments | Out-Null
        return $true
    }
    catch {
        Write-Host ''
        Write-Host '無法取得系統管理員權限。未修改任何機碼。' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        return $false
    }
}

function Get-ChromeInfo {
    $paths = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
            return [PSCustomObject]@{
                Path = $item.FullName
                Version = $item.VersionInfo.ProductVersion
            }
        }
    }

    return [PSCustomObject]@{
        Path = ''
        Version = 'NotFound'
    }
}

function Start-AutomationChrome {
    param(
        [Parameter(Mandatory = $true)]$ChromeInfo,
        [Parameter(Mandatory = $true)][int]$TestNumber
    )

    if ([string]::IsNullOrWhiteSpace([string]$ChromeInfo.Path) -or -not (Test-Path -LiteralPath $ChromeInfo.Path)) {
        throw '找不到 Google Chrome 執行檔，無法啟動自動測試。'
    }

    if (-not (Test-Path -LiteralPath $script:AutoProfileRoot)) {
        New-Item -ItemType Directory -Path $script:AutoProfileRoot -Force | Out-Null
    }

    $profilePath = Join-Path $script:AutoProfileRoot ('test-{0}-{1}-{2}' -f $TestNumber, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $profilePath -Force | Out-Null

    $arguments = @(
        ('--user-data-dir="{0}"' -f $profilePath),
        '--remote-debugging-port=0',
        '--remote-allow-origins=*',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-sync',
        '--disable-extensions',
        '--disable-popup-blocking',
        '--window-size=900,700',
        'about:blank'
    )

    $launcherProcess = Start-Process -FilePath $ChromeInfo.Path -ArgumentList $arguments -PassThru
    $activePortPath = Join-Path $profilePath 'DevToolsActivePort'
    $deadline = [DateTime]::UtcNow.AddSeconds($script:AutoChromeStartupTimeoutSeconds)
    $port = 0

    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $browserProcess = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $commandLine = [string]$_.CommandLine
                ($commandLine.IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                ($commandLine.IndexOf('--type=', [StringComparison]::OrdinalIgnoreCase) -lt 0)
            } | Select-Object -First 1)

            if ((Test-Path -LiteralPath $activePortPath) -and ($browserProcess.Count -gt 0)) {
                try {
                    $lines = @(Get-Content -LiteralPath $activePortPath -ErrorAction Stop)
                    if (($lines.Count -gt 0) -and [int]::TryParse([string]$lines[0], [ref]$port) -and ($port -gt 0)) {
                        $browserProcessId = [int]$browserProcess[0].ProcessId
                        Write-Log ('自動測試 Chrome 已啟動；PID={0}；Port={1}；Profile={2}' -f $browserProcessId, $port, $profilePath)
                        return [PSCustomObject]@{
                            ProcessId = $browserProcessId
                            Port = $port
                            ProfilePath = $profilePath
                        }
                    }
                }
                catch {
                    # Chrome 可能仍在寫入 DevToolsActivePort，稍後再讀取。
                }
            }

            Start-Sleep -Milliseconds 100
        }

        $launcherExit = '<仍在執行>'
        try {
            $launcherProcess.Refresh()
            if ($launcherProcess.HasExited) { $launcherExit = [string]$launcherProcess.ExitCode }
        }
        catch { }
        throw ('等待 Chrome 遠端偵錯端點逾時（{0} 秒）；launcher ExitCode={1}。' -f $script:AutoChromeStartupTimeoutSeconds, $launcherExit)
    }
    catch {
        $startupError = $_.Exception.Message
        $startupProcesses = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.CommandLine).IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($startupProcess in $startupProcesses) {
            Stop-Process -Id $startupProcess.ProcessId -Force -ErrorAction SilentlyContinue
        }
        try { Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue
        throw $startupError
    }
}

function Test-AutomationChromeRunning {
    param([Parameter(Mandatory = $true)]$ChromeSession)

    try {
        $profilePath = [string]$ChromeSession.ProfilePath
        $processId = [int]$ChromeSession.ProcessId
        $browserProcess = @(Get-CimInstance Win32_Process -Filter ("Name='chrome.exe' AND ProcessId={0}" -f $processId) -ErrorAction SilentlyContinue | Where-Object {
            $commandLine = [string]$_.CommandLine
            ($commandLine.IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
            ($commandLine.IndexOf('--type=', [StringComparison]::OrdinalIgnoreCase) -lt 0)
        })
        return $browserProcess.Count -gt 0
    }
    catch {
        return $false
    }
}

function Stop-AutomationChrome {
    param([Parameter(Mandatory = $true)]$ChromeSession)

    $profilePath = [string]$ChromeSession.ProfilePath
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.CommandLine).IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })

        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log ('清理自動測試 Chrome 程序時發生問題：{0}' -f $_.Exception.Message) 'WARN'
    }

    try {
        if (Test-Path -LiteralPath $profilePath) {
            Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Log ('無法刪除自動測試 Profile：{0}；{1}' -f $profilePath, $_.Exception.Message) 'WARN'
    }
}

function Stop-AllAutomationChrome {
    $stoppedCount = 0
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.CommandLine).IndexOf($script:AutoProfileRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            $stoppedCount++
        }
    }
    catch {
        Write-Log ('清理所有自動測試 Chrome 時發生問題：{0}' -f $_.Exception.Message) 'WARN'
    }

    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $script:AutoProfileRoot) {
        Get-ChildItem -LiteralPath $script:AutoProfileRoot -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $stoppedCount
}

function Initialize-CdpProbeType {
    if ($null -ne ('ChromePolicySyncMonitor.CdpProbe' -as [type])) {
        return
    }

    $source = @'
using System;
using System.IO;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace ChromePolicySyncMonitor
{
    public sealed class CdpProbeResult
    {
        public bool Success { get; set; }
        public string Error { get; set; }
        public string Response { get; set; }
    }

    public static class CdpProbe
    {
        public static CdpProbeResult Execute(string webSocketUrl, int timeoutMilliseconds)
        {
            TcpClient client = null;
            try
            {
                var uri = new Uri(webSocketUrl);
                client = new TcpClient();
                IAsyncResult connect = client.BeginConnect(uri.Host, uri.Port, null, null);
                if (!connect.AsyncWaitHandle.WaitOne(timeoutMilliseconds))
                {
                    throw new TimeoutException("CDP TCP connection timed out.");
                }
                client.EndConnect(connect);

                using (NetworkStream stream = client.GetStream())
                {
                    stream.ReadTimeout = timeoutMilliseconds;
                    stream.WriteTimeout = timeoutMilliseconds;

                    string key = Convert.ToBase64String(RandomBytes(16));
                    string request =
                        "GET " + uri.PathAndQuery + " HTTP/1.1\r\n" +
                        "Host: " + uri.Host + ":" + uri.Port + "\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Sec-WebSocket-Key: " + key + "\r\n" +
                        "Sec-WebSocket-Version: 13\r\n" +
                        "Origin: http://127.0.0.1:" + uri.Port + "\r\n\r\n";

                    byte[] requestBytes = Encoding.ASCII.GetBytes(request);
                    stream.Write(requestBytes, 0, requestBytes.Length);
                    stream.Flush();

                    string headers = ReadHttpHeaders(stream);
                    if (headers.IndexOf(" 101 ", StringComparison.Ordinal) < 0 &&
                        !headers.StartsWith("HTTP/1.1 101", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException("CDP WebSocket handshake was rejected: " + FirstLine(headers));
                    }

                    const string command = "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}";
                    SendTextFrame(stream, command);

                    var response = new StringBuilder();
                    while (true)
                    {
                        WebSocketFrame frame = ReadFrame(stream);
                        if (frame.Opcode == 8)
                        {
                            throw new InvalidOperationException("Chrome closed the CDP WebSocket.");
                        }
                        if (frame.Opcode == 9)
                        {
                            SendControlFrame(stream, 10, frame.Payload);
                            continue;
                        }
                        if (frame.Opcode != 1 && frame.Opcode != 0)
                        {
                            continue;
                        }

                        response.Append(Encoding.UTF8.GetString(frame.Payload));
                        if (!frame.Fin)
                        {
                            continue;
                        }

                        string text = response.ToString();
                        if (text.IndexOf("\"id\":1", StringComparison.Ordinal) >= 0)
                        {
                            bool validValue = text.IndexOf("\"value\":2", StringComparison.Ordinal) >= 0;
                            return new CdpProbeResult
                            {
                                Success = validValue,
                                Error = validValue ? string.Empty : "CDP response did not contain the expected value.",
                                Response = text
                            };
                        }
                        response.Clear();
                    }
                }
            }
            catch (Exception ex)
            {
                return new CdpProbeResult { Success = false, Error = ex.GetBaseException().Message, Response = string.Empty };
            }
            finally
            {
                if (client != null) { try { client.Close(); } catch { } }
            }
        }

        private sealed class WebSocketFrame
        {
            public bool Fin;
            public int Opcode;
            public byte[] Payload;
        }

        private static byte[] RandomBytes(int count)
        {
            byte[] bytes = new byte[count];
            using (var random = RandomNumberGenerator.Create()) { random.GetBytes(bytes); }
            return bytes;
        }

        private static string FirstLine(string text)
        {
            int end = text.IndexOf("\r\n", StringComparison.Ordinal);
            return end >= 0 ? text.Substring(0, end) : text;
        }

        private static string ReadHttpHeaders(Stream stream)
        {
            var bytes = new MemoryStream();
            int matched = 0;
            byte[] terminator = new byte[] { 13, 10, 13, 10 };
            while (bytes.Length < 65536)
            {
                int value = stream.ReadByte();
                if (value < 0) { throw new EndOfStreamException("CDP handshake ended early."); }
                bytes.WriteByte((byte)value);
                matched = value == terminator[matched] ? matched + 1 : (value == terminator[0] ? 1 : 0);
                if (matched == terminator.Length) { return Encoding.ASCII.GetString(bytes.ToArray()); }
            }
            throw new InvalidDataException("CDP handshake headers were too large.");
        }

        private static void SendTextFrame(Stream stream, string text)
        {
            SendControlFrame(stream, 1, Encoding.UTF8.GetBytes(text));
        }

        private static void SendControlFrame(Stream stream, int opcode, byte[] payload)
        {
            if (payload.Length >= 126) { throw new InvalidOperationException("CDP probe payload is unexpectedly large."); }
            byte[] mask = RandomBytes(4);
            byte[] frame = new byte[2 + 4 + payload.Length];
            frame[0] = (byte)(0x80 | (opcode & 0x0F));
            frame[1] = (byte)(0x80 | payload.Length);
            Buffer.BlockCopy(mask, 0, frame, 2, 4);
            for (int i = 0; i < payload.Length; i++) { frame[6 + i] = (byte)(payload[i] ^ mask[i % 4]); }
            stream.Write(frame, 0, frame.Length);
            stream.Flush();
        }

        private static WebSocketFrame ReadFrame(Stream stream)
        {
            int first = ReadByte(stream);
            int second = ReadByte(stream);
            bool fin = (first & 0x80) != 0;
            int opcode = first & 0x0F;
            bool masked = (second & 0x80) != 0;
            ulong length = (ulong)(second & 0x7F);
            if (length == 126)
            {
                length = (ulong)((ReadByte(stream) << 8) | ReadByte(stream));
            }
            else if (length == 127)
            {
                length = 0;
                for (int i = 0; i < 8; i++) { length = (length << 8) | (byte)ReadByte(stream); }
            }
            if (length > 1048576) { throw new InvalidDataException("CDP WebSocket frame is too large."); }

            byte[] mask = masked ? ReadExact(stream, 4) : null;
            byte[] payload = ReadExact(stream, (int)length);
            if (masked)
            {
                for (int i = 0; i < payload.Length; i++) { payload[i] = (byte)(payload[i] ^ mask[i % 4]); }
            }
            return new WebSocketFrame { Fin = fin, Opcode = opcode, Payload = payload };
        }

        private static int ReadByte(Stream stream)
        {
            int value = stream.ReadByte();
            if (value < 0) { throw new EndOfStreamException("CDP WebSocket ended early."); }
            return value;
        }

        private static byte[] ReadExact(Stream stream, int count)
        {
            byte[] result = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(result, offset, count - offset);
                if (read <= 0) { throw new EndOfStreamException("CDP WebSocket ended early."); }
                offset += read;
            }
            return result;
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Invoke-CdpProbe {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )

    $startedUtc = [DateTime]::UtcNow
    $standardOutputPath = Join-Path $script:DataDirectory ('probe-{0}-out.txt' -f ([Guid]::NewGuid().ToString('N')))
    $standardErrorPath = Join-Path $script:DataDirectory ('probe-{0}-err.txt' -f ([Guid]::NewGuid().ToString('N')))
    try {
        if (-not (Test-Path -LiteralPath $script:CdpProbeSourcePath)) {
            throw ('找不到 CDP helper 原始碼：{0}' -f $script:CdpProbeSourcePath)
        }

        $needsBuild = -not (Test-Path -LiteralPath $script:CdpProbeHelperPath)
        if (-not $needsBuild) {
            $needsBuild = (Get-Item -LiteralPath $script:CdpProbeSourcePath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $script:CdpProbeHelperPath).LastWriteTimeUtc
        }
        if ($needsBuild) {
            Remove-Item -LiteralPath $script:CdpProbeHelperPath -Force -ErrorAction SilentlyContinue
            $source = Get-Content -LiteralPath $script:CdpProbeSourcePath -Raw
            Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $script:CdpProbeHelperPath -OutputType ConsoleApplication
        }

        $process = Start-Process -FilePath $script:CdpProbeHelperPath `
            -ArgumentList @($Port, $TimeoutMilliseconds) `
            -RedirectStandardOutput $standardOutputPath `
            -RedirectStandardError $standardErrorPath `
            -WindowStyle Hidden `
            -PassThru

        $finished = $process.WaitForExit($TimeoutMilliseconds + 2000)
        if (-not $finished) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'CDP helper 超過硬性逾時。'
        }
        $process.Refresh()
        $exitCode = [int]$process.ExitCode

        if ($exitCode -ne 0) {
            $errorText = ''
            if (Test-Path -LiteralPath $standardErrorPath) {
                $rawError = Get-Content -LiteralPath $standardErrorPath -Raw -ErrorAction SilentlyContinue
                if ($null -ne $rawError) {
                    $errorText = ([string]$rawError).Trim()
                }
            }
            if ([string]::IsNullOrWhiteSpace($errorText)) {
                $errorText = 'CDP helper 失敗，ExitCode={0}。' -f $exitCode
            }
            throw $errorText
        }

        return [PSCustomObject]@{
            Success = $true
            StartedUtc = $startedUtc
            CompletedUtc = [DateTime]::UtcNow
            Error = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            StartedUtc = $startedUtc
            CompletedUtc = [DateTime]::UtcNow
            Error = $_.Exception.Message
        }
    }
    finally {
        Remove-Item -LiteralPath $standardOutputPath, $standardErrorPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-CdpReady {
    param(
        [Parameter(Mandatory = $true)]$ChromeSession,
        [int]$TimeoutSeconds = $script:AutoChromeStartupTimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-AutomationChromeRunning -ChromeSession $ChromeSession)) {
            throw '自動測試 Chrome 已結束，無法建立 CDP 基準。'
        }

        $probe = Invoke-CdpProbe -Port $ChromeSession.Port
        if ($probe.Success) {
            return $probe
        }
        $lastError = $probe.Error
        Start-Sleep -Milliseconds 250
    }

    throw ('政策值 1 的 CDP 基準確認逾時。最後錯誤：{0}' -f $lastError)
}

function Test-CdpHttpEndpoint {
    param([Parameter(Mandatory = $true)][int]$Port)

    try {
        $version = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/json/version' -f $Port) -Method Get -TimeoutSec 2
        return ($null -ne $version) -and -not [string]::IsNullOrWhiteSpace([string]$version.Browser)
    }
    catch {
        return $false
    }
}

function Wait-ForAutomaticCdpFailure {
    param(
        [Parameter(Mandatory = $true)]$ChromeSession,
        [Parameter(Mandatory = $true)]$WriteInfo,
        [int]$TimeoutSeconds = $script:DefaultTimeoutSeconds
    )

    $consecutiveFailures = 0
    $lastSuccessUtc = $WriteInfo.WriteCompletedUtc
    $firstFailureUtc = $null
    $confirmationUtc = $null
    $lastError = ''

    Write-Host ''
    Write-Host '已寫入禁止政策 (DWORD 2)，正在自動探測既有 CDP 工作階段...' -ForegroundColor Green
    Write-Host ('探測間隔：{0} ms；連續失敗 {1} 次後記錄候選停用事件。' -f $script:AutoProbeIntervalMilliseconds, $script:AutoRequiredConsecutiveFailures)

    while ($WriteInfo.Timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not (Test-AutomationChromeRunning -ChromeSession $ChromeSession)) {
            $WriteInfo.Timer.Stop()
            return [PSCustomObject]@{
                Status = 'Error'
                LastSuccessUtc = $lastSuccessUtc
                FirstFailureUtc = $firstFailureUtc
                ConfirmedUtc = [DateTime]::UtcNow
                ElapsedSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
                LowerBoundSeconds = [math]::Max(0.0, ($lastSuccessUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                UpperBoundSeconds = $null
                ConfirmationSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
                Notes = '自動測試 Chrome 在政策確認前意外結束。'
            }
        }

        $probe = Invoke-CdpProbe -Port $ChromeSession.Port
        if ($probe.Success) {
            $lastSuccessUtc = $probe.CompletedUtc
            $consecutiveFailures = 0
            $firstFailureUtc = $null
            $lastError = ''
        }
        else {
            if ($consecutiveFailures -eq 0) {
                $firstFailureUtc = $probe.StartedUtc
            }
            $consecutiveFailures++
            $lastError = $probe.Error

            if ($consecutiveFailures -ge $script:AutoRequiredConsecutiveFailures) {
                $confirmationUtc = $probe.CompletedUtc
                $WriteInfo.Timer.Stop()
                $lowerBound = [math]::Max(0.0, ($lastSuccessUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                $upperBound = [math]::Max(0.0, ($firstFailureUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)

                if (-not (Test-AutomationChromeRunning -ChromeSession $ChromeSession)) {
                    return [PSCustomObject]@{
                        Status = 'Error'
                        LastSuccessUtc = $lastSuccessUtc
                        FirstFailureUtc = $firstFailureUtc
                        ConfirmedUtc = $confirmationUtc
                        ElapsedSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
                        LowerBoundSeconds = $lowerBound
                        UpperBoundSeconds = $null
                        ConfirmationSeconds = [math]::Max(0.0, ($confirmationUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                        Notes = 'CDP 連續失敗，但自動測試 Chrome 已結束，不能記為有效的 CDP 停用觀測。'
                    }
                }

                if (-not (Test-CdpHttpEndpoint -Port $ChromeSession.Port)) {
                    return [PSCustomObject]@{
                        Status = 'Error'
                        LastSuccessUtc = $lastSuccessUtc
                        FirstFailureUtc = $firstFailureUtc
                        ConfirmedUtc = $confirmationUtc
                        ElapsedSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
                        LowerBoundSeconds = $lowerBound
                        UpperBoundSeconds = $null
                        ConfirmationSeconds = [math]::Max(0.0, ($confirmationUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                        Notes = 'CDP 連續失敗，且 Chrome 偵錯 HTTP 端點無法連線，判定為一般連線錯誤。'
                    }
                }

                $policyState = Get-PolicyState
                $policyIsBlocked = $policyState.ValueExists -and
                    ([string]$policyState.ValueKind -eq 'DWord') -and
                    ([int]$policyState.Value -eq 2)
                if (-not $policyIsBlocked) {
                    return [PSCustomObject]@{
                        Status = 'Error'
                        LastSuccessUtc = $lastSuccessUtc
                        FirstFailureUtc = $firstFailureUtc
                        ConfirmedUtc = $confirmationUtc
                        ElapsedSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
                        LowerBoundSeconds = $lowerBound
                        UpperBoundSeconds = $null
                        ConfirmationSeconds = [math]::Max(0.0, ($confirmationUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                        Notes = 'CDP 連續失敗，但政策未讀回為 DWORD 2，不能記為有效的 CDP 停用觀測。'
                    }
                }

                return [PSCustomObject]@{
                    Status = 'Success'
                    LastSuccessUtc = $lastSuccessUtc
                    FirstFailureUtc = $firstFailureUtc
                    ConfirmedUtc = $confirmationUtc
                    ElapsedSeconds = $upperBound
                    LowerBoundSeconds = $lowerBound
                    UpperBoundSeconds = $upperBound
                    ConfirmationSeconds = [math]::Max(0.0, ($confirmationUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
                    Notes = ('觀察到候選 CDP 停用事件：Chrome 存活、偵錯 HTTP 端點可用、政策讀回為 DWORD 2，且連續 {0} 次功能探測失敗。此結果不單獨證明 F12 已被封鎖，也不能排除其他 CDP 錯誤。最後錯誤：{1}' -f $consecutiveFailures, $lastError)
                }
            }
        }

        Write-Host ("`r已等待：{0}；連續失敗：{1}/{2}   " -f (Format-Duration $WriteInfo.Timer.Elapsed.TotalSeconds), $consecutiveFailures, $script:AutoRequiredConsecutiveFailures) -NoNewline
        Start-Sleep -Milliseconds $script:AutoProbeIntervalMilliseconds
    }

    $WriteInfo.Timer.Stop()
    Write-Host ''
    return [PSCustomObject]@{
        Status = 'Timeout'
        LastSuccessUtc = $lastSuccessUtc
        FirstFailureUtc = $firstFailureUtc
        ConfirmedUtc = [DateTime]::UtcNow
        ElapsedSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
        LowerBoundSeconds = [math]::Max(0.0, ($lastSuccessUtc - $WriteInfo.WriteCompletedUtc).TotalSeconds)
        UpperBoundSeconds = $null
        ConfirmationSeconds = $WriteInfo.Timer.Elapsed.TotalSeconds
        Notes = ('等待 CDP 探測出現連續失敗逾時；既有工作階段在觀察期間仍可用。最後錯誤：{0}' -f $lastError)
    }
}

function Get-PolicyState {
    $keyExists = Test-Path -LiteralPath $script:RegistryPath
    $valueExists = $false
    $value = $null
    $kind = $null

    if ($keyExists) {
        $key = Get-Item -LiteralPath $script:RegistryPath
        $valueExists = @($key.GetValueNames()) -contains $script:RegistryValueName
        if ($valueExists) {
            $value = $key.GetValue(
                $script:RegistryValueName,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            $kind = $key.GetValueKind($script:RegistryValueName).ToString()
        }
    }

    return [PSCustomObject]@{
        KeyExists = $keyExists
        ValueExists = $valueExists
        ValueKind = $kind
        Value = $value
    }
}

function Save-PolicyBackup {
    $state = Get-PolicyState
    $backupPath = Join-Path $script:DataDirectory ('backup-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:SessionId)
    $backup = [PSCustomObject]@{
        BackupVersion = 1
        SessionId = $script:SessionId
        CapturedUtc = [DateTime]::UtcNow.ToString('o')
        RestoredUtc = $null
        RegistryPath = $script:RegistryPath
        ValueName = $script:RegistryValueName
        KeyExisted = $state.KeyExists
        ValueExisted = $state.ValueExists
        ValueKind = $state.ValueKind
        Value = $state.Value
    }

    $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Log ('已備份政策狀態至 {0}' -f $backupPath)

    return [PSCustomObject]@{
        Path = $backupPath
        Data = $backup
    }
}

function Convert-BackupValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    switch ($Kind) {
        'DWord' { return [int]$Value }
        'QWord' { return [long]$Value }
        'Binary' { return [byte[]]@($Value) }
        'MultiString' { return [string[]]@($Value) }
        default { return $Value }
    }
}

function Restore-PolicyBackup {
    param(
        [Parameter(Mandatory = $true)]$BackupData,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    if ($BackupData.ValueExisted) {
        if (-not (Test-Path -LiteralPath $script:RegistryPath)) {
            New-Item -Path $script:RegistryPath -Force | Out-Null
        }

        Remove-ItemProperty -LiteralPath $script:RegistryPath -Name $script:RegistryValueName -ErrorAction SilentlyContinue
        $restoredValue = Convert-BackupValue -Value $BackupData.Value -Kind ([string]$BackupData.ValueKind)
        New-ItemProperty -LiteralPath $script:RegistryPath -Name $script:RegistryValueName -PropertyType ([string]$BackupData.ValueKind) -Value $restoredValue -Force | Out-Null
    }
    elseif (Test-Path -LiteralPath $script:RegistryPath) {
        Remove-ItemProperty -LiteralPath $script:RegistryPath -Name $script:RegistryValueName -ErrorAction SilentlyContinue

        if (-not $BackupData.KeyExisted) {
            $key = Get-Item -LiteralPath $script:RegistryPath
            $hasValues = @($key.GetValueNames()).Count -gt 0
            $hasSubKeys = @($key.GetSubKeyNames()).Count -gt 0
            if ((-not $hasValues) -and (-not $hasSubKeys)) {
                Remove-Item -LiteralPath $script:RegistryPath -Force
            }
        }
    }

    $BackupData.RestoredUtc = [DateTime]::UtcNow.ToString('o')
    $BackupData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    Write-Log ('已從備份還原政策狀態：{0}' -f $BackupPath)
}

function Get-UnrestoredBackups {
    if (-not (Test-Path -LiteralPath $script:DataDirectory)) {
        return @()
    }

    $items = @(Get-ChildItem -LiteralPath $script:DataDirectory -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $result = @()
    foreach ($item in $items) {
        try {
            $data = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace([string]$data.RestoredUtc)) {
                $result += [PSCustomObject]@{ Path = $item.FullName; Data = $data }
            }
        }
        catch {
            Write-Log ('無法讀取備份檔：{0}；{1}' -f $item.FullName, $_.Exception.Message) 'WARN'
        }
    }
    return $result
}

function Restore-AllUnrestoredBackups {
    $backups = @(Get-UnrestoredBackups)
    foreach ($backup in $backups) {
        Restore-PolicyBackup -BackupData $backup.Data -BackupPath $backup.Path
    }
    return $backups.Count
}

function Invoke-RecoveryOnly {
    if (-not (Test-Path -LiteralPath $script:DataDirectory)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }

    Write-Host '正在執行 Chrome 政策安全復原...' -ForegroundColor Cyan
    $stoppedChrome = Stop-AllAutomationChrome
    $helperProcesses = @(Get-Process -Name 'CdpProbeHelper' -ErrorAction SilentlyContinue)
    foreach ($helperProcess in $helperProcesses) {
        Stop-Process -Id $helperProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $restoredCount = Restore-AllUnrestoredBackups
    $state = Get-PolicyState
    $stateText = '<未設定>'
    if ($state.ValueExists) {
        $stateText = '{0} ({1})' -f $state.Value, $state.ValueKind
    }

    Write-Log ('安全復原完成；還原備份={0}；停止 Chrome={1}；停止 helper={2}；政策={3}' -f $restoredCount, $stoppedChrome, $helperProcesses.Count, $stateText)
    Write-Host ('已還原備份：{0} 個' -f $restoredCount) -ForegroundColor Green
    Write-Host ('已停止隔離 Chrome：{0} 個程序' -f $stoppedChrome) -ForegroundColor Green
    Write-Host ('目前 DeveloperToolsAvailability：{0}' -f $stateText) -ForegroundColor Green
}

function Set-DevToolsPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2)]
        [int]$Value,

        [switch]$StartTimer
    )

    if (-not (Test-Path -LiteralPath $script:RegistryPath)) {
        New-Item -Path $script:RegistryPath -Force | Out-Null
    }

    $writeStartedUtc = [DateTime]::UtcNow
    New-ItemProperty -LiteralPath $script:RegistryPath -Name $script:RegistryValueName -PropertyType DWord -Value $Value -Force | Out-Null
    $writeCompletedUtc = [DateTime]::UtcNow

    $timer = $null
    if ($StartTimer) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
    }

    $key = Get-Item -LiteralPath $script:RegistryPath
    $readBack = [int]$key.GetValue($script:RegistryValueName)
    $kind = $key.GetValueKind($script:RegistryValueName).ToString()
    if (($readBack -ne $Value) -or ($kind -ne 'DWord')) {
        if ($null -ne $timer) { $timer.Stop() }
        throw '機碼寫入後讀回驗證失敗。'
    }

    Write-Log ('已設定 {0}={1} (DWORD)' -f $script:RegistryValueName, $Value)
    return [PSCustomObject]@{
        WriteStartedUtc = $writeStartedUtc
        WriteCompletedUtc = $writeCompletedUtc
        Timer = $timer
    }
}

function Format-Duration {
    param([double]$Seconds)
    $time = [TimeSpan]::FromSeconds($Seconds)
    return '{0:00}:{1:00}:{2:00}.{3:000}' -f [math]::Floor($time.TotalHours), $time.Minutes, $time.Seconds, $time.Milliseconds
}

function Get-Percentile {
    param(
        [Parameter(Mandatory = $true)][double[]]$SortedValues,
        [Parameter(Mandatory = $true)][ValidateRange(0.0, 1.0)][double]$Percentile
    )

    if ($SortedValues.Count -eq 0) { return $null }
    $index = [math]::Ceiling($Percentile * $SortedValues.Count) - 1
    if ($index -lt 0) { $index = 0 }
    return [double]$SortedValues[$index]
}

function Get-ResultStatistics {
    param([object[]]$Records)

    $all = @($Records)
    $successRecords = @($all | Where-Object { $_.Status -eq 'Success' })
    $values = @()
    foreach ($record in $successRecords) {
        $number = 0.0
        if ([double]::TryParse(
            [string]$record.ElapsedSeconds,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )) {
            $values += $number
        }
    }

    $sorted = @($values | Sort-Object)
    $count = $sorted.Count
    $average = $null
    $median = $null
    $minimum = $null
    $maximum = $null
    $standardDeviation = $null
    $p90 = $null
    $p95 = $null

    if ($count -gt 0) {
        $sum = ($sorted | Measure-Object -Sum).Sum
        $average = [double]$sum / $count
        $minimum = [double]$sorted[0]
        $maximum = [double]$sorted[$count - 1]

        if (($count % 2) -eq 1) {
            $median = [double]$sorted[[math]::Floor($count / 2)]
        }
        else {
            $middle = $count / 2
            $median = ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
        }

        if ($count -gt 1) {
            $sumSquared = 0.0
            foreach ($value in $sorted) {
                $sumSquared += [math]::Pow(([double]$value - $average), 2)
            }
            $standardDeviation = [math]::Sqrt($sumSquared / ($count - 1))
        }
        else {
            $standardDeviation = 0.0
        }

        $p90 = Get-Percentile -SortedValues ([double[]]$sorted) -Percentile 0.90
        $p95 = Get-Percentile -SortedValues ([double[]]$sorted) -Percentile 0.95
    }

    return [PSCustomObject]@{
        Total = $all.Count
        Success = $successRecords.Count
        Timeout = @($all | Where-Object { $_.Status -eq 'Timeout' }).Count
        Cancelled = @($all | Where-Object { $_.Status -eq 'Cancelled' }).Count
        Error = @($all | Where-Object { $_.Status -eq 'Error' }).Count
        Average = $average
        Median = $median
        Minimum = $minimum
        Maximum = $maximum
        StandardDeviation = $standardDeviation
        P90 = $p90
        P95 = $p95
    }
}

function Get-AllResults {
    if (-not (Test-Path -LiteralPath $script:ResultsPath)) {
        return @()
    }
    return @(Import-Csv -LiteralPath $script:ResultsPath)
}

function Get-NextTestNumber {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    return @($Records).Count + 1
}

function Show-Statistics {
    param([object[]]$Records = $(Get-AllResults))

    $statistics = Get-ResultStatistics -Records $Records
    Write-Host ''
    Write-Host '================ 累積統計 ================' -ForegroundColor Cyan
    Write-Host ('總測試次數：{0}' -f $statistics.Total)
    Write-Host ('成功：{0}　逾時：{1}　取消：{2}　錯誤：{3}' -f $statistics.Success, $statistics.Timeout, $statistics.Cancelled, $statistics.Error)

    if ($statistics.Total -gt 0) {
        Write-Host ('成功率：{0:N2}%' -f (($statistics.Success / $statistics.Total) * 100.0))
    }

    if ($statistics.Success -gt 0) {
        Write-Host ('平均：{0} ({1:N3} 秒)' -f (Format-Duration $statistics.Average), $statistics.Average)
        Write-Host ('中位數：{0} ({1:N3} 秒)' -f (Format-Duration $statistics.Median), $statistics.Median)
        Write-Host ('最短／最長：{0}／{1}' -f (Format-Duration $statistics.Minimum), (Format-Duration $statistics.Maximum))
        Write-Host ('標準差：{0:N3} 秒' -f $statistics.StandardDeviation)
        Write-Host ('P90／P95：{0:N3}／{1:N3} 秒' -f $statistics.P90, $statistics.P95)
    }
    else {
        Write-Host '目前沒有成功樣本。' -ForegroundColor Yellow
    }
    Write-Host '==========================================' -ForegroundColor Cyan
}

function Save-Result {
    param([Parameter(Mandatory = $true)]$Record)

    if (Test-Path -LiteralPath $script:ResultsPath) {
        $Record | Export-Csv -LiteralPath $script:ResultsPath -NoTypeInformation -Append -Encoding UTF8
    }
    else {
        $Record | Export-Csv -LiteralPath $script:ResultsPath -NoTypeInformation -Encoding UTF8
    }
    Write-Log ('測試結果：{0}，耗時：{1} 秒' -f $Record.Status, $Record.ElapsedSeconds)
}

function Wait-ForMeasurementResult {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Timer,
        [int]$TimeoutSeconds = $script:DefaultTimeoutSeconds
    )

    Write-Host ''
    Write-Host '已寫入禁止政策 (DWORD 2)，計時開始。' -ForegroundColor Green
    Write-Host '請在 Chrome 定期測試 F12。確認已無法開啟後，切回此視窗按 Enter 或 S。'
    Write-Host '按 T 可手動標記逾時；按 C 可取消本輪。'
    Write-Host ('本輪自動逾時：{0} 分鐘。' -f [math]::Round($TimeoutSeconds / 60.0, 1))

    while ($true) {
        $elapsed = $Timer.Elapsed.TotalSeconds
        Write-Host ("`r已等待：{0}   " -f (Format-Duration $elapsed)) -NoNewline

        if ($elapsed -ge $TimeoutSeconds) {
            Write-Host ''
            return 'Timeout'
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Enter' { Write-Host ''; return 'Success' }
                'S' { Write-Host ''; return 'Success' }
                'T' { Write-Host ''; return 'Timeout' }
                'C' { Write-Host ''; return 'Cancelled' }
            }
        }
        Start-Sleep -Milliseconds 200
    }
}

function New-ResultRecord {
    param(
        [Parameter(Mandatory = $true)][int]$TestNumber,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)]$WriteInfo,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds,
        [Parameter(Mandatory = $true)]$ChromeInfo,
        [string]$Mode = 'ManualF12Confirmation',
        [string]$ConfirmationMethod = 'Manual',
        $ConfirmedAtUtc = $null,
        $LastSuccessUtc = $null,
        $FirstFailureUtc = $null,
        $LowerBoundSeconds = $null,
        $UpperBoundSeconds = $null,
        $ConfirmationSeconds = $null,
        [int]$ProbeIntervalMilliseconds = 0,
        [int]$RequiredConsecutiveFailures = 0,
        [string]$Notes = ''
    )

    if (($Status -eq 'Success') -and ($null -eq $ConfirmedAtUtc)) {
        $ConfirmedAtUtc = [DateTime]::UtcNow
    }

    $confirmedUtcText = ''
    $confirmedLocalText = ''
    if ($null -ne $ConfirmedAtUtc) {
        $confirmedDate = [DateTime]$ConfirmedAtUtc
        $confirmedUtcText = $confirmedDate.ToUniversalTime().ToString('o')
        $confirmedLocalText = $confirmedDate.ToLocalTime().ToString('o')
    }

    $lastSuccessUtcText = ''
    if ($null -ne $LastSuccessUtc) { $lastSuccessUtcText = ([DateTime]$LastSuccessUtc).ToUniversalTime().ToString('o') }
    $firstFailureUtcText = ''
    if ($null -ne $FirstFailureUtc) { $firstFailureUtcText = ([DateTime]$FirstFailureUtc).ToUniversalTime().ToString('o') }

    $lowerBoundText = ''
    if ($null -ne $LowerBoundSeconds) { $lowerBoundText = ([double]$LowerBoundSeconds).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) }
    $upperBoundText = ''
    if ($null -ne $UpperBoundSeconds) { $upperBoundText = ([double]$UpperBoundSeconds).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) }
    $confirmationText = ''
    if ($null -ne $ConfirmationSeconds) { $confirmationText = ([double]$ConfirmationSeconds).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) }

    return [PSCustomObject][ordered]@{
        SessionId = $script:SessionId
        TestNumber = $TestNumber
        Status = $Status
        Mode = $Mode
        WriteStartedUtc = $WriteInfo.WriteStartedUtc.ToString('o')
        WriteStartedLocal = $WriteInfo.WriteStartedUtc.ToLocalTime().ToString('o')
        WriteCompletedUtc = $WriteInfo.WriteCompletedUtc.ToString('o')
        WriteCompletedLocal = $WriteInfo.WriteCompletedUtc.ToLocalTime().ToString('o')
        LastSuccessUtc = $lastSuccessUtcText
        FirstFailureUtc = $firstFailureUtcText
        ConfirmedUtc = $confirmedUtcText
        ConfirmedLocal = $confirmedLocalText
        ElapsedSeconds = $ElapsedSeconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        ElapsedDisplay = Format-Duration $ElapsedSeconds
        LowerBoundSeconds = $lowerBoundText
        UpperBoundSeconds = $upperBoundText
        ConfirmationSeconds = $confirmationText
        ProbeIntervalMilliseconds = $ProbeIntervalMilliseconds
        RequiredConsecutiveFailures = $RequiredConsecutiveFailures
        ConfirmationMethod = $ConfirmationMethod
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        WindowsVersion = [Environment]::OSVersion.VersionString
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ChromePath = $ChromeInfo.Path
        ChromeVersion = $ChromeInfo.Version
        Notes = $Notes
    }
}

function Invoke-OneMeasurement {
    param(
        [Parameter(Mandatory = $true)][int]$TestNumber,
        [Parameter(Mandatory = $true)]$ChromeInfo
    )

    Clear-Host
    Write-Host ('Chrome 政策同步測試 #{0}' -f $TestNumber) -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------'
    Write-Host '準備階段：先將政策設為允許 DevTools (DWORD 1)。'
    Set-DevToolsPolicy -Value 1 | Out-Null
    Write-Host ''
    Write-Host '請回到 Chrome，等待並確認 F12 可以開啟 DevTools。' -ForegroundColor Yellow
    Write-Host '確認後請關閉 DevTools，再回到此視窗按 Enter。'
    Write-Host '若無法準備測試，輸入 C 後按 Enter 取消。'
    $ready = Read-Host '準備完成'
    if ($ready.Trim().ToUpperInvariant() -eq 'C') {
        Write-Host '本輪尚未寫入禁止政策，已取消。' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '即將寫入 DWORD 2。寫入後請勿重新啟動 Chrome、按 Reload policies 或執行 gpupdate。'
    $confirm = Read-Host '按 Enter 開始；輸入 C 可取消'
    if ($confirm.Trim().ToUpperInvariant() -eq 'C') {
        Write-Host '本輪已取消。' -ForegroundColor Yellow
        return
    }

    $writeInfo = $null
    $status = 'Error'
    $elapsedSeconds = 0.0
    $notes = ''

    try {
        $writeInfo = Set-DevToolsPolicy -Value 2 -StartTimer
        $status = Wait-ForMeasurementResult -Timer $writeInfo.Timer
        $writeInfo.Timer.Stop()
        $elapsedSeconds = $writeInfo.Timer.Elapsed.TotalSeconds
    }
    catch {
        if (($null -ne $writeInfo) -and ($null -ne $writeInfo.Timer)) {
            $writeInfo.Timer.Stop()
            $elapsedSeconds = $writeInfo.Timer.Elapsed.TotalSeconds
        }
        $notes = $_.Exception.Message
        Write-Log ('測試發生錯誤：{0}' -f $notes) 'ERROR'
        Write-Host ('測試錯誤：{0}' -f $notes) -ForegroundColor Red

        if ($null -eq $writeInfo) {
            $now = [DateTime]::UtcNow
            $writeInfo = [PSCustomObject]@{ WriteStartedUtc = $now; WriteCompletedUtc = $now; Timer = $null }
        }
    }

    $record = New-ResultRecord -TestNumber $TestNumber -Status $status -WriteInfo $writeInfo -ElapsedSeconds $elapsedSeconds -ChromeInfo $ChromeInfo -Notes $notes
    Save-Result -Record $record

    Write-Host ''
    Write-Host ('本輪結果：{0}' -f $status) -ForegroundColor Cyan
    Write-Host ('耗時：{0} ({1:N3} 秒)' -f $record.ElapsedDisplay, $elapsedSeconds)
    Write-Host ('寫入完成時間 (UTC)：{0}' -f $record.WriteCompletedUtc)
    if ($status -eq 'Success') {
        Write-Host ('人工確認時間 (UTC)：{0}' -f $record.ConfirmedUtc)
    }
    Write-Host '注意：成功耗時包含 F12 測試間隔與人工反應時間。' -ForegroundColor DarkYellow

    try {
        Set-DevToolsPolicy -Value 1 | Out-Null
        Write-Host '已切回允許值 (DWORD 1)，供下一輪準備。結束程式時會還原最初狀態。' -ForegroundColor Green
    }
    catch {
        Write-Log ('無法切回允許值：{0}' -f $_.Exception.Message) 'ERROR'
        Write-Host '警告：無法切回允許值，請結束程式以嘗試還原原始狀態。' -ForegroundColor Red
    }

    Show-Statistics
    Read-Host '按 Enter 返回主選單' | Out-Null
}

function Invoke-OneAutomaticMeasurement {
    param(
        [Parameter(Mandatory = $true)][int]$TestNumber,
        [Parameter(Mandatory = $true)]$ChromeInfo
    )

    $chromeSession = $null
    $writeInfo = $null
    $result = $null
    $record = $null

    Write-Host ''
    Write-Host ('自動測試 #{0}' -f $TestNumber) -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------'

    try {
        Set-DevToolsPolicy -Value 1 | Out-Null
        Write-Host '已設定允許政策，正在啟動隔離 Chrome...'

        $chromeSession = Start-AutomationChrome -ChromeInfo $ChromeInfo -TestNumber $TestNumber
        [void](Wait-CdpReady -ChromeSession $chromeSession)
        Write-Host ('CDP 基準確認成功；測試 Chrome PID={0}，Port={1}。' -f $chromeSession.ProcessId, $chromeSession.Port) -ForegroundColor Green

        $writeInfo = Set-DevToolsPolicy -Value 2 -StartTimer
        $result = Wait-ForAutomaticCdpFailure -ChromeSession $chromeSession -WriteInfo $writeInfo -TimeoutSeconds $script:DefaultTimeoutSeconds

        $record = New-ResultRecord `
            -TestNumber $TestNumber `
            -Status $result.Status `
            -WriteInfo $writeInfo `
            -ElapsedSeconds $result.ElapsedSeconds `
            -ChromeInfo $ChromeInfo `
            -Mode 'AutomaticCdpProbe' `
            -ConfirmationMethod 'ChromeDevToolsProtocolProbeFailure' `
            -ConfirmedAtUtc $result.ConfirmedUtc `
            -LastSuccessUtc $result.LastSuccessUtc `
            -FirstFailureUtc $result.FirstFailureUtc `
            -LowerBoundSeconds $result.LowerBoundSeconds `
            -UpperBoundSeconds $result.UpperBoundSeconds `
            -ConfirmationSeconds $result.ConfirmationSeconds `
            -ProbeIntervalMilliseconds $script:AutoProbeIntervalMilliseconds `
            -RequiredConsecutiveFailures $script:AutoRequiredConsecutiveFailures `
            -Notes $result.Notes
    }
    catch {
        if (($null -ne $writeInfo) -and ($null -ne $writeInfo.Timer)) {
            $writeInfo.Timer.Stop()
        }

        $errorMessage = $_.Exception.Message
        Write-Log ('自動測試 #{0} 發生錯誤：{1}' -f $TestNumber, $errorMessage) 'ERROR'

        if ($null -eq $writeInfo) {
            $now = [DateTime]::UtcNow
            $writeInfo = [PSCustomObject]@{
                WriteStartedUtc = $now
                WriteCompletedUtc = $now
                Timer = $null
            }
        }

        $errorElapsed = 0.0
        if ($null -ne $writeInfo.Timer) {
            $errorElapsed = $writeInfo.Timer.Elapsed.TotalSeconds
        }

        $record = New-ResultRecord `
            -TestNumber $TestNumber `
            -Status 'Error' `
            -WriteInfo $writeInfo `
            -ElapsedSeconds $errorElapsed `
            -ChromeInfo $ChromeInfo `
            -Mode 'AutomaticCdpProbe' `
            -ConfirmationMethod 'ChromeDevToolsProtocolProbeFailure' `
            -ConfirmedAtUtc ([DateTime]::UtcNow) `
            -ProbeIntervalMilliseconds $script:AutoProbeIntervalMilliseconds `
            -RequiredConsecutiveFailures $script:AutoRequiredConsecutiveFailures `
            -Notes $errorMessage
    }
    finally {
        if ($null -ne $chromeSession) {
            Stop-AutomationChrome -ChromeSession $chromeSession
        }
    }

    Save-Result -Record $record

    if ($record.Status -eq 'Success') {
        Write-Host ''
        Write-Host ('觀察到 CDP 候選停用事件：最後成功至首次失敗區間 {0} ～ {1} 秒；首次失敗 {2} 秒；連續失敗確認完成 {3} 秒。' -f `
            $record.LowerBoundSeconds, $record.UpperBoundSeconds, $record.ElapsedSeconds, $record.ConfirmationSeconds) -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host ('測試結果：{0}；{1}' -f $record.Status, $record.Notes) -ForegroundColor Red
    }

    return $record
}

function Invoke-AutomaticMeasurements {
    param(
        [Parameter(Mandatory = $true)]$ChromeInfo,
        [Parameter(Mandatory = $true)][int]$Count
    )

    Write-Host 'Chrome 政策／CDP 全自動觀測' -ForegroundColor Cyan
    Write-Host '=========================================='
    Write-Host ('Chrome：{0}' -f $ChromeInfo.Version)
    Write-Host ('輪數：{0}；每輪逾時：{1} 秒' -f $Count, $script:DefaultTimeoutSeconds)
    Write-Host '不需要按 F12，也不需要人工確認。' -ForegroundColor Green
    Write-Host '注意：自動模式觀測 CDP 功能可用性，不等同於自動驗證 F12 視窗。' -ForegroundColor DarkYellow

    for ($index = 1; $index -le $Count; $index++) {
        $existingResults = @(Get-AllResults)
        $testNumber = Get-NextTestNumber -Records $existingResults
        [void](Invoke-OneAutomaticMeasurement -TestNumber $testNumber -ChromeInfo $ChromeInfo)

        if ($index -lt $Count) {
            try {
                Set-DevToolsPolicy -Value 1 | Out-Null
                Start-Sleep -Seconds 1
            }
            catch {
                Write-Log ('準備下一輪時無法設定允許政策：{0}' -f $_.Exception.Message) 'ERROR'
                break
            }
        }
    }

    Show-Statistics
}

function Invoke-AutomationSmokeTest {
    $chromeInfo = Get-ChromeInfo
    $chromeSession = $null
    try {
        Write-Host '執行隔離 Chrome／CDP Smoke Test；不修改政策機碼...' -ForegroundColor Cyan
        $chromeSession = Start-AutomationChrome -ChromeInfo $chromeInfo -TestNumber 0
        $probe = Wait-CdpReady -ChromeSession $chromeSession
        Write-Host ('Smoke Test 通過：Chrome {0}，Port {1}，完成時間 {2}。' -f $chromeInfo.Version, $chromeSession.Port, $probe.CompletedUtc.ToString('o')) -ForegroundColor Green
        exit 0
    }
    catch {
        Write-Host ('Smoke Test 失敗：{0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    finally {
        if ($null -ne $chromeSession) {
            Stop-AutomationChrome -ChromeSession $chromeSession
        }
    }
}

function Invoke-SelfTest {
    Write-Host '執行不修改機碼的自我測試...' -ForegroundColor Cyan
    $failures = New-Object System.Collections.Generic.List[string]

    try {
        if ((Format-Duration 65.25) -ne '00:01:05.250') {
            $failures.Add('Format-Duration 結果不正確。')
        }

        $mock = @(
            [PSCustomObject]@{ Status = 'Success'; ElapsedSeconds = '10.000' },
            [PSCustomObject]@{ Status = 'Success'; ElapsedSeconds = '20.000' },
            [PSCustomObject]@{ Status = 'Success'; ElapsedSeconds = '30.000' },
            [PSCustomObject]@{ Status = 'Timeout'; ElapsedSeconds = '60.000' },
            [PSCustomObject]@{ Status = 'Cancelled'; ElapsedSeconds = '5.000' }
        )
        $stats = Get-ResultStatistics -Records $mock
        if (($stats.Total -ne 5) -or ($stats.Success -ne 3) -or ([math]::Abs($stats.Average - 20.0) -gt 0.0001) -or ([math]::Abs($stats.Median - 20.0) -gt 0.0001)) {
            $failures.Add('統計計算結果不正確。')
        }

        $evenMock = @(
            [PSCustomObject]@{ Status = 'Success'; ElapsedSeconds = '2.000' },
            [PSCustomObject]@{ Status = 'Success'; ElapsedSeconds = '4.000' }
        )
        $evenStats = Get-ResultStatistics -Records $evenMock
        if ([math]::Abs($evenStats.Median - 3.0) -gt 0.0001) {
            $failures.Add('偶數樣本中位數計算不正確。')
        }

        if ((Get-NextTestNumber -Records @()) -ne 1) {
            $failures.Add('空結果資料的下一個測試編號不正確。')
        }

        if ((Get-NextTestNumber -Records $evenMock) -ne 3) {
            $failures.Add('既有結果資料的下一個測試編號不正確。')
        }

        $chrome = Get-ChromeInfo
        if ($null -eq $chrome) {
            $failures.Add('Chrome 資訊函式未傳回結果。')
        }
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    if ($failures.Count -gt 0) {
        Write-Host '自我測試失敗：' -ForegroundColor Red
        foreach ($failure in $failures) { Write-Host ('- {0}' -f $failure) -ForegroundColor Red }
        exit 1
    }

    Write-Host '自我測試通過。未修改 Chrome 政策機碼。' -ForegroundColor Green
    exit 0
}

function Invoke-Main {
    param(
        [switch]$StartImmediately,
        [switch]$AutomaticMode,
        [int]$AutomaticIterations = 10
    )

    if (-not (Test-Path -LiteralPath $script:DataDirectory)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }

    $chromeInfo = Get-ChromeInfo
    Write-Log ('啟動監測器；Chrome={0}；Version={1}' -f $chromeInfo.Path, $chromeInfo.Version)

    $unrestored = @(Get-UnrestoredBackups)
    if ($unrestored.Count -gt 0) {
        if ($AutomaticMode) {
            Write-Host ('偵測到 {0} 個未完成備份，正在自動還原...' -f $unrestored.Count) -ForegroundColor Yellow
            $restoredCount = Restore-AllUnrestoredBackups
            Write-Host ('已還原 {0} 個殘留備份。' -f $restoredCount) -ForegroundColor Green
        }
        else {
            $latest = $unrestored[0]
            Write-Host '偵測到先前未標記為已還原的備份，可能是上次未正常結束。' -ForegroundColor Yellow
            Write-Host ('備份：{0}' -f $latest.Path)
            $choice = Read-Host '輸入 R 還原該備份；按 Enter 保留目前狀態並繼續'
            if ($choice.Trim().ToUpperInvariant() -eq 'R') {
                Restore-PolicyBackup -BackupData $latest.Data -BackupPath $latest.Path
                Write-Host '已還原先前備份。' -ForegroundColor Green
            }
        }
    }

    $backup = Save-PolicyBackup
    $restored = $false

    try {
        if ($AutomaticMode) {
            Invoke-AutomaticMeasurements -ChromeInfo $chromeInfo -Count $AutomaticIterations
            return
        }

        if ($StartImmediately) {
            $existingResults = @(Get-AllResults)
            $testNumber = Get-NextTestNumber -Records $existingResults
            Invoke-OneMeasurement -TestNumber $testNumber -ChromeInfo $chromeInfo
            return
        }

        while ($true) {
            Clear-Host
            $state = Get-PolicyState
            $displayValue = '<未設定>'
            if ($state.ValueExists) { $displayValue = '{0} ({1})' -f $state.Value, $state.ValueKind }

            Write-Host 'Google Chrome 政策同步時間監測器' -ForegroundColor Cyan
            Write-Host '=========================================='
            Write-Host ('Chrome：{0}' -f $chromeInfo.Version)
            Write-Host ('目前 DeveloperToolsAvailability：{0}' -f $displayValue)
            Write-Host ('結果檔：{0}' -f $script:ResultsPath)
            Write-Host ''
            Write-Host '1. 開始一輪測試'
            Write-Host '2. 查看累積統計'
            Write-Host '3. 開啟資料資料夾'
            Write-Host '4. 還原原始機碼並離開'
            Write-Host ''
            $selection = Read-Host '請選擇'

            switch ($selection.Trim()) {
                '1' {
                    $existingResults = @(Get-AllResults)
                    $testNumber = Get-NextTestNumber -Records $existingResults
                    Invoke-OneMeasurement -TestNumber $testNumber -ChromeInfo $chromeInfo
                }
                '2' {
                    Show-Statistics
                    Read-Host '按 Enter 返回主選單' | Out-Null
                }
                '3' {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:DataDirectory) | Out-Null
                }
                '4' { break }
                default {
                    Write-Host '請輸入 1、2、3 或 4。' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }

            if ($selection.Trim() -eq '4') { break }
        }
    }
    finally {
        if (-not $restored) {
            try {
                Restore-PolicyBackup -BackupData $backup.Data -BackupPath $backup.Path
                $restored = $true
                Write-Host ''
                Write-Host '已還原程式啟動前的原始機碼狀態。' -ForegroundColor Green
            }
            catch {
                Write-Log ('還原原始機碼失敗：{0}' -f $_.Exception.Message) 'ERROR'
                Write-Host ''
                Write-Host '警告：自動還原失敗。請保留下列備份檔並以系統管理員身分重新執行程式：' -ForegroundColor Red
                Write-Host $backup.Path -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor DarkRed
            }
        }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
}

if ($AutomationSmokeTest) {
    Invoke-AutomationSmokeTest
}

if (-not (Test-IsAdministrator)) {
    Write-Host '此工具需要系統管理員權限才能修改 HKLM。正在要求 UAC 授權...' -ForegroundColor Yellow
    [void](Start-ElevatedCopy)
    exit
}

if ($RecoverOnly) {
    Invoke-RecoveryOnly
    exit 0
}

Invoke-Main -StartImmediately:$DirectStart -AutomaticMode:$Auto -AutomaticIterations $Iterations
