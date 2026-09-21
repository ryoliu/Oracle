# Oracle 19c 安裝與建庫整合腳本

使用 `oracle_linux_7_8_19c_full_install.sh`，以 root 在 Oracle Linux 7／8 的互動終端執行。只需上傳這支整合腳本，不依賴 `create_oracle_19c_database.sh`；後者仍保留作為獨立建庫工具。

## 執行模式

```bash
# Install software only.
bash oracle_linux_7_8_19c_full_install.sh

# Install software and create a database.
bash oracle_linux_7_8_19c_full_install.sh --create-db

# Also reset the existing oracle OS account password.
bash oracle_linux_7_8_19c_full_install.sh --create-db --set-password

# Show usage without installing anything.
bash oracle_linux_7_8_19c_full_install.sh --help
```

未指定 `--create-db` 時，只進行既有 OS 準備與軟體安裝，不建立 Listener、資料庫、DB alias 或主機 profile 的資料庫區塊。原有 `--la-paz` 參數可繼續使用，將時區改為 America/La_Paz；預設 Asia/Taipei。

## 開始時一次輸入

先確認 root、支援的 OS 與互動終端，然後才收集資料。需要輸入時，主機須已安裝 `dialog`；缺少就停止，不會為了顯示視窗先安裝套件。

| 條件 | 開始時輸入 |
|---|---|
| 尚無 oracle OS 帳號 | OS 密碼及確認密碼 |
| 已有帳號且指定 `--set-password` | 新 OS 密碼及確認密碼 |
| 已有帳號且未指定 `--set-password` | 保留 OS 密碼，不詢問 |
| 指定 `--create-db` | SID、Listener Port、SYS／SYSTEM 共用的 DB 密碼及確認密碼 |

OS 密碼與 DB 密碼分開輸入。取消、密碼不一致、SID／Port 不合法時，會在安裝與系統變更前停止。SID 為 1～8 碼大寫英數，第一碼須為字母；Port 預設 1522，範圍 1024～65535。DB 密碼不得含雙引號或控制字元；OS 密碼不得含換行。密碼另須符合目標環境與 Oracle 的密碼要求。

輸入完成後顯示不含密碼的摘要。路徑、DB_HOST、DB_SERVICE、記憶體、FRA 額度、字元集集中在腳本頂部修改。預設 non-CDB、OMF、NOARCHIVELOG、ASMM 2048 MiB、FRA 10240 MiB、AL32UTF8／AL16UTF16。DB_SERVICE 留空時使用輸入的 SID；自訂值必須對應實際存在的服務，不會自動建立額外服務。

`root.sh` 使用頂部的 `LOCAL_BIN_DIR`，預設 `/usr/local/bin`；遇到既有 dbhome、oraenv、coraenv 時回答不覆寫。這些標準問題不需要中途輸入。SYS／SYSTEM 建庫密碼與最後的 SYSTEM 登入密碼也不會再次詢問。

## 執行順序與身分

1. root 收集並檢查輸入，執行原有 OS 準備、套件與安裝作業；軟體解壓與 Oracle installer 仍以 oracle 執行。
2. root 完成 `orainstRoot.sh`、`root.sh`。軟體安裝或 root scripts 失敗時，不進行建庫。
3. 建庫模式透過 `runuser` 切換 oracle，檢查 Oracle 工具、同名資源、Listener 與 Port 衝突。
4. NETCA 建立 `LSNR_<SID>`，DBCA 使用 `-listeners` 建立 non-CDB。
5. 設定直接 ADDRESS 的 LOCAL_LISTENER，執行 ALTER SYSTEM REGISTER，建立或更新 TNS alias。
6. 執行 Listener、tnsping 與 SYSTEM 實際登入，核對 Instance、Service、Container。READY 狀態由 DBA 查看 Listener 輸出確認。
7. 成功後備份並更新 oracle 的 `$HOME/.$(hostname).profile`：

```bash
# BEGIN ORACLE DATABASE SETTINGS
export ORACLE_SID="TESTDB"
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
# END ORACLE DATABASE SETTINGS
```

TNS 更新保留其他 alias，profile 更新保留其他設定；備份沿用 `.pre_create.bak`、`.pre_alias.bak`、`.pre_db.bak`，不覆寫首次備份。

## 密碼與失敗處理

OS 密碼僅透過標準輸入交給 `chpasswd`。DBCA 使用暫存 response file，SQL*Plus 使用暫存登入檔；密碼不作為程序命令列參數，不出現在設定摘要，也不寫入 profile。

暫存憑證目錄權限為 700、檔案為 600，交給 oracle 使用。正常結束、失敗及可捕捉的 INT／TERM 中斷會清除檔案。強制斷電或 SIGKILL 無法執行清理；必要時由 DBA 檢查本次遺留的 `/tmp/oracle_db_credentials.*` 目錄。

任一步驟失敗即停止，保留已安裝軟體與已建立資料。安裝成功紀錄與 Inventory 一致時沿用原有略過安裝規則；同名資料庫、檔案或 Listener 已存在時停止，不自動重建。建庫失敗後應查看階段訊息及 Oracle 日誌，依 SOP 手動完成或處理殘留，不要直接重跑期待自動修復。

整合版保留原腳本的 OS 行為，包括 SELinux、防火牆、時區與 shell startup 設定；不會自動重新開機。OL8 沿用 CV_ASSUME_DISTID=OL7，不含 RU 套用或認證檢查。此流程不適用 Grid Infrastructure／Oracle Restart 管理的 Listener。

## 驗證範圍

本機驗證 Bash 語法與離線模擬，涵蓋模式選擇、集中輸入、失敗停止、密碼轉義與清理、TNS／profile 保留及重跑保護。OS 安裝與 Oracle 工具均以替身模擬；Windows 測試只能確認有要求 Linux 所需權限，不能證明 Linux 實際權限效果。

尚未在目標主機實際執行安裝、DBCA 或遠端連線。完整建庫規則見 [Oracle_DB_Creation_SOP.md](Oracle_DB_Creation_SOP.md)。

2026-09-22 已在 Oracle Linux 7 Docker 容器直接執行本整合腳本的兩種模式；皆因 `sysctl --system` 無法寫入容器核心參數而停止，未進入 Oracle 軟體安裝及建庫。完整結果及重跑指令見 [Docker 實測紀錄](tests/docker/FULL_INSTALL_TEST_RESULT.md)。完整 OS 至建庫流程仍需獨立 Oracle Linux VM 驗證。
