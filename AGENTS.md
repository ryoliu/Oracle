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

Oracle 專案的特定 Reference 規則優先於一般 Shell 可重跑規則。