# Oracle Database 19c Installer for Oracle Linux 8

這個專案用於在 Oracle Linux 8.x 上安裝 Oracle Database 19c 19.3 Base Software，並可選擇建立 single-instance non-CDB。

所有 Script 都由 `root` 啟動，固定環境設定由 `oracle_install.conf` 提供。`ORACLE_SID` 與 Listener Port 必須由 DBA 在執行時指定，不會從既有環境自動推測。

## 執行流程

```text
PreCheck
    -> Main
        -> PostCheck
```

- `oracle_linux_8_19c_precheck.sh`：read-only 安裝前檢查，也可獨立檢查新的 SID 與 Listener target。
- `oracle_linux_8_19c_full_install.sh`：安裝 Oracle Software，並依選項建立 Database。
- `oracle_linux_8_19c_postcheck.sh`：read-only Database health check，內部切換成設定的 Oracle owner 執行 Oracle commands。

三支 Script 與 `oracle_install.conf` 必須放在同一個目錄。

## 安裝前設定

先檢查 `oracle_install.conf`，確認 Oracle Software media、Oracle Home、Inventory、storage path、memory 與 character set 符合目標主機。

本專案只支援 Oracle Linux 8.x，不支援 Oracle Linux 7、Oracle Linux 9、RHEL、Rocky Linux、AlmaLinux、CentOS 或其他 Linux distribution。

## PreCheck

全新 Oracle Software 安裝前檢查：

```bash
bash oracle_linux_8_19c_precheck.sh
```

檢查新的 SID 與 Listener target：

```bash
bash oracle_linux_8_19c_precheck.sh \
    --target-only \
    --allow-complete-software \
    --sid ORCL \
    --listener-port 1521
```

顯示完整參數：

```bash
bash oracle_linux_8_19c_precheck.sh --help
```

PreCheck 不會安裝套件、修改設定、建立目錄、啟動服務或建立 Oracle resources。

## Main

### Software-only

只安裝 Oracle Software，不建立 Database：

```bash
bash oracle_linux_8_19c_full_install.sh
```

### 安裝 Software 並建立 Database

```bash
bash oracle_linux_8_19c_full_install.sh --create-db
```

Main 會在 PreCheck 通過後詢問 SID、Listener Port 及必要密碼，再依序完成 Software、root scripts、Listener、DBCA 與 PostCheck。

### 使用既有的完整 Software 建立新 Database

如果 Oracle Software 已由本專案完整安裝，且 Inventory、Installer Marker、兩個 root-script Marker 與必要 Oracle tools 全部驗證通過，可以再次執行：

```bash
bash oracle_linux_8_19c_full_install.sh --create-db
```

此模式只略過 Software 與 root-script 階段，仍會要求新的 SID 與未使用的 Listener Port。這是 Database-only provisioning，不是未完成安裝的續跑。

## PostCheck

驗證既有且由本專案管理的 Database：

```bash
bash oracle_linux_8_19c_postcheck.sh \
    --sid ORCL \
    --listener-port 1521
```

`DB_HOST` 預設使用 `hostname -f`，`DB_SERVICE` 預設與 SID 相同。PostCheck 會要求輸入 SYSTEM password，並依序檢查：

1. Listener status 與 endpoint。
2. Service 與 READY instance registration。
3. SYSTEM Easy Connect。
4. SYSDBA database identity 與 OPEN status。

顯示完整參數：

```bash
bash oracle_linux_8_19c_postcheck.sh --help
```

## Partial state policy

本專案不支援未完成 Oracle Software 安裝的跨次續跑。

```text
NEW
    -> 允許完整安裝

COMPLETE + --create-db
    -> 允許略過 Software，建立新的 Database

COMPLETE without --create-db
    -> 停止

PARTIAL / UNKNOWN / INCONSISTENT
    -> 停止並交由 DBA review
```

Script 不會自動補跑 root scripts、修復 Oracle Home、接管未知 Inventory、刪除既有 Database artifacts，或重用既有 SID、Listener Name 與 Listener Port。

## 靜態檢查

執行：

```bash
bash tests/static_checks.sh
```

測試一定會對三支主要 Script 執行 `bash -n`。如果主機有安裝 ShellCheck，會再執行 ShellCheck；沒有安裝時會顯示 SKIP，不會因此失敗。
