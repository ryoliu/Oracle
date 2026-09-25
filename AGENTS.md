# Oracle Repository 規則

此 Repository 用於 Oracle Database 安裝自動化。

## 一般規則

- Shell Script 必須保持簡單且容易閱讀。
- 腳本必須可以安全地再次執行。
- 對於本專案的一次性 Oracle Installer，「可安全再次執行」表示再次呼叫時，會先檢查既有 Oracle 安裝狀態；若在本次執行開始前已存在目標 Oracle Software，必須乾淨地停止，且不得修改現有環境。
- 可安全再次執行不代表支援跨次續跑、跳過已完成階段後繼續，或自動修復部分完成的安裝。
- 不支援跨次執行續跑（resume）。
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
- PreCheck 與 Main Script 必須在修改系統、建立目錄、修改 Profile、安裝套件或啟動 Oracle Installer 前先確認 OS。
- 若目前主機不是 Oracle Linux 8，必須清楚顯示實際偵測到的 OS / Version，然後 `exit 1`；不得只顯示 warning 後繼續。
- 不要使用 `CV_ASSUME_DISTID` 或其他方式把非 Oracle Linux 8 的主機偽裝成受支援的 OS，以繞過專案的 OS 限制。
- OS 檢查應保持簡單，優先使用 Oracle Linux 自帶的 release 資訊，例如 `/etc/oracle-release` 或 `/etc/os-release`；不要為了支援其他 distribution 加入額外相容邏輯。
- 此 OS 限制只定義 Distribution / Major Version 範圍；Architecture、Kernel、Memory、Swap、Disk、Package 與 Oracle prerequisite 仍由各自的 PreCheck 規則判斷。

## Oracle 安裝範圍

此專案只用於全新的 Oracle 安裝。

不要自動加入以下功能：

- Migration
- 接管未知的 Oracle Home
- 解析舊版 Profile
- 合併既有設定
- 自動修復未知或不明確的既有環境

本次 Main Script 自行成功安裝 Oracle Software 後，可以繼續執行同一次安裝流程中的 root scripts、Listener、Database 與 PostCheck。這不屬於跨次續跑。

## Shell 工作

進行 Shell 自動化相關工作時，使用 `simple-shell-automation` Skill。

當工作內容符合 Oracle Reference 文件的適用範圍時，必須完整讀取並遵守對應的 Oracle Reference 文件。

Oracle 專案的特定 Reference 規則優先於一般 Shell 可重跑規則，但不得放寬本檔定義的 Oracle Linux 8 支援範圍。