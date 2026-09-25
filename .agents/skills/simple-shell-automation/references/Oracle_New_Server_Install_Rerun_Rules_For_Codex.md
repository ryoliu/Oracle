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
- 可安全再次呼叫；如果本次執行開始前已存在目標 Oracle Software，立即停止
- 容易維護
- 容易除錯
- 不使用進階 Shell 技巧
- 固定環境參數由 `oracle_install.conf` 提供
- `ORACLE_SID` 與 `LISTENER_PORT` 由 DBA 執行時人工輸入
- 本次執行開始前若已存在 Oracle Software，不得進入續跑流程
- 只有本次執行開始時 Oracle Software 尚未安裝，才允許進入新的完整安裝流程

> 本文件中的「既有 Oracle Software」或「Software 已安裝後重跑」是指 **本次 Main Script 啟動之前就已經存在** 的 Oracle Software。  
> 本次 Main Script 自己成功完成 `runInstaller` 後，仍屬於同一次受支援的新安裝 invocation，必須繼續執行同一次流程中的 root scripts、Listener／Database creation-blocking checks、Database 建立與 PostCheck。

---

## 支援的作業系統

本專案只支援 Oracle Linux 8.x（OEL8 / OL8），不將支援範圍限制在單一 minor release。

```text
Oracle Linux 8 → 支援
Oracle Linux 7 → FAIL
其他 Linux    → FAIL
```

PreCheck 與 Main Script 必須在修改系統、建立目錄、修改 Profile、安裝套件或啟動 Oracle Installer 前確認目前主機為 Oracle Linux 8。

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

只有確認本次 Main Script 啟動時 Oracle Software 尚未安裝後，才由 DBA 人工輸入這兩個值，完成格式與範圍驗證後，再由主安裝 Script 傳給後續步驟。不得從舊 Profile、`/etc/oratab`、舊 Listener 或其他既有設定反推輸入值。

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
下一次執行發現 Software 已經存在              → 不支援續跑，立即停止

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

### 3. Oracle Software 是本次執行開始時的第一個停止條件

固定環境參數由 `oracle_install.conf` 提供；`ORACLE_SID` 與 `LISTENER_PORT` 使用 DBA 本次執行時輸入的值。

PreCheck 必須先判斷 **本次執行開始前** 目標 Oracle Software 是否已安裝。這項檢查必須位於 SID、Listener Port、作業系統密碼及 Database 密碼輸入之前。

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

6. 檢查 Installer completion Marker。

7. 檢查 root-script Marker 是否呈現 partial / inconsistent state。

8. 檢查 ORACLE_HOME 是否為正常目錄且符合尚未安裝 Software 的新安裝狀態。

9. Software hard gate 通過後，才允許進入其餘 read-only prerequisite、
   SID、Listener 與 Port 檢查。
```

不得先採用 `/etc/oraInst.loc` 指向的其他 Inventory，再用該路徑判斷 Oracle Software 是否存在。

只要確認本次執行開始前目標 Oracle Software 已安裝，就立即 `ERROR + exit 1`，不得把 Software 階段設為 SKIP 後繼續執行。

判斷順序固定為：

```text
本次執行開始前 Oracle Software 已安裝
→ STOP
→ 不做額外安裝階段檢查
→ 不進入 SID / Listener / Database 新建流程

本次執行開始前 Oracle Software 未安裝
→ 通過 Software hard gate
→ 才允許檢查新的 SID、Listener Name 與 Listener Port
→ 才允許進入新的完整安裝流程
```

偵測到 **pre-existing Oracle Software** 後，不得再為了續跑或接管而檢查或處理：

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
下一次執行發現 Software 已安裝
→ SKIP software
→ 繼續建 Listener / Database
```

Oracle Inventory 已有目標 `ORACLE_HOME`、Installer completion Marker 存在，或其他既有判斷已足以確認目標 Software 在本次執行開始前已經完成安裝時，都必須立即停止。停止後不得為了判斷是否可以接續而再驗證其他安裝階段。

