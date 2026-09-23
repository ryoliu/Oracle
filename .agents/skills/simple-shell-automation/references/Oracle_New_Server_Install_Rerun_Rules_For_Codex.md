# Oracle 新機安裝與可重跑簡化規格

## 目的

本專案只處理 Oracle Linux 新機安裝與 Oracle Database 19c 新安裝。

不處理：
- 舊環境 Migration
- 既有 Oracle Home 接管
- 既有 Profile 合併
- 舊設定自動解析
- 手動安裝到一半後的未知狀態接管

設計目標：
- 簡單
- 可重複執行
- 容易維護
- 容易除錯
- 不使用進階 Shell 技巧
- 固定環境參數由 `oracle_install.conf` 提供
- `ORACLE_SID` 與 `LISTENER_PORT` 由 DBA 執行時人工輸入
- 已完成步驟直接 SKIP
- 未完成步驟才執行

---

## 核心原則

### 1. 固定環境參數與部署識別參數分流

不要從舊 Profile、舊 Oracle Home、舊設定檔反推安裝參數。

固定環境參數統一從 `oracle_install.conf` 取得。

例如：

```bash
ORACLE_BASE=/opt/oracle
ORACLE_HOME=/opt/oracle/product/19.3.0.0/db_1
ORA_INVENTORY=/opt/oraInventory
DATA_DIR=/opt/oracle/oradata
FRA_DIR=/opt/oracle/fast_recovery_area
TIMEZONE=Asia/Taipei
TOTAL_MEMORY_MB=2048
FRA_SIZE_MB=10240
```

各 Script 可直接載入固定環境參數：

```bash
. ./oracle_install.conf
```

部署識別參數不放在 `oracle_install.conf`：

```text
ORACLE_SID
LISTENER_PORT
```

這兩個值由 DBA 每次執行時人工輸入，完成格式與範圍驗證後，再由主安裝 Script 傳給後續步驟。不得從舊 Profile、`/etc/oratab`、舊 Listener 或其他既有設定反推輸入值。

不要再解析舊設定來決定：
- ORACLE_SID
- ORACLE_HOME
- Listener Port
- DATA_DIR
- FRA_DIR
- Database Name
- DB_UNIQUE_NAME

---

### 2. 新機安裝，不做 Migration

本專案的邊界：

```text
全新主機                  → 支援
同一套 Script 重跑        → 支援
安裝失敗後再次重跑        → 支援

舊 Oracle Home            → 不支援
舊 Database               → 不支援
舊 Listener               → 不支援
舊 Profile Migration      → 不支援
舊 Inventory 自動接管      → 不支援
```

遇到不符合預期的舊環境，直接 FAIL。

不要加入複雜邏輯去：
- 猜
- merge
- migrate
- adopt
- repair

---

### 3. 重跑靠狀態判斷，不靠解析舊設定

固定環境參數由 `oracle_install.conf` 提供；`ORACLE_SID` 與 `LISTENER_PORT` 使用 DBA 本次執行時輸入的值。

可重跑靠：

```text
已完成 → SKIP
未完成 → RUN
異常或不一致 → ERROR + exit 1
```

下列 Oracle 資源必須保留明確狀態判斷，不得使用舊 Profile 或舊設定內容代替狀態檢查：

- Oracle Software / `runInstaller`
- `orainstRoot.sh`
- `root.sh`
- Listener
- Database / DBCA

每個建立階段必須有獨立完成狀態。只有該階段成功後才能建立 Marker；Marker 存在但實際狀態不一致時，必須停止，不得自動重做或修復。

---

### 4. Profile 管理

Profile 採固定內容管理，不解析、merge 或 migration 舊 Profile。

涉及以下檔案時：

- `~/.bash_profile`
- `~/.oracle_env`
- `~/.bash_alias`
- `~/.<hostname>.profile`

必須完整讀取並遵守 [Oracle_Profile_Simplification_For_Codex.md](Oracle_Profile_Simplification_For_Codex.md)。該文件是 Profile 載入順序、檔案內容、備份、檔案型態與語法驗證的唯一詳細規格。

---

### 5. Oracle Software 與 root scripts

Oracle Software、`orainstRoot.sh` 與 `root.sh` 必須分別記錄完成狀態，不得因前一階段完成就同時略過後續階段。

