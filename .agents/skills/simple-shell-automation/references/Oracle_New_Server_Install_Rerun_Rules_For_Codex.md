# Oracle 新機安裝與停止規格

## 目的

本專案只處理 Oracle Linux 8 新機安裝與 Oracle Database 19c 新安裝。

不處理：

- 舊環境 Migration
- 既有 Oracle Home 接管
- 既有 Profile 合併
- 舊設定自動解析
- 手動安裝到一半後的未知狀態接管

設計目標：

- 簡單
- 可安全再次呼叫；Software 尚未安裝時執行完整安裝，已驗證完整的專案 Software 只允許 `--create-db` Database-only 流程
- 容易維護
- 容易除錯
- 不使用進階 Shell 技巧
- 固定環境參數由 `oracle_install.conf` 提供
- `ORACLE_SID` 與 `LISTENER_PORT` 由 DBA 執行時人工輸入
- 本次執行開始前若已存在 Oracle Software，必須先分類為完整、部分完成或未知狀態
- 只有完整且由本專案 Marker 與 Inventory 驗證一致的 Software，才允許在 `--create-db` 下略過 Software 階段
- 未完成的 Software 安裝不支援跨次續跑、補跑 root scripts 或自動修復

> 本次 Main Script 自己成功完成 `runInstaller` 後，仍屬於同一次受支援的新安裝 invocation，必須繼續執行同一次流程中的 root scripts、Listener／Database creation-blocking checks、Database 建立與 PostCheck。
> 下一次執行只有在指定 `--create-db`，且既有 Software 通過完整狀態驗證時，才允許執行 Database-only provisioning。這不是未完成 Software 安裝的 cross-run resume。

---

## 支援的作業系統

本專案只支援 Oracle Linux 8.x（OEL8 / OL8），不將支援範圍限制在單一 minor release。

```text
Oracle Linux 8 → 支援
Oracle Linux 7 → FAIL
其他 Linux    → FAIL
```

PreCheck 必須在修改系統、建立目錄、修改 Profile、安裝套件或啟動 Oracle Installer 前確認目前主機為 Oracle Linux 8。

如果目前主機不是 Oracle Linux 8，必須顯示實際偵測到的 OS 與 Version，然後 `exit 1`。不得只顯示 warning 後繼續，也不得加入 Oracle Linux 7、RHEL、Rocky Linux、AlmaLinux、CentOS 或其他 distribution 的相容處理。

`CV_ASSUME_DISTID` 只能在已確認主機為 Oracle Linux 8 後，用於 Oracle Database 19c 19.3 Base Installer 的已知相容需求；不得用來讓非 Oracle Linux 8 主機繞過本專案的 OS 限制。

此限制只定義 Distribution 與 Major Version。Architecture、Kernel、Memory、Swap、Disk、Package 與 Oracle prerequisite 仍由各自的 PreCheck 規則判斷。

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

Oracle Linux 8 UEK7 的 kernel release 若符合已知最低版本，PreCheck 應通過 kernel minimum check，但必須顯示 WARN，指出此組合正式支援需要 Oracle Database 19c RU 19.21 或更新版本。已辨識的 Oracle Linux 8 kernel family 若低於已知最低版本，PreCheck 也應顯示 WARN 並列出最低版本，不得因此阻止目前測試流程。由於目前測試版不套用 RU，這些 WARN 只允許繼續驗證 19.3 Base Media 安裝流程，不得描述為正式支援或認證組合。

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

只有 Software hard gate 確認狀態為全新安裝，或確認為 `--create-db` 可使用的完整專案 Software 後，才由 DBA 人工輸入這兩個值，完成格式與範圍驗證後，再由主安裝 Script 傳給後續步驟。不得從舊 Profile、`/etc/oratab`、舊 Listener 或其他既有設定反推輸入值。

不要再解析舊設定來決定：

- ORACLE_SID
- ORACLE_HOME
- Listener Port
- DATA_DIR
- FRA_DIR
- Database Name
- DB_UNIQUE_NAME

`oracle_install.conf` 是 Oracle Inventory path 與 group 的唯一設定來源與 source of truth。

`/etc/oraInst.loc` 若已存在，只能作為驗證資料：

```text
inventory_loc 必須等於 oracle_install.conf 的 ORA_INVENTORY
inst_group    必須等於 oracle_install.conf 的 ORACLE_GROUP
```

不得使用 `/etc/oraInst.loc` 的值覆寫 `ORA_INVENTORY`、`ORACLE_GROUP` 或其他設定變數，也不得以其內容接管另一個 Inventory。