如果 Software 尚未安裝，但發現 Oracle Home、Inventory 或 Marker 處於未知、部分完成、不一致或無法安全判斷的狀態，同樣在 Software hard gate 階段立即停止，交由 DBA 處理；不得自動重裝、修復或接管。

### 同一次 invocation 的例外

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

不得把這個情境誤判為「Software 已安裝後重跑」。

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

`orainstRoot.sh` 與 `root.sh` 只屬於同一次全新安裝流程。它們可以在本次 Main Script 中依序執行並於成功後記錄 Marker，但不得用於下一次執行的續跑判斷。

```text
本次 Main Script 的 runInstaller 成功
→ 執行 orainstRoot.sh
→ 執行 root.sh
→ 繼續同一次 invocation 的 Listener / Database 流程

下一次執行在 Software hard gate 偵測到 Software 已安裝
→ 立即 STOP
→ 不檢查 orainstRoot.sh 或 root.sh Marker
```

不得使用 `INSTALL_REQUIRED=N`、Installer Marker 或 Inventory 將 Software 階段設成 SKIP，再於 **下一次執行** 繼續任何 root script、Listener 或 Database 工作。

可以保留下列 Marker 作為稽核與衝突證據：

```bash
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
```

只有對應步驟成功後才能建立 Marker。Marker 不代表下一次執行可以 SKIP 該階段並繼續；下一次執行只要確認 Oracle Software 已經存在，就立即停止，不得再使用 root-script Marker 判斷是否可以補跑。

不允許：

- 使用 `INSTALL_REQUIRED=N` 在下一次執行繼續後續安裝階段。
- 因 `ORAINST_ROOT_MARKER` 或 `ROOT_SH_MARKER` 不存在而在下一次執行補跑 root scripts。
- 使用 `/etc/oraInst.loc`、`/etc/oratab` 或 `oraenv` 判斷是否可以跨次續跑。
- 自動刪除 Oracle Home、Inventory 或 Marker。
- 自動重裝、修復或接管既有 Oracle Software。

---

### 6. SID / Listener / Database 衝突規則

這一節要區分兩個時間點：

```text
A. 本次 Main Script 啟動後、runInstaller 前
B. 本次 Main Script 已成功安裝 Software 後、真正建立 Listener / Database 前
```

A 階段只有在 Software hard gate 確認 **本次執行開始前 Software 尚未安裝** 時才允許執行。

B 階段屬於同一次 invocation 的第二層 creation-blocking check。即使 Software 已由本次 Main Script 安裝完成，仍必須再次檢查 SID、Listener Name 與 Listener Port，避免從 PreCheck 到實際建立資源之間狀態發生改變。

如果是 **下一次執行**，Software hard gate 發現 Software 已存在時，必須在進入 A 或 B 階段之前停止。

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
本次執行開始前 Oracle Software 已安裝
或 Software、Oracle Home、Inventory、Marker 處於部分完成、不一致或無法安全判斷的狀態
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
- Installer completion Marker 是否存在
- root-script Marker 是否呈現 partial / inconsistent state
- ORACLE_HOME 是否為正常目錄且符合尚未安裝 Software 的新安裝狀態
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

Target PreCheck 必須涵蓋：

```text
- ORACLE_SID format
- LISTENER_PORT format
- SID Marker、oratab、PMON、dbs、DATA、FRA 衝突
- Listener Marker、listener.ora、Listener process、lsnrctl 衝突
- Listener Port 使用狀態
```

依賴 SID 或 Listener Port 的檢查，在對應輸入格式無效時可以標示為未執行；不得使用無效輸入執行修改操作。完成 read-only 檢查後，只要 `FAIL_COUNT` 大於零，就必須輸出 `PRECHECK RESULT: FAIL` 並 `exit 1`。只有零 FAIL 才能讓 Main 繼續。

Main Script 必須在 **本次 invocation 已成功完成 Software 與 root scripts 後、真正建立 Listener／Database 前**，再次確認 SID、Listener Name 與 Listener Port 未被使用。

這個第二層檢查是同一次 invocation 的 creation-blocking check，不是 Software 已安裝後重跑，也不是 cross-run resume。

整體判斷：

```text
本次執行開始前 Software 已安裝
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
