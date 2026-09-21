# Oracle 19c 整合腳本 Docker 實測

測試日期：2026-09-22。目標為原始 `oracle_linux_7_8_19c_full_install.sh`，未替換命令、刪除 OS 段落或新增安裝完成標記。

## 環境與方法

- Docker Desktop Linux containers，`oraclelinux:7-slim`。
- 容器 `oracle19c-full-install-test`，4 GiB 記憶體、1 GiB `/dev/shm`，非 privileged。
- 唯讀掛載工作區及 Oracle 19.3 ZIP，未使用先前已安裝 Oracle 的容器。
- 預先只安裝 dialog、expect、hostname 及其依賴，Oracle preinstall 套件由受測腳本自行安裝。
- `run-full-install.exp` 提供真實 PTY 操作 dialog，密碼在容器內隨機產生，不作為命令列參數。

## 結果

| 執行 | 結果 |
| --- | --- |
| 預設軟體模式，首次執行 | 輸入及確認新 oracle OS 密碼，安裝 preinstall 套件後回傳 1 |
| 預設軟體模式，再次執行 | 使用已存在帳號、不再要求 OS 密碼，回傳 1 |
| `--create-db` | 完成 SID、Port、DB 密碼及確認視窗，回傳 1 |

三次均停止於第 6 步 `sysctl --system`。保留的兩份日誌分別是軟體模式再次執行及建庫模式；首次執行未成功保存終端輸出。

```text
sysctl: setting key "fs.file-max": Read-only file system
sysctl: setting key "kernel.sem": Read-only file system
sysctl: setting key "fs.aio-max-nr": Read-only file system
Failed to apply kernel parameters.
ERROR: Stopped during software installation. Existing installation and database resources were retained.
```

確認 Oracle Home 與資料庫資料目錄未建立、未產生 DB 憑證暫存目錄。這驗證了目前失敗點會停止流程，不能視為安裝及建庫成功。

容器內日誌 `/tmp/full-install-software.log`、`/tmp/full-install-database.log` 權限 600，包含終端控制碼。測試未修改正式腳本。

## 重跑

在同一測試容器內：

```powershell
docker exec oracle19c-full-install-test bash -c 'umask 077; expect /workspace/tests/docker/run-full-install.exp software'
docker exec oracle19c-full-install-test bash -c 'umask 077; expect /workspace/tests/docker/run-full-install.exp database'
```

這兩個指令會實際執行 OS 設定，只能用於拋棄式測試容器。此環境預期仍會停在 sysctl。

## 完整驗證尚缺項目

本次沒有驗證整合腳本的 runInstaller、root scripts、NETCA、DBCA、SQL 登入、TNS 及 profile 更新。另一個 `oracle19c-shell-lab` 容器已由測試輔助腳本完成軟體安裝，其成功不能代替整合腳本測試結果。

完整測試應使用獨立 Oracle Linux 7／8 VM，提供可設定的核心參數、SELinux 與 systemd；使用原始整合脚本分別測試軟體及建庫模式。不要為通過 Docker 測試而略過正式腳本的 OS 設定或偽造命令成功。
