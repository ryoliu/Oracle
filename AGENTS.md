# Oracle Repository 規則

此 Repository 用於 Oracle Database 安裝自動化。

## 一般規則

- Shell Script 必須保持簡單且容易閱讀。
- Script must be safe to invoke again.
- For this one-time installer, an existing Oracle Software installation must cause a clean stop without modifying the environment.
- Cross-run resume is not supported.
- 除非確實有需要，否則不要使用進階 Shell 技巧。
- 優先採用以下流程：\
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

## Shell 工作

進行 Shell 自動化相關工作時，使用 `simple-shell-automation` Skill。

當工作內容符合 Oracle Reference 文件的適用範圍時，必須遵守對應的 Oracle Reference 文件。
