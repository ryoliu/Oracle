# Oracle 新機安裝與停止規格

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
- 可安全再次呼叫；偵測到既有 Oracle Software 時立即停止
- 容易維護
- 容易除錯
- 不使用進階 Shell 技巧
- 固定環境參數由 `oracle_install.conf` 提供
- `ORACLE_SID` 與 `LISTENER_PORT` 由 DBA 執行時人工輸入
- Oracle Software 已安裝時立即停止
- 只有 Oracle Software 尚未安裝時才允許繼續新安裝

---

## 測試版 Patch 範圍

目前測試版只使用 Oracle Database 19c 19.3 Base Media：

```text
LINUX.X64_193000_db_home.zip
```

目前測試環境沒有可用的 Oracle Release Update（RU）與新版 OPatch 安裝檔，因此不要在測試版加入：

- RU Patch ZIP 或 OPatch Patch ZIP 的設定及下載流程
- OPatch 更新
- RU 解壓
- `runInstaller -applyRU`
- RU 或 OPatch completion Marker
- `opatch lspatches`、`opatch lsinventory` 或其他 RU 套用結果驗證

這個測試版只用於驗證 19.3 Base Media 的安裝流程、重跑狀態、Listener、DBCA、PreCheck 與 PostCheck，不是正式環境的 Patch 或認證基準。

Oracle Linux 8 的 Bug 29772579 例外必須維持原有限制：只有確認 Oracle Linux 8 缺少 `compat-libcap1` 時，才允許對 19.3 Base Installer 加入 `-ignorePrereqFailure`。這項限制只約束選項的啟用條件；`-ignorePrereqFailure` 本身會讓 OUI 忽略所有 prerequisite check failures，無法限定只忽略 `compat-libcap1`。

專案 PreCheck 可降低已知的 OS、Architecture、Kernel、Memory、Swap、Filesystem 與 Package 風險，但不能取代或完整重現 OUI prerequisite engine，也不得宣稱其他 OUI prerequisite failures 一定已解決。OUI 回傳 exit code `6` 時，必須清楚警告 DBA：安裝是在忽略 prerequisite results 後完成，且必須人工檢查 Oracle Installer log；不能把 code `6` 描述成只忽略 Bug 29772579。

不得在其他 OS、其他缺少套件或一般 prerequisite failure 情境中啟用此選項，也不要加入脆弱的 Installer log parsing 來自動宣稱只有 `compat-libcap1` 失敗。

未來取得 RU 與 OPatch 安裝檔後，必須先由 DBA 明確要求加入 Patch 流程，並先更新本 Reference，再設計 OPatch 更新、RU 解壓、`-applyRU`、Marker 與 Patch Inventory 驗證。不得因 Oracle 文件存在 RU 安裝方式，就自動把 RU 功能加入目前測試版。

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

只有確認 Oracle Software 尚未安裝後，才由 DBA 人工輸入這兩個值，完成格式與範圍驗證後，再由主安裝 Script 傳給後續步驟。不得從舊 Profile、`/etc/oratab`、舊 Listener 或其他既有設定反推輸入值。

不要再解析舊設定來決定：
- ORACLE_SID
- ORACLE_HOME
- Listener Port
- DATA_DIR
- FRA_DIR
- Database Name
- DB_UNIQUE_NAME

`oracle_install.conf` 也是 Oracle Inventory path 與 group 的唯一設定來源。`/etc/oraInst.loc` 若已存在，只能用來驗證 `inventory_loc` 與 `inst_group` 是否分別等於設定檔的 `ORA_INVENTORY` 與 `ORACLE_GROUP`；不得用既有值覆寫設定變數或接管其他 Inventory。不一致時立即停止。

---

### 2. 新機安裝，不做 Migration

本專案的邊界：

```text
全新主機                  → 支援
Software 安裝前重跑       → 支援
Software 已安裝後重跑     → 不支援，立即停止

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

### 3. Oracle Software 是第一個停止條件

固定環境參數由 `oracle_install.conf` 提供；`ORACLE_SID` 與 `LISTENER_PORT` 使用 DBA 本次執行時輸入的值。

PreCheck 必須先判斷 Oracle Software 是否已安裝。這項檢查必須位於 SID、Listener Port、作業系統密碼及 Database 密碼輸入之前。只要確認 Oracle Software 已安裝，就立即 `ERROR + exit 1`，不得把 Software 階段設為 SKIP 後繼續執行。

判斷順序固定為：

```text
Oracle Software 已安裝
→ STOP
→ 不做額外檢查

Oracle Software 未安裝
→ 才檢查 SID、Listener Name 與 Listener Port
```

偵測到 Oracle Software 已安裝後，不得再檢查或處理：

- RU
- OPatch
- `orainstRoot.sh`
- `root.sh`
- Listener
- Database
- Profile
- PostCheck

不再允許：

```text
Software 已安裝
→ SKIP software
→ 繼續建 Listener / Database
```

Oracle Inventory 已有目標 `ORACLE_HOME`、Installer completion Marker 存在，或其他既有判斷已足以確認目標 Software 安裝完成時，都必須立即停止。停止後不得為了判斷是否可以接續而再驗證其他階段。

如果 Software 尚未安裝，但發現 Oracle Home、Inventory 或 Marker 處於未知、部分完成或不一致狀態，同樣立即停止，交由 DBA 處理；不得自動重裝、修復或接管。

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

`orainstRoot.sh` 與 `root.sh` 只屬於同一次全新安裝流程。它們可以在本次 Main Script 中依序執行並於成功後記錄 Marker，但不得用於下一次執行的續跑判斷。

```text
本次 runInstaller 成功
→ 執行 orainstRoot.sh
→ 執行 root.sh

