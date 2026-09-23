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

例如：

```text
runInstaller
→ INSTALL_MARKER

orainstRoot.sh
→ ORAINST_ROOT_MARKER

root.sh
→ ROOT_SH_MARKER
```

建議：

```bash
EXTRACT_MARKER="$ORACLE_HOME/.oracle_19c_extraction_complete"
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
```

---

### 4. Profile 固定內容覆寫，不做 Migration

安裝 Script 直接管理並覆寫下列 Profile 類檔案：

- `~/.bash_profile`
- `~/.oracle_env`
- `~/.bash_alias`
- `~/.<hostname>.profile`

每個檔案都必須遵守：

1. 既有路徑若為 symbolic link 或 non-regular file，立即顯示 `ERROR` 並 `exit 1`。
2. 第一次覆寫前備份既有 regular file，重跑時不得覆蓋首次備份。
3. 通過檔案型態檢查後，直接覆寫專案定義的標準內容。
4. 寫入後對每個檔案執行 `bash -n`；驗證失敗時立即 `exit 1`。
5. 不解析舊內容、不 merge 舊設定，也不做 Profile Migration。

#### Save database settings in the host profile

`~/.<hostname>.profile` 由安裝 Script 完整管理。這一段不得使用：

- `PROFILE_INPUT`
- `PROFILE_TEMP`
- `mktemp`
- `awk`
- BEGIN / END managed block
- 舊 `ORACLE_SID`、`DB_NAME` 或 `DB_UNIQUE_NAME` 解析
- Migration 或 merge 舊設定
- `cmp`

保留檔案型態檢查與第一次備份，然後直接覆寫固定內容：

```bash
HOST_PROFILE="$HOME/.$(hostname).profile"
HOST_PROFILE_BACKUP="$HOST_PROFILE.pre_oracle_install.bak"

if [ -L "$HOST_PROFILE" ]; then
    echo "ERROR: Host profile must not be a symbolic link: $HOST_PROFILE"
    exit 1
fi

if [ -e "$HOST_PROFILE" ] && [ ! -f "$HOST_PROFILE" ]; then
    echo "ERROR: Host profile is not a regular file: $HOST_PROFILE"
    exit 1
fi

if [ -f "$HOST_PROFILE" ] && [ ! -e "$HOST_PROFILE_BACKUP" ]; then
    if ! cp -p "$HOST_PROFILE" "$HOST_PROFILE_BACKUP"; then
        echo "ERROR: Failed to back up host profile: $HOST_PROFILE"
        exit 1
    fi
fi

if ! cat > "$HOST_PROFILE" <<EOF; then
export ORACLE_SID="$ORACLE_SID"
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
EOF
    echo "ERROR: Failed to write host profile: $HOST_PROFILE"
    exit 1
fi

if ! bash -n "$HOST_PROFILE"; then
    echo "ERROR: Host profile syntax validation failed."
    exit 1
fi
```

只有第一次遇到既有 regular file 時建立備份；後續重跑不得覆蓋該備份。每次重跑直接再次覆寫相同內容並執行 `bash -n`，不讀取或解析舊 Profile。

核心行為：

```text
.<hostname>.profile
→ 直接覆寫
→ bash -n 驗證
→ 重跑結果一致
```

這項修改只適用於 Host Profile 區段，不得順便重構其他安裝功能。

---

### 5. Profile 載入流程保持簡單

建議：

```text
.bash_profile
      ↓
.oracle_env
      ↓
.<hostname>.profile
      ↓
.bash_alias
```

`.bash_profile`：

```bash
if [ -f "$HOME/.oracle_env" ]; then
    . "$HOME/.oracle_env"
fi
```

`.oracle_env`：

```bash
umask 022

export ORACLE_BASE=/opt/oracle
export ORACLE_HOME=/opt/oracle/product/19.3.0.0/db_1
export LD_LIBRARY_PATH=$ORACLE_HOME/lib
export PATH=$ORACLE_HOME/bin:$PATH
export EDITOR=vi

HOST_PROFILE="$HOME/.$(hostname).profile"

if [ -f "$HOST_PROFILE" ]; then
    . "$HOST_PROFILE"
fi

if [ -f "$HOME/.bash_alias" ]; then
    . "$HOME/.bash_alias"
fi
```

不要使用：
- ORACLE_ENV_LOADING
- ORACLE_ENV_SHELL_PID
- BASHPID recursion guard

除非真的有 recursive source 問題。

---

### 6. Software 安裝可重跑

不要每次重跑 `runInstaller`。

簡單判斷：

```bash
if [ -f "$INSTALL_MARKER" ] &&
   [ -f "$INVENTORY_FILE" ] &&
   grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then

    echo "Oracle software already installed. Skip."
else
    # runInstaller
fi
```

原則：