```text
Marker + Inventory 正常
→ SKIP

Marker 不存在
→ RUN

Marker 存在但 Inventory 不一致
→ ERROR
```

成功後才建立對應 Marker；失敗時保留現況並停止，不自動重裝或猜測完成狀態。

涉及 `runInstaller`、Oracle Inventory、`orainstRoot.sh`、`root.sh` 或其完成 Marker 時，必須完整讀取並遵守 [Oracle_Root_Script_Rerun_Rules_For_Codex.md](Oracle_Root_Script_Rerun_Rules_For_Codex.md)。該文件是 Marker 路徑、執行順序、驗證與失敗重跑情境的唯一詳細規格。

---

### 6. Listener / Database 的重跑原則

使用兩個獨立 Marker：

```bash
LISTENER_MARKER="$ORACLE_HOME/network/admin/.LSNR_${ORACLE_SID}_complete"
DATABASE_MARKER="$ORACLE_BASE/.DB_${ORACLE_SID}_complete"
```

Marker 只代表對應建立階段已成功，重跑時仍須搭配實際狀態驗證。Marker 必須是 regular file；symbolic link 或 non-regular file 視為異常。

#### Listener

第一次：
```text
Listener 不存在
Port 沒被占用
→ 建立
```

如果是同一套 Script 已經成功建立：
```text
Listener Marker 存在
+ listener.ora 內的 Listener 名稱、Host、Port 一致
+ Listener 可啟動並通過 status 驗證
→ SKIP Listener creation
```

如果 Marker 存在但設定或實際 Listener 狀態不一致：
```text
ERROR + exit 1
```

如果 Marker 不存在但發現 Listener 名稱、Port、程序或設定痕跡：
```text
ERROR + exit 1
```

不要 merge、reuse、接管或自動修復未知 Listener。已完成但目前停止的 Listener 可以啟動後驗證，不重新建立。

#### Database

Database 使用兩個簡單狀態變數控制建立階段：

```bash
LISTENER_REQUIRED="Y"
DATABASE_REQUIRED="Y"
```

判斷原則：

```text
Database Marker 存在
+ /etc/oratab 的 SID 與 Oracle Home 一致
+ spfile 存在
+ Database 可啟動並以 OS authentication 連線
+ Database name 與 open mode 一致
→ DATABASE_REQUIRED=N，SKIP DBCA

Database Marker 存在但實際狀態不一致
→ ERROR + exit 1

Database Marker 不存在
+ 沒有 /etc/oratab、PMON、dbs 檔案及 DATA/FRA 目錄痕跡
→ DATABASE_REQUIRED=Y，RUN DBCA

Database Marker 不存在
+ 已出現任一 Database 痕跡
→ ERROR + exit 1，交由 DBA review
```

Database 建立流程分成三段：

```text
1. Listener creation
2. DBCA creation and basic database verification
3. LOCAL_LISTENER, service registration, connectivity and profile verification
```

`DATABASE_MARKER` 必須在 DBCA 成功，且 `/etc/oratab`、spfile、Database identity、open mode 與 OS authentication 連線驗證完成後立即建立。若第 3 段失敗，下一次重跑略過 DBCA，但仍重新執行 post-configuration and verification。

不要自動刪除失敗 DBCA 留下的檔案，不要修復 `/etc/oratab`，也不要接管未知 Database。這是新機安裝工具，不是 Repair 工具。

---

### 7. Directory 規則

新機模式下：

```text
不存在
→ 建立

存在且符合預期
→ 使用

存在但明顯不符合預期
→ ERROR
```

不要：
- 自動接管未知目錄
- 自動改既有 Oracle Home
- 自動猜舊權限

---

## 修改邊界

- 只修改需求涉及的區段，不順便重構其他功能。
- 不為縮短程式碼而移除失敗處理、語法驗證或基本狀態驗證。
- 不加入 Profile migration、舊設定解析、既有 Oracle 環境接管或自動修復。
- 涉及 Profile 或 root scripts 時，以對應專項 Reference 為唯一詳細實作規格。
- 若總規格與專項 Reference 出現重複細節，應移除總規格中的副本並保留路由，不建立第二份實作規則。
