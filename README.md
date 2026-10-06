# Chrome Policy Sync Monitor

以 Windows PowerShell 5.1 撰寫的 Chrome Enterprise 政策觀測工具，用來記錄下列事件之間的時間：

1. 寫入機器層級政策 `HKLM\SOFTWARE\Policies\Google\Chrome\DeveloperToolsAvailability=2`；
2. 人工觀察到 F12／DevTools 無法開啟，或自動觀察到既有 Chrome DevTools Protocol（CDP）工作階段連續失敗。

專案不依賴 PowerShell Gallery、Node.js、Python 或第三方套件。CDP helper 由 Windows PowerShell 隨附的 `Add-Type` 在本機從 C# 原始碼編譯。

> [!IMPORTANT]
> 自動模式測試的是 **CDP 功能可用性**，不是模擬鍵盤按 F12，也不是 UI 自動化。自動模式的 `Success` 只表示符合本專案定義的「候選 CDP 停用事件」；它不單獨證明 F12 已被封鎖，也不能排除其他 CDP 錯誤。

## 目錄

- [功能摘要](#功能摘要)
- [安全與影響範圍](#安全與影響範圍)
- [系統需求](#系統需求)
- [快速開始](#快速開始)
- [自動模式如何運作](#自動模式如何運作)
- [CDP 是什麼](#cdp-是什麼)
- [人工 F12 模式](#人工-f12-模式)
- [命令列參數](#命令列參數)
- [結果檔與欄位](#結果檔與欄位)
- [狀態與結果解讀](#狀態與結果解讀)
- [備份、異常中止與復原](#備份異常中止與復原)
- [完整測試流程](#完整測試流程)
- [程式架構](#程式架構)
- [測量方法與誤差](#測量方法與誤差)
- [已知限制](#已知限制)
- [疑難排解](#疑難排解)
- [隱私與提交規則](#隱私與提交規則)
- [官方參考資料](#官方參考資料)

## 功能摘要

- 支援不需人工按 F12 的多輪自動 CDP 觀測。
- 保留人工 F12／DevTools 視窗確認模式。
- 每輪自動測試使用全新的 Chrome `--user-data-dir`，不讀寫日常 Chrome Profile。
- 使用 `--remote-debugging-port=0` 讓 Chrome 選擇可用的本機偵錯連接埠。
- 在政策值 `1` 時先建立 CDP 功能基準，避免把一開始就不能連線誤當成切換結果。
- 以 CDP `Runtime.evaluate` 執行 `1+1`，驗證頁面 target 的實際 CDP 命令回應，而不只檢查 TCP 或 HTTP。
- 預設每約 500 ms 探測一次，需連續失敗 3 次才記錄候選停用事件。
- 連續失敗後額外確認測試 Chrome 仍存活、`/json/version` 仍可連線，且登錄值仍為 `DWORD 2`。
- 記錄最後成功、首次失敗、候選時間區間與連續失敗確認完成時間。
- 自動備份並還原程式啟動前的政策狀態。
- 可在異常中止後還原未完成的備份並清理隔離 Chrome。
- 提供 parser、self-test 與 Chrome/CDP smoke test 驗證流程。
- 將結果、日誌、政策備份與暫存 Profile 放在 `data`，並由 Git 排除。

## 安全與影響範圍

### 這是機器層級政策

測量模式會暫時修改：

```text
HKLM\SOFTWARE\Policies\Google\Chrome\DeveloperToolsAvailability
```

`HKLM` 政策可能影響同一台電腦上的所有 Chrome 使用者與 Profile。隔離的 `--user-data-dir` 只隔離瀏覽器 Profile 資料，**不會隔離機器政策**。

建議：

- 優先在測試機、虛擬機或核准的維護時段執行；
- 正式測量期間不要使用同一台機器進行需要 DevTools 的工作；
- 不要在隔離測試 Chrome 登入帳號、輸入密碼或瀏覽敏感資料；
- 完成後確認原始政策已還原。

### 系統管理員權限

修改 HKLM 需要系統管理員權限。一般啟動檔會先以目前權限執行，再透過 UAC 啟動提升權限的 PowerShell。使用者只需核准 UAC，不需把密碼、token 或其他憑證寫入專案。

### Remote debugging

自動測試 Chrome 會啟用本機 remote-debugging endpoint。測試期間，本機其他程序可能嘗試連線，因此隔離 Profile 不應存放任何真實登入資訊。每輪完成後，程式會停止屬於該 Profile 的 Chrome processes 並刪除 Profile。

更多資訊請參閱 [SECURITY.md](SECURITY.md)。

## 系統需求

- Windows 10、Windows 11 或相容的 Windows Server 環境；
- Google Chrome；
- Windows PowerShell 5.1 或更新版本；
- 可使用 WMI/CIM 查詢本機 process command line；
- 測量與復原模式需要本機系統管理員權限；
- Smoke Test 不修改政策，通常不需提升權限。

Chrome 搜尋順序：

1. `C:\Program Files\Google\Chrome\Application\chrome.exe`
2. `C:\Program Files (x86)\Google\Chrome\Application\chrome.exe`
3. `%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe`

## 快速開始

下載或 clone 後，在專案根目錄使用下列入口。所有 `.cmd` 都先切換到自身所在目錄，因此專案可以放在任意本機路徑，包括含空白的路徑。

### 一輪自動觀測

首次確認環境時建議先執行：

```text
Start-Auto-One.cmd
```

流程會要求一次 UAC，然後自動完成一輪。預設逾時 1800 秒。

### 十輪自動觀測

```text
Start-Auto.cmd
```

預設執行 10 輪，每輪最多 1800 秒。如果所有輪次都逾時，總時間可能接近 5 小時，另加 Chrome 啟動與輪次間準備時間。

### 不修改政策的快速驗證

先執行靜態與邏輯自我測試：

```text
Run-SelfTest.cmd
```

再驗證隔離 Chrome、remote-debugging、CDP helper 與清理：

```text
Run-AutomationSmokeTest.cmd
```

Smoke Test 不修改政策，但**會受目前已套用的 Chrome 政策影響**。如果系統目前已禁止 remote debugging，Smoke Test 基準可能失敗；這不一定代表程式碼有錯。

## 自動模式如何運作

每一輪的完整流程如下：

```text
程式啟動
  │
  ├─ 還原先前未完成的備份（自動模式）
  ├─ 備份目前 DeveloperToolsAvailability 狀態
  │
  └─ 每一輪：
       1. 寫入 DWORD 1
       2. 建立新的 data/auto-profiles/test-... 目錄
       3. 以 --remote-debugging-port=0 啟動隔離 Chrome
       4. 從 DevToolsActivePort 讀取 Chrome 選擇的 port
       5. 找出真正的 browser PID，而不是只依賴 launcher PID
       6. 呼叫 /json/list 取得頁面 target 的 WebSocket URL
       7. 送出 Runtime.evaluate("1+1")，確認回傳值為 2
       8. 寫入 DWORD 2，完成寫入後開始 Stopwatch
       9. 每約 500 ms 重新執行 CDP 功能探測
      10. 成功時重設連續失敗計數
      11. 連續失敗 3 次時進行 browser／HTTP／registry 安全檢查
      12. 寫入 results.csv
      13. 停止本輪隔離 Chrome並刪除 Profile
  │
  └─ finally：還原程式啟動前的原始政策狀態
```

### 為什麼不把單次失敗當成結果

單次 CDP 失敗可能來自 process 排程、短暫連線錯誤、target 切換、helper timeout 或其他非政策因素。因此程式預設要求連續 3 次失敗，並檢查 Chrome 與 HTTP discovery endpoint 是否仍存活。

這些檢查只能排除部分常見誤判。它們仍不足以從因果上證明「失敗一定由 `DeveloperToolsAvailability` 引起」。

### 為什麼檢查 launcher handoff

在 Windows 上啟動 `chrome.exe` 時，最初 process 可能很快結束，實際 browser 工作由另一個 process 接手。程式會依隔離 Profile 路徑與不含 `--type=` 的 command line 找出真正 browser process，避免因 launcher 結束而誤判 Chrome 已關閉。

## CDP 是什麼

CDP 是 **Chrome DevTools Protocol**。Chrome DevTools 前端及其他自動化工具可透過這套 JSON protocol 對 Chromium/Chrome 進行檢查、偵錯與效能分析。

本專案使用的最小流程：

1. Chrome 以 `--remote-debugging-port=0` 啟動；
2. Chrome 把選到的 port 寫入 Profile 內的 `DevToolsActivePort`；
3. helper 讀取 `http://127.0.0.1:<port>/json/list`；
4. 從 JSON 找出頁面 target 的 `webSocketDebuggerUrl`；
5. 透過 WebSocket 傳送：

```json
{
  "id": 1,
  "method": "Runtime.evaluate",
  "params": {
    "expression": "1+1",
    "returnByValue": true
  }
}
```

6. 回應中包含 request id `1` 且結果值為 `2`，才視為本次 probe 成功。

### CDP 與 F12 的關係

兩者都屬於 Chrome 開發者工具能力的一部分，但觀測面不同：

| 模式 | 實際觀察項目 | 優點 | 主要限制 |
|---|---|---|---|
| 人工 F12 | DevTools 視窗是否能由使用者開啟 | 直接接近使用者情境 | 有人工反應時間、測試間隔與焦點誤差 |
| 自動 CDP | 既有 remote-debugging 工作階段能否執行命令 | 可高頻率、可重複、可無人值守 | 不等同於 F12 UI；失敗原因可能不是政策 |

如果目標是證明「使用者按 F12 時 DevTools 視窗已不能開啟」，應使用人工模式，或另外建立具有畫面辨識與焦點驗證的 Windows UI automation。這個專案目前沒有實作後者。

## 人工 F12 模式

### 主選單

```text
Start.cmd
```

主選單可開始單輪人工測試、查看累積統計、開啟資料目錄，或還原原始政策後離開。

### 直接開始一輪

```text
Start-Direct.cmd
```

人工流程：

1. 程式先寫入 `DWORD 1`；
2. 使用者確認 Chrome 可以開啟 DevTools，關閉 DevTools 後回到 PowerShell；
3. 程式寫入 `DWORD 2` 並開始計時；
4. 使用者定期在 Chrome 測試 F12；
5. 確認無法開啟時回到 PowerShell，按 `Enter` 或 `S`；
6. `T` 可手動標記逾時，`C` 可取消該輪；
7. 程式記錄結果，並在離開時還原啟動前狀態。

人工 `Success` 的耗時包含 F12 測試間隔、切換視窗、使用者觀察與反應、按鍵時間。因此人工結果不應解讀為毫秒級政策套用時間。

## 命令列參數

主程式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor.ps1 [參數]
```

| 參數 | 說明 | 預設／範圍 |
|---|---|---|
| `-SelfTest` | 執行不修改政策的函式與統計測試 | switch |
| `-AutomationSmokeTest` | 啟動隔離 Chrome 並完成一次 CDP probe；不修改政策 | switch |
| `-DirectStart` | 提升權限後直接開始一輪人工 F12 測試 | switch |
| `-Auto` | 執行無人值守 CDP 觀測 | switch |
| `-RecoverOnly` | 只做安全復原，不開始測量 | switch |
| `-Iterations` | 自動模式輪數 | 預設 10；1–1000 |
| `-TimeoutSeconds` | 每輪逾時秒數 | 預設 1800；5–7200 |

範例：執行 3 輪，每輪最多 120 秒：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor.ps1 `
  -Auto -Iterations 3 -TimeoutSeconds 120
```

範例：只做復原：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor.ps1 -RecoverOnly
```

## 結果檔與欄位

執行時建立的資料均位於 `data\`：

| 路徑 | 用途 | 是否應提交 Git |
|---|---|---|
| `data/results.csv` | 每輪結果與環境資料 | 否 |
| `data/monitor.log` | 執行與錯誤紀錄 | 否 |
| `data/backup-*.json` | 原始政策狀態與還原標記 | 否 |
| `data/auto-profiles/` | 隔離 Chrome 暫存 Profile | 否 |
| `data/validation-*.txt` | 開發驗證報告 | 否 |
| `data/probe-*.txt` | helper 暫存 stdout/stderr；正常會刪除 | 否 |

### `results.csv` 欄位

| 欄位 | 說明 |
|---|---|
| `SessionId` | 本次 PowerShell process 的隨機 GUID |
| `TestNumber` | 依目前 CSV 筆數產生的測試序號 |
| `Status` | `Success`、`Timeout`、`Cancelled` 或 `Error` |
| `Mode` | `ManualF12Confirmation` 或 `AutomaticCdpProbe` |
| `WriteStartedUtc` / `WriteStartedLocal` | 開始寫入 `DWORD 2` 的時間 |
| `WriteCompletedUtc` / `WriteCompletedLocal` | Windows registry 寫入 API 完成的時間；read-back validation 緊接著執行 |
| `LastSuccessUtc` | 自動模式最後一次成功 probe 的完成時間 |
| `FirstFailureUtc` | 最終連續失敗序列第一次 probe 的開始時間 |
| `ConfirmedUtc` / `ConfirmedLocal` | 人工確認或連續失敗確認完成時間 |
| `ElapsedSeconds` | 人工確認耗時；自動 Success 時為首次失敗相對時間；Timeout/Error 為結束耗時 |
| `ElapsedDisplay` | `HH:mm:ss.fff` 顯示格式 |
| `LowerBoundSeconds` | 自動模式最後成功相對於政策寫入完成的時間 |
| `UpperBoundSeconds` | 自動 Success 時首次失敗相對於政策寫入完成的時間 |
| `ConfirmationSeconds` | 完成連續失敗確認或結束觀察的時間 |
| `ProbeIntervalMilliseconds` | 設定的 probe 間隔；目前為 500 ms |
| `RequiredConsecutiveFailures` | 候選事件所需連續失敗次數；目前為 3 |
| `ConfirmationMethod` | `Manual` 或 `ChromeDevToolsProtocolProbeFailure` |
| `ComputerName` | Windows 電腦名稱；屬於敏感環境資料 |
| `UserName` | Windows 使用者／網域名稱；屬於敏感個資 |
| `WindowsVersion` | 執行時 Windows 版本 |
| `PowerShellVersion` | 執行時 PowerShell 版本 |
| `ChromePath` | 本機 Chrome 完整路徑；可能包含使用者目錄 |
| `ChromeVersion` | Chrome product version |
| `Notes` | 判定依據或錯誤訊息；可能包含本機路徑 |

`results.csv` 含電腦名稱、使用者名稱與本機路徑，**不得未經脫敏直接公開**。

## 狀態與結果解讀

### `Success`

- **人工模式**：使用者表示 F12／DevTools 已無法開啟。
- **自動模式**：先有成功基準，之後 Chrome 與 HTTP endpoint 仍存活、登錄值讀回 `DWORD 2`，且 CDP 功能 probe 連續失敗達門檻。

自動 `Success` 是候選 CDP 停用觀測，不是政策因果證明。

### `Timeout`

在設定的觀察時間內沒有出現符合條件的連續失敗。這是有效觀測結果，不代表程式卡住或還原失敗。

對已建立的 remote-debugging session 而言，Chrome 可能在整個時間窗仍允許命令執行；政策也可能只影響新工作、特定 target、UI 或其他路徑。應依 Chrome 版本與完整政策集合解讀。

### `Cancelled`

人工模式由使用者取消。只有已進入計時階段的取消才會留下結果紀錄。

### `Error`

環境或驗證條件不成立，例如找不到 Chrome、基準 probe 失敗、Chrome 意外結束、HTTP endpoint 失效、機碼不是預期值、helper 失敗，或寫入／還原政策失敗。

### 統計

主選單與自動模式結束時會顯示總次數、各狀態數量、成功率，以及 Success 樣本的平均值、中位數、最短、最長、樣本標準差、P90、P95。

只有 `Status=Success` 會納入時間統計。人工與自動模式的 `Success` 定義不同，正式分析時應依 `Mode` 分組，不建議混合計算。

## 備份、異常中止與復原

### 正常結束

程式啟動測量前建立 `data/backup-*.json`，保存原本 key/value 是否存在、registry type、原始值、擷取時間與還原時間。

主要執行流程放在 `try/finally` 中。正常完成、發生一般例外或使用者離開主選單時，都會嘗試恢復原始狀態並更新 `RestoredUtc`。

### 異常中止

斷電、強制終止 PowerShell 或作業系統當機可能讓 `finally` 無法執行。下一次進入自動模式時，程式會由新到舊還原所有 `RestoredUtc` 為空的備份，使最終狀態回到最早保存的原始值。

### 手動安全復原

```text
Recover.cmd
```

或：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor.ps1 -RecoverOnly
```

復原模式會要求 UAC、停止屬於本專案 Profile 的 Chrome、停止殘留 helper、刪除暫存 Profile、還原未完成備份，並顯示目前政策狀態。它不應停止使用其他 Profile 的日常 Chrome，但執行前仍建議保存工作。

> [!WARNING]
> 不要在確認復原成功前刪除 `data/backup-*.json`。Git 忽略 `data` 不代表可以任意刪除本機備份。

## 完整測試流程

以下流程供開發、發布與乾淨 clone 驗證使用。

> [!CAUTION]
> 不要平行執行 Static validation、Smoke validation 或正式測量。它們共用 `data`、helper 編譯產物與隔離 Profile 根目錄。驗證腳本會在開始前檢查既有 Monitor、隔離 Chrome 與 Profile；若環境不乾淨會以 exit code `2` 結束，而不會中斷其他測量。

### 0. 前置檢查

記錄目前政策，不要假設它一定未設定：

```powershell
$path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome'
if (Test-Path $path) {
    $key = Get-Item $path
    if (@($key.GetValueNames()) -contains 'DeveloperToolsAvailability') {
        '{0} ({1})' -f $key.GetValue('DeveloperToolsAvailability'), `
            $key.GetValueKind('DeveloperToolsAvailability')
    }
    else { '<not set>' }
}
else { '<key missing>' }
```

確認沒有上一輪隔離 Chrome 正在使用 `data/auto-profiles`。如果狀態不明，先執行 `Recover.cmd`。

### 1. Parser 與 Self-Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Validate-Automation.ps1 -Mode Static
```

此模式會解析 `Monitor.ps1`、執行 `Monitor.ps1 -SelfTest`、驗證 duration formatting／統計／中位數／序號／Chrome 資訊，比對政策前後狀態，並確認無殘留隔離 Chrome 或 Profile。

報告寫到 `data/validation-static.txt`。成功傳回 exit code `0`，任一檢查失敗傳回非零值。

也可直接雙擊：

```text
Run-SelfTest.cmd
```

### 2. 隔離 Chrome／CDP Smoke Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Validate-Automation.ps1 -Mode Smoke
```

此模式會清理殘留隔離 Chrome、啟動新的隔離 Chrome、等待 `DevToolsActivePort`、編譯或重用 helper、執行一次 `Runtime.evaluate("1+1")`、在 45 秒內等待完成，最後清理 process/Profile 並比對政策前後狀態。

報告寫到 `data/validation-smoke.txt`。Smoke Test 不修改政策；如果目前政策不允許建立 remote-debugging 基準，測試應以非零 exit code 結束並保留診斷輸出。

### 3. 短時間單輪整合測試

這一步會修改 HKLM，請只在核准環境執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Monitor.ps1 -Auto -Iterations 1 -TimeoutSeconds 15
```

驗收條件：

- UAC 提升成功；
- 政策值 `1` 時能建立基準；
- 寫入 `2` 後得到 `Success`、`Timeout` 或有明確原因的 `Error`；
- 結果寫入 CSV；
- 測試 Chrome 與 Profile 已清除；
- 最終政策與步驟 0 完全相同；
- 最新備份具有非空白 `RestoredUtc`。

不要為了讓測試通過而手動刪除或改寫備份檔。

### 4. 異常復原測試

應在測試機進行：

1. 記錄原始政策；
2. 啟動單輪測量；
3. 在測量中強制終止提升權限的 PowerShell；
4. 確認留下 `RestoredUtc` 空白的備份；
5. 執行 `Recover.cmd`；
6. 確認原始政策被恢復；
7. 確認沒有隔離 Chrome、helper 或 Profile 殘留；
8. 確認該備份已寫入 `RestoredUtc`。

### 5. 正式多輪測量

固定 Chrome 版本、Windows build、PowerShell 版本、電腦負載、電源模式、其他 policies，以及 timeout、probe interval、failure threshold。

建議至少 10 輪；若分析 P90/P95，應收集更多樣本。人工與自動模式分開分析，Timeout 也應保留並回報，不要只留下 Success。

### 6. 發布前 Git 檢查

```powershell
git status --short
git diff --check
git diff --cached --stat
git diff --cached
git ls-files
```

必須確認 `data/`、`CdpProbeHelper.exe`、結果、日誌、備份、validation、Chrome Profile、`.env`、private key、certificate、token 或含憑證的 remote URL 未被追蹤。

## 程式架構

### 檔案

| 檔案 | 責任 |
|---|---|
| `Monitor.ps1` | 權限提升、Chrome lifecycle、policy backup/write/restore、人工／自動測量、CSV 與統計 |
| `CdpProbeHelper.cs` | 獨立 CDP probe process；查詢 target、連線 WebSocket、執行 `Runtime.evaluate` |
| `Validate-Automation.ps1` | Parser、Self-Test、Smoke Test、政策不變與清理驗證，並提供可靠 exit code |
| `Start-Auto.cmd` | 10 輪自動模式 |
| `Start-Auto-One.cmd` | 1 輪自動模式 |
| `Start.cmd` | 人工模式主選單 |
| `Start-Direct.cmd` | 直接開始一輪人工模式 |
| `Run-SelfTest.cmd` | 不修改政策的 self-test |
| `Run-AutomationSmokeTest.cmd` | 不修改政策的 Chrome/CDP smoke test |
| `Recover.cmd` | 只執行安全復原 |
| `.gitignore` | 排除 runtime data、編譯產物與常見秘密檔 |
| `SECURITY.md` | 安全、隱私與 vulnerability reporting 說明 |

### `Monitor.ps1` 主要模組

| 函式群組 | 主要函式 | 說明 |
|---|---|---|
| 權限與環境 | `Test-IsAdministrator`, `Start-ElevatedCopy`, `Get-ChromeInfo` | UAC 與 Chrome discovery |
| Chrome lifecycle | `Start-AutomationChrome`, `Test-AutomationChromeRunning`, `Stop-AutomationChrome` | 建立、辨識、停止隔離 browser |
| CDP | `Invoke-CdpProbe`, `Wait-CdpReady`, `Test-CdpHttpEndpoint` | helper build/execute、基準、HTTP 健康檢查 |
| 自動觀測 | `Wait-ForAutomaticCdpFailure`, `Invoke-OneAutomaticMeasurement` | 連續探測、候選事件與結果建立 |
| 政策 | `Get-PolicyState`, `Set-DevToolsPolicy` | HKLM 讀取、寫入與 read-back validation |
| 備份復原 | `Save-PolicyBackup`, `Restore-PolicyBackup`, `Restore-AllUnrestoredBackups` | 保留 value existence/type/value 並復原 |
| 結果統計 | `New-ResultRecord`, `Save-Result`, `Get-ResultStatistics`, `Show-Statistics` | CSV schema 與統計 |
| 人工模式 | `Invoke-OneMeasurement`, `Wait-ForMeasurementResult` | F12 人工確認 |
| 驗證 | `Invoke-SelfTest`, `Invoke-AutomationSmokeTest` | 不修改政策的測試入口 |

### 為什麼 helper 是獨立 process

CDP 網路操作可能因環境或 framework 行為而等待過久。主程式將 probe 放在 `CdpProbeHelper.exe`：

- 每次 probe 都有 protocol timeout；
- 主 PowerShell 另有 `timeout + 2000 ms` 的 process hard timeout；
- 超時可強制停止 helper；
- helper stdout/stderr 先寫到 `data/probe-*.txt`，讀取後在 `finally` 刪除。

`CdpProbeHelper.exe` 不提交 Git。當 EXE 不存在，或 `.cs` 比 EXE 新時，`Add-Type -OutputAssembly` 會重新編譯。

## 測量方法與誤差

### 計時起點

程式先寫入 registry，記錄 `WriteCompletedUtc`，接著啟動 `Stopwatch` 並執行 read-back validation。這測量的是「本機 registry 寫入 API 完成後，到觀測事件」的時間；它包含緊接在起點後的讀回驗證耗時，但不包含 registry 寫入前的準備時間。

### 自動模式區間

離散 probe 無法知道兩次 probe 中間的確切變化時間。程式記錄：

- 下界：最後成功 probe 完成相對於政策寫入完成的時間；
- 上界：最終連續失敗序列第一次 probe 開始相對於政策寫入完成的時間；
- 確認時間：第 3 次連續失敗完成的時間。

此區間是 **CDP 功能由成功轉為失敗的觀測區間**，不是經過因果驗證的「政策生效區間」。

實際時間解析度還受到 500 ms sleep、每次 probe 耗時、Windows scheduler、Chrome 負載、helper process 啟動時間與連續失敗門檻影響。

### 系統時間與 Stopwatch

- UTC timestamps 供事件關聯與記錄；
- elapsed duration 使用單調遞增的 `System.Diagnostics.Stopwatch`，避免系統時鐘調整直接扭曲耗時。

## 已知限制

1. **CDP 不等於 F12 UI。** 自動模式不能宣稱已自動按 F12 或驗證 DevTools 視窗。
2. **CDP 失敗不等於政策因果成立。** 其他 protocol、target、process 或網路錯誤仍可能通過目前的部分安全檢查。
3. **Registry read-back 不等於 Chrome 已重新讀取政策。** 程式只確認 Windows registry 中的值與型別。
4. **Chrome policies 可能互相影響。** 應同時檢查 `chrome://policy` 與官方 policy 文件。
5. **進行中的工作可能與新工作行為不同。** 已建立 remote-debugging session 未必會在政策更新後立刻被撤銷。
6. **Profile 隔離不是 policy 隔離。** HKLM 政策可能影響日常 Chrome。
7. **Chrome discovery 路徑有限。** Chromium、Chrome Beta/Dev/Canary 或自訂安裝路徑不會自動找到。
8. **只探測第一個可檢查 page target。** 多 target、extension、worker 或 browser target 不在目前範圍。
9. **helper 是最小實作。** 簡化的 JSON/WebSocket 邏輯只服務本專案，不是通用 CDP client。
10. **輸出可能包含敏感環境資料。** `data` 必須保持在 Git 之外。

## 疑難排解

### 找不到 Chrome

確認 Chrome 安裝於支援路徑。若使用 Beta、Canary、Chromium 或企業自訂位置，需要修改 `Get-ChromeInfo` 的搜尋清單。

### `政策值 1 的 CDP 基準確認逾時`

可能原因包括其他 policy 阻止 remote debugging、policy 尚未被 Chrome 採用、security software 阻擋 loopback WebSocket、Chrome 啟動過慢、目前版本有額外限制，或 helper 無法編譯／執行。

先執行 Smoke Test，查看：

```text
data/validation-smoke.txt
data/validation-smoke-output.txt
data/validation-smoke-error.txt
data/monitor.log
```

### Chrome 啟動後立刻回報 process 不存在

程式已處理常見 launcher handoff。如果仍發生，檢查 `monitor.log` 中的 Profile 路徑，並用 CIM 查看相同 `--user-data-dir` 的 Chrome command line。

### Smoke Test 失敗但政策已是 2

Smoke Test 刻意不修改政策。如果現有政策阻止新 remote-debugging session，失敗是合理結果。不要為了 smoke test 在未備份的情況下手動改 registry；應在核准環境使用正式自動模式，由程式負責備份與還原。

### 自動模式一直 Timeout

`Timeout` 代表觀察期間內既有 CDP session 沒有出現符合門檻的失敗。可以延長 `-TimeoutSeconds`、檢查 Chrome 版本與完整 policies、同時進行獨立的人工 F12 測量，或分別測試政策切換前已建立與切換後新建立的 Chrome。

不要把 Timeout 自動改標成 Success。

### 政策未還原

1. 不要刪除 `data/backup-*.json`；
2. 以系統管理員身分執行 `Recover.cmd`；
3. 查看 `monitor.log` 的最後錯誤；
4. 比對最新 backup 的 `ValueExisted`、`ValueKind`、`Value` 與 `RestoredUtc`；
5. 若仍失敗，停止測量並交由系統管理員處理。

### 殘留 Chrome 或 Profile

執行 `Recover.cmd`。復原只以本專案 `data/auto-profiles` 路徑辨識隔離 Chrome，不應終止其他 Profile；但操作前仍應保存日常 Chrome 工作。

## 隱私與提交規則

`.gitignore` 排除整個 `data/`、編譯後的 helper、log、CSV、backup、validation、probe output，以及常見 `.env`、private key、certificate、password database 與 credential JSON。

提交前仍須人工檢查，因為 `.gitignore` 不是秘密掃描器，也無法保護已被 Git 追蹤的檔案。

```powershell
git ls-files
git diff --cached
git grep -n -I -E "github_pat_|gh[pousr]_|BEGIN .*PRIVATE KEY|password|token|secret"
```

不要提交 GitHub PAT、密碼、cookie、session、client secret、含憑證的 remote URL、registry export、未脫敏結果／日誌或本機 Chrome Profile。

## 開發驗證紀錄

2026-10-04 的開發環境曾完成 PowerShell parser、內建 self-test、隔離 Chrome/CDP smoke test、一輪短逾時自動觀測、launcher handoff 修正驗證，以及原始政策還原與殘留 process/Profile 清理檢查。

該次短逾時觀測中，已建立的 CDP session 在 180 秒內持續可用，因此結果為 `Timeout`。這只代表該版本、該環境與該次觀察窗口。原始 CSV、log、電腦名稱、使用者名稱、路徑與 registry backup 不包含在儲存庫中。

## 官方參考資料

- [Chrome Enterprise：DeveloperToolsAvailability policy](https://chromeenterprise.google/policies/developer-tools-availability/)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [CDP Runtime domain／Runtime.evaluate](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate)

Chrome 與政策行為可能隨版本調整。正式測試前應重新檢查官方文件、Chrome release notes 與目標環境的完整 policy 清單。