尤其不得建立另一個 Inventory 變數，再由 `/etc/oraInst.loc` 的 `inventory_loc` 改變 Software hard gate 的檢查目標，例如：

```bash
SOFTWARE_INVENTORY="$ORA_INVENTORY"
SOFTWARE_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
```

Software hard gate 的 Inventory 檢查路徑固定為：

```text
$ORA_INVENTORY/ContentsXML/inventory.xml
```

如果 `/etc/oraInst.loc` 與 `oracle_install.conf` 不一致、內容缺失、無法安全讀取，必須在 Software hard gate 階段立即停止。

Software hard gate 判斷 Oracle Inventory 時，也必須以 `oracle_install.conf` 的 `ORA_INVENTORY` 為目標 Inventory；`/etc/oraInst.loc` 只負責驗證一致性，不是替代設定來源。

#### Oracle Inventory 的新機狀態

如果 `/etc/oraInst.loc` 不存在：

```text
ORA_INVENTORY 不存在
→ 支援
→ Main 可以建立新的 Inventory

ORA_INVENTORY 已存在且為空目錄
→ 支援
→ 視為預先建立的新安裝空目錄

ORA_INVENTORY 已存在且非空
→ FAIL
→ 視為 unknown existing Inventory
→ DBA review
```

不得因既有非空 Inventory 的 owner、group 或權限看起來合理，就自動接管該 Inventory。

如果 `/etc/oraInst.loc` 已存在：

```text
inventory_loc == ORA_INVENTORY
且
inst_group == ORACLE_GROUP
→ 才能繼續檢查該 Inventory 是否符合新安裝條件

inventory_loc != ORA_INVENTORY
或
inst_group != ORACLE_GROUP
→ FAIL
```

---

### 2. 新機安裝，不做 Migration

本專案的邊界：

```text
全新主機                                      → 支援
本次執行開始前 Software 尚未安裝              → 支援新的完整安裝
本次執行自己剛完成 Software 安裝              → 支援繼續同一次 invocation
完整專案 Software + --create-db               → 支援 Database-only
完整專案 Software + 未指定 --create-db        → FAIL
部分完成、未知或不一致 Software               → FAIL

舊 Oracle Home                                → 不支援
舊 Database                                   → 不支援
既有 Target Listener                          → 不支援 reuse / adoption
既有 unrelated Listener                       → 可以保留，但不得與本次 Listener Name / Port 衝突
舊 Profile Migration                          → 不支援
舊 Inventory 自動接管                         → 不支援
```

遇到不符合預期的舊環境，直接 FAIL。

不要加入複雜邏輯去：

- 猜
- merge
- migrate
- adopt
- repair

保留既有 unrelated Listener configuration 不代表 Migration 或 adoption。它只能保持原內容不變，並且本次新 Listener 必須使用新的 Listener Name 與未使用的 Port。

---

### 3. Oracle Software 狀態是本次執行開始時的第一個 Hard Gate

固定環境參數由 `oracle_install.conf` 提供；`ORACLE_SID` 與 `LISTENER_PORT` 使用 DBA 本次執行時輸入的值。

PreCheck 必須先判斷 **本次執行開始前** 目標 Oracle Software 屬於 `NEW`、`COMPLETE` 或 `INVALID`。這項檢查必須位於 SID、Listener Port、作業系統密碼及 Database 密碼輸入之前。

Software hard gate 的判斷順序固定為：

```text
1. 載入 oracle_install.conf，確認必要的 ORACLE_HOME、ORA_INVENTORY、
   ORAINST_FILE 與 ORACLE_GROUP 設定存在。

2. /etc/oraInst.loc 若存在，確認它是 regular file。

3. /etc/oraInst.loc 若存在，確認：
   inventory_loc == ORA_INVENTORY
   inst_group    == ORACLE_GROUP

4. /etc/oraInst.loc 若不存在：
   - ORA_INVENTORY 不存在       → 可以繼續
   - ORA_INVENTORY 為空目錄     → 可以繼續
   - ORA_INVENTORY 為非空目錄   → FAIL，DBA review

5. Oracle Software Inventory 判斷永遠只使用：
   $ORA_INVENTORY/ContentsXML/inventory.xml

6. 檢查 Installer completion Marker 是否為 regular、readable 且非空檔案。

7. 檢查 orainstRoot.sh 與 root.sh Marker 是否為 regular、readable file；目前這兩個 Marker 可為空檔案。

8. 檢查 ORACLE_HOME 是否為正常目錄，並判斷為空的新安裝狀態或完整 Software 狀態。

9. 完整 Software 必須同時滿足：oraInst.loc 一致、Inventory 登錄相同 ORACLE_HOME、
   三個 Marker 全部存在，以及 runInstaller、root.sh、orainstRoot.sh、dbca、lsnrctl、
   sqlplus、DBCA response template、dbs 與 /etc/oratab 可安全使用。

10. Software hard gate 通過後，才允許進入其餘 read-only prerequisite、
    SID、Listener 與 Port 檢查。
```

