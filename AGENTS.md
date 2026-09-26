# Oracle Repository 規則

此 Repository 用於 Oracle Database 安裝自動化。

## 一般規則

- Shell Script 必須保持簡單且容易閱讀。
- 腳本必須可以安全地再次執行。
- 對於本專案的一次性 Oracle Installer，「可安全再次執行」表示再次呼叫時，會先檢查既有 Oracle 安裝狀態。若 Oracle Software 尚未安裝，執行完整的新機安裝流程；若指定 `--create-db`，且 Software 經 Inventory、Installer Marker、兩個 root-script Marker 與必要 Oracle tools 驗證為本專案完整安裝的狀態，允許略過 Software 階段建立新的 Database。其他既有、部分完成、未知或不一致狀態必須乾淨地停止。
- 可安全再次執行不代表支援一般性的跨次續跑、任意跳過已完成階段，或自動修復部分完成的安裝；唯一例外是上述完整驗證後的 `--create-db` Database-only 流程。
- 不支援未完成安裝的跨次續跑（resume）。已驗證完整 Software 的 `--create-db` Database-only 流程不是 Software resume，不得補跑 root scripts、修復 Software 或接管未知 Oracle Home。
- 除非確實有需要，否則不要使用進階 Shell 技巧。
- 優先採用以下流程：  
  檢查目前狀態 → 必要時修改 → 驗證結果。
- 不要只為了縮短程式碼而移除驗證或錯誤處理。
- 只修改與目前需求相關的程式碼。
- 不要順便重構與目前需求無關的區段。

## 支援的作業系統

此專案只支援 **Oracle Linux 8.x（OEL8 / OL8）**。

- Oracle Linux 8 的所有 minor release 都屬於此專案範圍；除非需求另外指定，不要把支援範圍寫死為單一版本（例如 8.8）。
- Oracle Linux 7、Oracle Linux 9、RHEL、Rocky Linux、AlmaLinux、CentOS 及其他 Linux distribution 均不屬於支援範圍。

## Oracle 安裝範圍

此專案只用於全新的 Oracle 安裝。

不要自動加入以下功能：

- Migration
- 接管未知的 Oracle Home
- 解析舊版 Profile
- 合併既有設定
- 自動修復未知或不明確的既有環境

本次 Main Script 自行成功安裝 Oracle Software 後，可以繼續執行同一次安裝流程中的 root scripts、Listener、Database 與 PostCheck。指定 `--create-db` 時，也可以在通過完整 Software hard gate 後，對本專案管理的既有 Oracle Home 執行 Database-only 流程。兩者都不得用於接管未知環境或續跑未完成的 Software 安裝。

## Shell 工作

進行 Shell 自動化相關工作時，使用 `simple-shell-automation` Skill。

當工作內容符合 Oracle Reference 文件的適用範圍時，必須完整讀取並遵守對應的 Oracle Reference 文件。

Oracle 專案的特定 Reference 規則優先於一般 Shell 可重跑規則，但不得放寬本檔定義的 Oracle Linux 8 支援範圍。