下一次執行偵測到 Software 已安裝
→ 立即 STOP
→ 不檢查 orainstRoot.sh 或 root.sh Marker
```

不得使用 `INSTALL_REQUIRED=N`、Installer Marker 或 Inventory 將 Software 階段設成 SKIP，再繼續執行任何 root script、Listener 或 Database 工作。

可以保留下列 Marker 作為稽核與衝突證據：

```bash
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
```

只有對應步驟成功後才能建立 Marker。Marker 不代表下一次執行可以 SKIP 該階段並繼續；下一次執行只要確認 Oracle Software 已安裝，就立即停止，不得再檢查 root-script Marker。

不允許：

- 使用 `INSTALL_REQUIRED=N` 繼續後續安裝階段。
- 因 `ORAINST_ROOT_MARKER` 或 `ROOT_SH_MARKER` 不存在而補跑 root scripts。
- 使用 `/etc/oraInst.loc`、`/etc/oratab` 或 `oraenv` 判斷是否可以續跑。
- 自動刪除 Oracle Home、Inventory 或 Marker。
- 自動重裝、修復或接管既有 Oracle Software。

---

### 6. SID / Listener / Database 衝突規則

以下檢查只有在 Oracle Software 尚未安裝時才執行。Software 已安裝時，必須在進入 SID／Listener 檢查之前停止。

#### ORACLE_SID 不得重複使用

如果下列任一狀態存在，立即停止：

```text
/etc/oratab 已有相同 SID
PMON 已有相同 SID
$ORACLE_HOME/dbs 已有該 SID 的 spfile、pfile、password file 或 lock file
DATA_DIR 已有該 SID 的資料目錄或檔案
FRA_DIR 已有該 SID 的目錄或檔案
Database Marker 顯示該 SID 已建立
```

錯誤訊息必須要求 DBA 改用不同 SID：

```text
ERROR: Oracle SID already exists or has existing database artifacts: ORCL
Use a different ORACLE_SID and rerun the installer.
```

不得 reuse、start、repair、接管或刪除既有 Database 資源。

#### Listener Name 不得重複使用

Listener Name 固定由 SID 產生：

```bash
LISTENER_NAME="LSNR_$ORACLE_SID"
```

如果 `listener.ora`、`lsnrctl status`、Listener 程序或 Listener Marker 已有相同名稱，立即停止：

```text
ERROR: Listener already exists: LSNR_ORCL
Use a different ORACLE_SID and rerun the installer.
```

不得 reuse、start、merge、修改或接管既有 Listener。

#### Listener Port 必須未被使用

```bash
if ss -H -ltn | awk '{print $4}' | grep -Eq ":${LISTENER_PORT}$"; then
    echo "ERROR: Listener port is already in use: $LISTENER_PORT"
    echo "Use an unused LISTENER_PORT and rerun the installer."
    exit 1
fi
```

不得自動選擇下一個 Port、停止占用 Port 的程序、修改既有 Listener 或 reuse 已使用的 Port。

#### PreCheck 與 Main

PreCheck 分為兩個階段。

第一階段是 Oracle Software hard gate：

```text
Oracle Software 已安裝
或 Software、Oracle Home、Inventory、Marker 處於部分完成、不一致或無法安全判斷的狀態
→ 立即輸出 PRECHECK RESULT: FAIL
→ exit 1
→ 不執行其他 OS、SID、Listener、Database 或 Port 檢查
```

第二階段是 read-only prerequisite 與 target 檢查。Software hard gate 通過後，可以完成其餘檢查並累計 `PASS_COUNT`、`WARN_COUNT` 與 `FAIL_COUNT`，不需要因單一 target failure 立即退出。Target PreCheck 必須涵蓋：

```text
- ORACLE_SID format
- LISTENER_PORT format
- SID Marker、oratab、PMON、dbs、DATA、FRA 衝突
- Listener Marker、listener.ora、Listener process、lsnrctl 衝突
- Listener Port 使用狀態
```

依賴 SID 或 Listener Port 的檢查，在對應輸入格式無效時可以標示為未執行；不得使用無效輸入執行修改操作。完成 read-only 檢查後，只要 `FAIL_COUNT` 大於零，就必須輸出 `PRECHECK RESULT: FAIL` 並 `exit 1`。只有零 FAIL 才能讓 Main 繼續。

Main Script 必須在真正建立 Listener／Database 前再次確認 SID、Listener Name 與 Listener Port 未被使用。PreCheck 是第一層防護，Main 是第二層防護；但 Software 已安裝時不得進入任何第二層檢查。

整體判斷：

```text
Software 已安裝
→ STOP

Software 未安裝 + SID 已使用
→ STOP

Software 未安裝 + Listener Name 已使用
→ STOP

Software 未安裝 + Listener Port 已使用
→ STOP

Software 未安裝
+ SID 未使用
+ Listener Name 未使用
+ Listener Port 未使用
→ 才允許繼續新的完整安裝
```

Database／Listener Marker 是已使用識別值的證據，不是允許 reuse 的依據。

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
- Profile 規則維持在獨立 Reference；其他新機安裝停止、Marker、root scripts、SID、Listener 與 Database 規則以本文件為唯一規格。