不得先採用 `/etc/oraInst.loc` 指向的其他 Inventory，再用該路徑判斷 Oracle Software 是否存在。

狀態判斷固定為：

```text
NEW：Inventory 未登錄目標 ORACLE_HOME、三個 Marker 均不存在、ORACLE_HOME 不存在或為空
→ 通過 Software hard gate
→ 才允許檢查新的 SID、Listener Name 與 Listener Port
→ 才允許進入新的完整安裝流程

COMPLETE：oraInst.loc、Inventory、三個 Marker、ORACLE_HOME 與必要 Oracle tools 全部一致
→ 未指定 --create-db 時 FAIL
→ 指定 --create-db 時允許 Database-only
→ 不執行套件安裝、系統設定、Software 解壓、runInstaller 或 root scripts

INVALID：任何介於 NEW 與 COMPLETE 之間、無法安全讀取或互相不一致的狀態
→ FAIL
→ DBA review
```

COMPLETE 只允許建立新的 Database，不代表允許一般性的 cross-run resume。不得因 Marker 缺少而補跑 root scripts，不得重新執行 runInstaller，不得修復 Software，也不得接管沒有本專案完整 Marker 的 Oracle Home。

Database-only 不執行 Main 的作業系統修改階段。PreCheck 若發現 preinstall package、SELinux、firewalld、iptables 或 timezone 已偏離本專案完整安裝後的必要狀態，必須 FAIL，不得以「Main 稍後會修正」的 WARN 繼續。

如果 Oracle Home、Inventory、Marker 或必要 Oracle tools 處於未知、部分完成、不一致或無法安全判斷的狀態，必須在 Software hard gate 階段立即停止，交由 DBA 處理。

### 支援的兩種 Database 建立路徑

以下情境不是 cross-run resume：

```text
本次 Main Script 啟動
→ Software hard gate 確認目標 Software 尚未安裝
→ Target PreCheck 通過
→ 本次 Main Script 執行 runInstaller
→ runInstaller 成功
→ 本次 Main Script 執行 root scripts
→ 本次 Main Script 再次執行 creation-blocking SID / Listener / Port checks
→ 建立 Listener
→ DBCA
→ PostCheck
```

此時 Oracle Software 雖然已經存在，但它是 **本次 Main Script 自己剛安裝完成** 的結果，因此必須繼續同一次 invocation。

另一個受支援路徑是：

```text
本次 Main Script 以 --create-db 啟動
→ Software hard gate 確認既有 Software 為 COMPLETE
→ 略過全部 Software 與 root-script 階段
→ Target PreCheck 通過
→ 再次確認 SID / Listener Name / Listener Port
→ 建立新的 Listener、Database、Host Profile 並執行 PostCheck
```

這是針對已驗證專案 Oracle Home 的跨次 Database provisioning，不是未完成 Software 安裝的續跑。

---

### 4. Profile 管理

Profile 採固定內容管理，不解析、merge 或 migration 舊 Profile。

涉及以下檔案時：

- `~/.bash_profile`
- `~/.oracle_env`
- `~/.bash_alias`
- `~/.<hostname>.profile`

必須完整讀取並遵守 [Oracle_Profile_Simplification_For_Codex.md](Oracle_Profile_Simplification_For_Codex.md)。該文件是 Profile 載入順序、檔案內容、備份、檔案型態與語法驗證的唯一詳細規格。

其中 Host Profile (`~/.<hostname>.profile`) 屬於本專案管理的主機 Database identity 設定。

Host Profile 規則：

```text
不存在
→ 建立固定內容

已存在且為 regular file
→ 不建立備份
→ 直接覆寫為本次安裝的固定內容

symbolic link 或非 regular file
→ FAIL
→ DBA review
```

Host Profile 不進行：

- legacy parsing
- merge
- migration
- adoption
- 首次備份

直接覆寫 Host Profile 不代表支援既有 Oracle Database 接管。Oracle Software、SID、Listener 與 Database 的新安裝衝突檢查仍必須先通過；Host Profile 只能在本次受支援的新 Database 建立流程中寫入。

---

### 5. Oracle Software 與 root scripts

