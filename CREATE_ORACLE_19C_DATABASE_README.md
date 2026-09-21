# Oracle 19c 建庫腳本

`create_oracle_19c_database.sh` 依新版 SOP 建立單機 non-CDB；Oracle 軟體須已安裝，Listener 不由 Grid Infrastructure／Oracle Restart 管理。

若需從軟體安裝一路完成建庫，請使用單一整合入口，參考 [安裝與建庫整合說明](ORACLE_19C_FULL_INSTALL_README.md)。本文件仍適用於獨立建庫腳本。

## 執行方式

1. 依需求修改 `DB_SERVICE`、`DB_HOST`、`LISTENER_PORT`、資料根目錄與記憶體配置。`DB_SERVICE` 留空時使用輸入的 SID。
2. 將腳本上傳目標 Linux 主機，以 `oracle` 帳號在互動終端執行：

```bash
bash create_oracle_19c_database.sh
```

執行後先跳出終端機輸入視窗，讓使用者輸入 `ORACLE_SID`，不再固定使用 TESTDB。主機須提供 `dialog`；取消或輸入不合法的 SID 時停止，不進行建庫。SID 為 1～8 碼大寫英文字母或數字，且以字母開頭。

接著依 DBCA 提示輸入 SYS／SYSTEM 密碼；最後 SQL*Plus 會再次提示 SYSTEM 密碼以測試連線，密碼不寫入腳本。

`DB_NAME`、`DB_UNIQUE_NAME` 使用輸入的 SID，Listener 為 `LSNR_<SID>`。預設埠 1522、ASMM 2048 MiB、FRA 10 GiB。DB_SERVICE 可獨立指定，但必須是建庫後實際存在的服務，此設定不會建立自訂服務。DB_HOST 預設取 hostname -f，須與 NETCA 實際建立的 Listener endpoint 一致，並能從用戶端解析及到達。

建庫與連線驗證成功後，更新 Oracle 使用者的 `$HOME/.$(hostname).profile`，沿用目前登入設定載入的隱藏檔名稱。例如輸入 TESTDB 時，保存：

```bash
# BEGIN ORACLE DATABASE SETTINGS
export ORACLE_SID="TESTDB"
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
# END ORACLE DATABASE SETTINGS
```

使用固定標記區塊管理這三個變數，保留其他 profile 內容。舊版的單行變數設定會移入區塊，修改前保留首次 `.pre_db.bak` 備份，並檢查 Bash 語法。遇到無法安全辨識的複合指令、多行變數設定或不完整的標記時停止，保留原檔。新設定於後續登入生效，不會改變呼叫腳本的父 shell。

## 執行流程

- 執行前檢查名稱、檔案、埠及 Oracle 工具，顯示可用記憶體供 DBA 評估。
- 使用安裝目錄的 `netca.rsp` 範本，由 NETCA 建立並啟動 `LSNR_<SID>`；不使用 NETCA 新增 DB connection alias。
- DBCA 使用 `-listeners` 指定該 Listener，建立 non-CDB。
- LOCAL_LISTENER 設定為直接 ADDRESS，執行 ALTER SYSTEM REGISTER。1521 也明確指定 ADDRESS，避免沿用錯誤 alias；服務是否正確由最後的實際登入核對。
- 檢查 DBCA 產生的 tnsnames.ora；alias 正確則保留，不存在則新增，設定不符則只更新該項目。
- 執行 lsnrctl status、lsnrctl services、tnsping。DBA 需查看輸出，確認目標服務及 Instance 為 READY；腳本不再解析 Listener 狀態文字。
- SQL*Plus 使用 `system@<SID>` 登入，自動查詢並核對 Instance、Service 及 Container；任一步驟失敗即停止。

## 既有設定與重跑規則

**新增或更新對應項目，不要覆蓋整份既有檔案。**

網路設定檔在 assistants 執行前保留首次 .pre_create.bak；alias 實際修改前另保留首次 .pre_alias.bak。更新器按括號層級讀取完整項目，保留其他 alias，使用同一檔案系統的暫存檔替換。正確 alias 不修改，備份不覆寫。

為避免誤改，更新器遇到 IFILE、引號、跳脫字元、未閉合括號、重複目標 alias，或目標與其他名稱共用同一項目時，會停止並要求人工處理，保留更新前的檔案。Shell 更新器不支援所有 Oracle Net 語法。

整份腳本不是既有資料庫的修復工具。同名 DB、資料檔、目錄或 Listener 已存在就停止，不重建、不清除。建庫中途失敗會保留資源；請檢查失敗原因並依 SOP 完成剩餘步驟，不要直接重跑建庫。TNS 更新段本身可重複執行。

OMF 分庫建立目錄，例如 /opt/oracle/oradata/TESTDB。不同資料庫使用不同埠。記憶體僅顯示可用值與配置值，不再因額外 512 MiB 門檻停止；DBA 應預留 OS 與其他資料庫所需容量。磁碟容量與遠端防火牆需在執行前確認。

## 驗證範圍

本機僅執行 Bash 語法與離線模擬測試；未在目標 Oracle 主機實際執行 NETCA、DBCA 或遠端連線。

參考完整規則：[Oracle_DB_Creation_SOP.md](Oracle_DB_Creation_SOP.md)。
