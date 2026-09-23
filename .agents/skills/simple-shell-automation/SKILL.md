---
name: simple-shell-automation
description: 撰寫、修改及整合 Linux Shell/Bash 自動化腳本，採用簡單、可重複執行、不要用進階技巧的風格。當使用者要求 Shell 自動化、sh 腳本、Linux 維運腳本，或要求將手動 Linux 指令改成容易維護的腳本時使用，包含 OS 設定、套件安裝、服務管理及資料庫維運前置作業。
---

# 簡單 Shell 自動化

## 撰寫原則

- 以「盡量簡單、可重複執行、不要用進階技巧」為主要要求；保持必要的正確性與錯誤處理。
- 使用繁體中文說明。所有程式碼、程式碼註解及腳本輸出使用英文。預設使用 Bash 並加上 `#!/bin/bash`；使用者指定 POSIX sh 時遵守其語法限制。
- 將使用者需要修改的設定集中放在最上方，例如套件名稱、路徑及時區。不要覆用 HOME、PATH 等系統變數。
- 依執行順序分段，使用清楚的英文註解與簡單 echo 顯示步驟。
- 優先使用一般變數、if/elif/else、簡單 for 迴圈及常見系統指令。讓讀者可以由上往下理解。
- 不主動加入複雜函式框架、關聯陣列、eval、動態產生指令、程序替換、複雜正規表示式、多層巢狀或過長管線。
- 不主動增加選單、參數解析框架、平行執行、自動重試、通知、排程或大量日誌功能。需求確實需要時才加入最小實作。
- 路徑及字串變數使用雙引號；不要把密碼寫死或輸出到畫面。

## 工作流程

1. 先確認使用者要達成的結果及已提供的 OS、版本、Shell 和執行權限。沿用明確的環境資訊，不擅自把所有 Linux 當成 Oracle Linux。
2. 若資訊不足仍可提供有效腳本，使用置頂設定及清楚註明的假設繼續。只有缺少資訊會直接影響正確性時才詢問。
3. 需要 root 才檢查 `id -u`；需要外部指令才使用 `command -v` 檢查。避免與任務無關的檢查。
4. 每項操作採用「檢查目前狀態 → 必要時修改 → 檢查結果」，或使用本身可安全重跑的指令。
5. 關鍵操作使用 `if command; then ... else ... fi` 檢查成功與失敗。必要步驟失敗時清楚顯示原因並 `exit 1`，不要繼續顯示全部成功。不用 `set -e` 代替明確的錯誤處理。
6. 完成後提供完整腳本、簡短執行方式，以及哪些狀態已符合時會略過的說明。

## Oracle 專案參考

- 修改本專案的 Oracle Linux 新機安裝、Oracle Database 19c 安裝、設定來源、安裝步驟狀態判斷或整體重跑邏輯時，必須先完整讀取並遵守 [references/Oracle_New_Server_Install_Rerun_Rules_For_Codex.md](references/Oracle_New_Server_Install_Rerun_Rules_For_Codex.md)。此專案定位為新機安裝工具；固定環境參數來自 `oracle_install.conf`，部署識別參數 `ORACLE_SID` 與 `LISTENER_PORT` 由 DBA 執行時人工輸入，重跑依靠 Marker、Oracle Inventory 與明確狀態，不解析舊設定，也不加入舊環境 Migration、接管、合併或自動修復。
- 修改 Oracle 安裝腳本中的使用者 Profile 管理、`.bash_profile`、`.bashrc`、`.oracle_env`、Host Profile 或 DBA Alias 時，必須先完整讀取並遵守 [references/Oracle_Profile_Simplification_For_Codex.md](references/Oracle_Profile_Simplification_For_Codex.md)。
- 修改 Oracle 安裝腳本中的 `orainstRoot.sh`、`root.sh`、完成 Marker 或安裝重跑判斷時，必須先完整讀取並遵守 [references/Oracle_Root_Script_Rerun_Rules_For_Codex.md](references/Oracle_Root_Script_Rerun_Rules_For_Codex.md)。
- 若同一修改同時涉及上述多個範圍，必須讀取通用的新機安裝規格及所有相關專項參考。通用規格定義共通原則與文件路由；Profile 與 root scripts 專項 Reference 是各自範圍的唯一詳細實作規格。
- 一般 Shell 任務不需要載入這些 Oracle 專案參考。

## 可重複執行的要求

- 第二次執行不得重複新增設定、帳號、排程或其他資源；已符合目標時顯示「已設定，略過」。
- 建目錄可使用 `mkdir -p`。修改設定時先判斷值，避免每次都使用 `>>` 重複附加。
- 修改既有設定檔時保留無關內容；需要備份時採簡單方式保留首次備份，不在每次重跑時覆蓋原始備份。
- 套件安裝使用符合 OS 的套件管理工具，不把「RPM 檔存在」當成「已安裝」。離線情境說明來源及依賴需求，不假設網際網路可用。
- 服務管理區分「目前執行狀態」與「開機啟用狀態」；判斷缺少服務是否可以略過，不能把必要服务缺失當成功。
- 需重開機才生效的設定要區分目前狀態與永久設定，不自動重開機。
- 若工作是新增資料或備份等每次都產生新結果的任務，說明重跑的實際行為，不誤稱完全不變。
- 不自行加入刪除資料、清空磁碟、關閉 SELinux 或防火牆等未要求的操作。

## 驗證與交付

- 有腳本檔及可用環境時，用 `bash -n` 檢查 Bash 語法；POSIX sh 使用相應的語法檢查。
- 檢查首次執行、第二次執行及必要指令失敗三種情境，確認失敗不會回報成功。
- 不為驗證腳本而在目前主機執行套件安裝、服務變更或其他系統設定。只有實際授權且環境正確時才執行這些操作。
- 如只做語法或邏輯檢查，明確說明未在目標主機實測。
- 修改已有腳本時維持原有風格，僅調整需求相關段落；使用者要整合版時提供完整內容。
- 說明保持簡短；必要語法用白話解釋，不加入長篇理論或多種替代版本。