`orainstRoot.sh` 與 `root.sh` 只屬於同一次全新 Software 安裝流程。它們可以在本次 Main Script 中依序執行並於成功後記錄 Marker，但不得在 Database-only 流程中再次執行。

```text
本次 Main Script 的 runInstaller 成功
→ 執行 orainstRoot.sh
→ 執行 root.sh
→ 繼續同一次 invocation 的 Listener / Database 流程

下一次執行以 --create-db 啟動
→ 只有三個 Marker、Inventory 與必要 tools 全部一致才允許 Database-only
→ 略過 orainstRoot.sh 與 root.sh

Marker 缺少、型態錯誤或與 Inventory 不一致
→ FAIL
→ 不補跑任何 root script
```

不得使用單一 Marker 或單一 Inventory 判斷將 Software 階段設成 SKIP。只有 `--create-db` 且完整 Software hard gate 全部通過，才允許設定 Database-only mode。

可以保留下列 Marker 作為稽核與衝突證據：

```bash
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
```

只有對應步驟成功後才能建立 Marker。三個 Marker 必須與 oraInst.loc、Inventory、ORACLE_HOME 與必要 Oracle tools 一起驗證；任何單一 Marker 都不代表可以略過安裝。Database-only 只能使用完整集合判斷，而且 Marker 只能證明可略過，不能作為補跑 root scripts 的依據。

不允許：

- 使用 `INSTALL_REQUIRED=N` 或類似旗標續跑部分完成的 Software 安裝。
- 因 `ORAINST_ROOT_MARKER` 或 `ROOT_SH_MARKER` 不存在而在下一次執行補跑 root scripts。
- 單獨使用 `/etc/oraInst.loc`、`/etc/oratab` 或 `oraenv` 判斷是否可以進入 Database-only 或跨次續跑。
- 自動刪除 Oracle Home、Inventory 或 Marker。
- 自動重裝、修復或接管既有 Oracle Software。

---

### 6. SID / Listener / Database 衝突規則

這一節要區分三個時間點：

```text
A. 本次 Main Script 啟動後、runInstaller 前
B. 本次 Main Script 已成功安裝 Software 後、真正建立 Listener / Database 前
C. Database-only 啟動後、真正建立 Listener / Database 前
```

A 階段在 Software hard gate 確認 `NEW` 後執行。C 階段只有在指定 `--create-db` 且 Software hard gate 確認 `COMPLETE` 後執行。

B 與 C 階段都必須再次檢查 SID、Listener Name 與 Listener Port，避免從 Target PreCheck 到實際建立資源之間狀態發生改變。

Database-only 不得略過 Target PreCheck 或 Main 的 creation-blocking check。

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

如果 `listener.ora`、`lsnrctl status`、Listener 程序或 Listener Marker 已有 **相同 Listener Name**，立即停止：

```text
ERROR: Listener already exists: LSNR_ORCL
Use a different ORACLE_SID and rerun the installer.
```

不得 reuse、start、repair 或接管本次 Target Listener。

既有 unrelated Listener 可以保留，但必須同時滿足：

```text
Listener Name 與本次 LISTENER_NAME 不同
Listener Port 與本次 LISTENER_PORT 不同
既有 Listener 定義保持原內容
```

新增本次 dedicated Listener 時可以保留 `listener.ora` 中既有 unrelated Listener entries，再加入新的 Target Listener entry。這不視為接管既有 Listener。

不得為了本次安裝修改、重新命名、停止或重建 unrelated Listener。

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
Software 狀態為 NEW
→ 允許完整安裝

Software 狀態為 COMPLETE + --create-db
→ 允許 Database-only