```text
Marker + Inventory 正常
→ SKIP

Marker 不存在
→ RUN

Marker 存在但 Inventory 不一致
→ ERROR
```

不要自動重裝或猜狀態。

---

### 7. orainstRoot.sh 可重跑

```bash
if [ -f "$ORAINST_ROOT_MARKER" ]; then
    echo "orainstRoot.sh already completed. Skip."
else
    if ! "$ORA_INVENTORY/orainstRoot.sh"; then
        echo "ERROR: orainstRoot.sh failed."
        exit 1
    fi

    touch "$ORAINST_ROOT_MARKER"
fi
```

成功才建立 Marker。

---

### 8. root.sh 可重跑

```bash
if [ -f "$ROOT_SH_MARKER" ]; then
    echo "root.sh already completed. Skip."
else
    if ! "$ORACLE_HOME/root.sh" <<ROOT_SCRIPT_INPUT
$LOCAL_BIN_DIR
n
n
n
ROOT_SCRIPT_INPUT
    then
        echo "ERROR: root.sh failed."
        exit 1
    fi

    touch "$ROOT_SH_MARKER"
fi
```

成功才建立 Marker。

---

### 9. Listener / Database 的重跑原則

#### Listener

第一次：
```text
Listener 不存在
Port 沒被占用
→ 建立
```

如果是同一套 Script 已經成功建立：
```text
可用自己的 Marker 或明確狀態判斷 SKIP
```

如果發現未知 Listener：
```text
ERROR
```

不要做 merge 或 reuse。

#### Database

Database 建立前：

```bash
if grep -q "^$ORACLE_SID:" /etc/oratab 2>/dev/null; then
    echo "Database already exists. Skip."
else
    # dbca
fi
```

更嚴謹時可再搭配：
- PMON
- spfile
- password file
- data directory

但不要加入 Migration 邏輯。

---

### 10. Directory 規則

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

## Codex 修改要求

請依以下原則簡化 Oracle 安裝 Script：

1. 本專案只支援全新主機安裝。
2. 不支援舊 Oracle 環境 Migration。
3. 固定環境參數統一來自 `oracle_install.conf`。
4. 部署識別參數 `ORACLE_SID` 與 `LISTENER_PORT` 必須由 DBA 執行時人工輸入，完成驗證後再傳給後續步驟。
5. 不再從舊 Profile 或舊 Oracle 設定反推參數。
6. 移除不必要的：
   - Profile migration
   - managed block parser
   - 舊 assignment parser
   - merge 舊設定
   - legacy compatibility logic
7. Profile 可直接以固定內容覆蓋。
   - `~/.bash_profile`
   - `~/.oracle_env`
   - `~/.bash_alias`
   - `~/.<hostname>.profile`
   - 修改前保留第一次備份。
   - 拒絕 symbolic link 與 non-regular file。
   - 寫入後逐一執行 `bash -n`。
   - 不解析、merge 或 migration 舊內容。
8. 重跑能力必須保留。
9. 重跑依靠：
   - Marker
   - Oracle Inventory
   - 明確 Oracle 狀態
   - Oracle Software / `runInstaller`
   - `orainstRoot.sh`
   - `root.sh`
   - Listener
   - Database / DBCA
10. 已完成步驟 → SKIP。
11. 未完成步驟 → RUN。
12. 異常、不一致或未知舊環境 → `ERROR` 並 `exit 1`。
13. 不要加入自動 Migration 或自動修復。
14. 不要為了縮短程式碼刪除必要的：
   - 失敗 `exit 1`
   - 語法驗證
   - 基本狀態驗證
15. 不使用進階 Shell 技巧。
16. 優先保持：
   - 簡單
   - 可讀
   - 可重複執行
   - 容易維護
17. 只修改需求涉及的必要區段，不順便重構其他功能。

---

## DBA 簡單摘要

這套 Script 的定位：

```text
新機安裝工具
```

不是：

```text
Oracle Migration / Repair 工具
```

固定環境參數統一從：

```text
oracle_install.conf
```

取得；部署識別參數則由 DBA 執行時輸入：

```text
ORACLE_SID
LISTENER_PORT
```

Script 不再：
- 讀舊 Profile
- 猜舊 SID
- merge 舊設定
- migration 舊 Oracle Home

可重跑則靠：

```text
完成過的步驟 → SKIP
沒完成的步驟 → RUN
```

例如：

```text
runInstaller 完成
→ 下次 SKIP

orainstRoot.sh 完成
→ 下次 SKIP

root.sh 完成
→ 下次 SKIP
```

核心原則：

```text
Profile      → 直接覆寫
固定設定     → oracle_install.conf
SID / Port   → DBA 人工輸入
Oracle 資源  → 已完成 SKIP，未完成 RUN，異常 ERROR
```

支援重跑，不支援 Migration；只修改必要區段，不順便重構其他功能。