Software 狀態為 COMPLETE + 未指定 --create-db
或 Software、Oracle Home、Inventory、Marker、必要 tools 處於部分完成、不一致或無法安全判斷的狀態
→ 立即輸出 PRECHECK RESULT: FAIL
→ exit 1
→ 不執行其他 OS、SID、Listener、Database 或 Port 檢查
```

Software hard gate 至少要先判斷：

```text
- oracle_install.conf 的必要 Inventory 設定是否存在
- /etc/oraInst.loc 若存在，是否為 regular file
- /etc/oraInst.loc 的 inventory_loc 是否等於 ORA_INVENTORY
- /etc/oraInst.loc 的 inst_group 是否等於 ORACLE_GROUP
- /etc/oraInst.loc 不存在時，ORA_INVENTORY 若已存在是否仍為空目錄
- 只使用 $ORA_INVENTORY/ContentsXML/inventory.xml 判斷目標 ORACLE_HOME
- Installer completion Marker 是否為 regular、readable 且非空
- 兩個 root-script Marker 是否為 regular、readable file
- ORACLE_HOME 是否為正常目錄且符合 NEW 或 COMPLETE 狀態
- COMPLETE 狀態需要的 Oracle tools、DBCA template、dbs 與 /etc/oratab 是否可安全使用
```

`oracle_install.conf` 是 source of truth；不得先採用 `/etc/oraInst.loc` 指向的其他 Inventory，再以該 Inventory 決定是否繼續。

不得使用下列模式改變 Software hard gate 的 Inventory 目標：

```bash
SOFTWARE_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
SOFTWARE_INVENTORY_FILE="$SOFTWARE_INVENTORY/ContentsXML/inventory.xml"
```

應固定以：

```text
$ORA_INVENTORY/ContentsXML/inventory.xml
```

判斷 Oracle Software 安裝狀態。

第二階段是 read-only prerequisite 與 target 檢查。Software hard gate 通過後，可以完成其餘檢查並累計 `PASS_COUNT`、`WARN_COUNT` 與 `FAIL_COUNT`，不需要因單一 target failure 立即退出。

PreCheck 的 WARN、FAIL、結果摘要與最終結果顯示方式，必須遵守 `AGENTS.md` 的終端輸出顯示規則；顏色不得影響 exit code 或停止邏輯。

Target PreCheck 必須涵蓋：

```text
- ORACLE_SID format
- LISTENER_PORT format
- SID Marker、oratab、PMON、dbs、DATA、FRA 衝突
- Listener Marker、listener.ora、Listener process、lsnrctl 衝突
- Listener Port 使用狀態
```

依賴 SID 或 Listener Port 的檢查，在對應輸入格式無效時可以標示為未執行；不得使用無效輸入執行修改操作。完成 read-only 檢查後，只要 `FAIL_COUNT` 大於零，就必須輸出 `PRECHECK RESULT: FAIL` 並 `exit 1`。只有零 FAIL 才能讓 Main 繼續。

Main Script 必須在真正建立 Listener／Database 前，再次確認 SID、Listener Name 與 Listener Port 未被使用。完整安裝與 Database-only 都適用。

這個第二層檢查是 creation-blocking check，不是既有 Database 的 resume 或 adoption。

整體判斷：

```text
本次執行開始前 Software COMPLETE + 未指定 --create-db
→ STOP

本次執行開始前 Software COMPLETE + --create-db
→ 略過 Software 與 root scripts
→ 檢查新的 SID / Listener / Port

本次執行開始前 Software partial / unknown / inconsistent
→ STOP

本次執行開始前 Software 未安裝 + SID 已使用
→ STOP

本次執行開始前 Software 未安裝 + Listener Name 已使用
→ STOP

本次執行開始前 Software 未安裝 + Listener Port 已使用
→ STOP

本次執行開始前 Software 未安裝
+ SID 未使用
+ Listener Name 未使用
+ Listener Port 未使用
→ 允許進入新的完整安裝

本次 invocation 的 runInstaller / root scripts 成功
→ 再次確認 SID / Listener Name / Listener Port
→ 無衝突才建立 Listener / Database

Database-only 的 Target PreCheck 成功
→ 再次確認 SID / Listener Name / Listener Port
→ 無衝突才建立 Listener / Database
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

其中 Oracle Inventory 有更嚴格的規則：

```text
oraInst.loc 不存在 + ORA_INVENTORY 不存在
→ 可以建立

oraInst.loc 不存在 + ORA_INVENTORY 為空目錄
→ 可以使用

oraInst.loc 不存在 + ORA_INVENTORY 非空
→ ERROR
→ unknown Inventory
→ DBA review
```

Database-only 模式下，`ORACLE_BASE`、`ORACLE_HOME` 與 `ORA_INVENTORY` 必須已存在且符合完整 Software 驗證結果，不得由 Main 補建或修復。新的 `DATA_DIR` 與 `FRA_DIR` storage root 仍可在 Database 建立階段依既有規則建立。

不要：

- 自動接管未知目錄
- 自動改既有 Oracle Home
- 自動猜舊權限
- 因權限看起來合理就接管 unknown non-empty Inventory

---

## 修改邊界

- 只修改需求涉及的區段，不順便重構其他功能。
- 不為縮短程式碼而移除失敗處理、語法驗證或基本狀態驗證。
- 不加入 Profile migration、舊設定解析、既有 Oracle 環境接管或自動修復。
- Profile 規則維持在獨立 Reference；其他新機安裝停止、Marker、root scripts、SID、Listener 與 Database 規則以本文件為唯一規格。
