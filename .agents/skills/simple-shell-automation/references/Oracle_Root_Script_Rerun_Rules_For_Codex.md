# Oracle root script 重跑判斷規格

## 問題說明

`oracle_linux_7_8_19c_full_install.sh` 已使用 `INSTALL_MARKER` 與 Oracle Inventory 判斷 Oracle Software 是否安裝完成，因此重跑時可以略過解壓與 `runInstaller`。但 `orainstRoot.sh` 與 `root.sh` 若沒有各自的完成狀態，仍會在每次重跑時再次執行。

不能只在 `INSTALL_REQUIRED=N` 時同時略過兩個 root scripts。可能發生 `runInstaller` 成功並建立 `INSTALL_MARKER`，但後續 `orainstRoot.sh` 或 `root.sh` 失敗；下一次必須能從失敗階段繼續。

## Marker 設計

保留既有 Oracle Software Marker，並增加兩個獨立 Marker：

```bash
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
```

用途：

```text
INSTALL_MARKER
    → runInstaller 已成功完成

ORAINST_ROOT_MARKER
    → orainstRoot.sh 已成功完成

ROOT_SH_MARKER
    → root.sh 已成功完成
```

只有對應步驟成功後才能建立 Marker。

## Oracle Software 判斷

保留現有判斷，不得只檢查 Marker，仍需搭配 Oracle Inventory 驗證：

```bash
if [ -f "$INSTALL_MARKER" ] &&
   [ -f "$INVENTORY_FILE" ] &&
   grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    INSTALL_REQUIRED="N"
    echo "Oracle software is already installed. Skip runInstaller."
else
    INSTALL_REQUIRED="Y"
fi
```

如果 Marker 存在但 Inventory 沒有對應 Oracle Home，視為異常狀態，不要直接重裝或自動修復。

## `orainstRoot.sh` 判斷

```bash
if [ -f "$ORAINST_ROOT_MARKER" ]; then
    echo "orainstRoot.sh already completed. Skip."
else
    echo "=== Run orainstRoot.sh ==="

    if ! "$ORA_INVENTORY/orainstRoot.sh"; then
        echo "ERROR: orainstRoot.sh failed."
        exit 1
    fi

    if ! touch "$ORAINST_ROOT_MARKER"; then
        echo "ERROR: Failed to create orainstRoot.sh completion marker."
        exit 1
    fi

    echo "orainstRoot.sh completed successfully."
fi
```

規則：

- Marker 存在：略過。
- Marker 不存在：執行。
- Script 成功後：建立 Marker。
- Script 失敗：不建立 Marker，立即 `exit 1`。

## `root.sh` 判斷

```bash
if [ -f "$ROOT_SH_MARKER" ]; then
    echo "root.sh already completed. Skip."
else
    echo "=== Run root.sh ==="

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

    if ! touch "$ROOT_SH_MARKER"; then
        echo "ERROR: Failed to create root.sh completion marker."
        exit 1
    fi

    echo "root.sh completed successfully."
fi
```

規則：

- Marker 存在：略過。
- Marker 不存在：執行。
- Script 成功後：建立 Marker。
- Script 失敗：不建立 Marker，立即 `exit 1`。

## 最終流程

```text
Oracle ZIP 解壓
      ↓
EXTRACT_MARKER

runInstaller
      ↓
INSTALL_MARKER

orainstRoot.sh
      ↓
ORAINST_ROOT_MARKER

root.sh
      ↓
ROOT_SH_MARKER
```

## 重跑行為

### 全部成功

```text
INSTALL_MARKER       = 有
ORAINST_ROOT_MARKER  = 有
ROOT_SH_MARKER       = 有

runInstaller      SKIP
orainstRoot.sh    SKIP
root.sh           SKIP
```

### `runInstaller` 成功，但 `orainstRoot.sh` 失敗

```text
INSTALL_MARKER       = 有
ORAINST_ROOT_MARKER  = 無
ROOT_SH_MARKER       = 無

runInstaller      SKIP
orainstRoot.sh    RUN
root.sh           orainstRoot.sh 成功後再 RUN
```

### `orainstRoot.sh` 成功，但 `root.sh` 失敗

```text
INSTALL_MARKER       = 有
ORAINST_ROOT_MARKER  = 有
ROOT_SH_MARKER       = 無

runInstaller      SKIP
orainstRoot.sh    SKIP
root.sh           RUN
```

## 修改要求

修改 Oracle 安裝腳本的 root script 執行邏輯時：

- 保留 `EXTRACT_MARKER`、`INSTALL_MARKER` 與 Oracle Inventory 驗證。
- `runInstaller` 成功後才建立 `INSTALL_MARKER`。
- Oracle Software 已安裝完成時，不重新執行 `runInstaller`。
- 新增 `ORAINST_ROOT_MARKER` 與 `ROOT_SH_MARKER`。
- 每個 root script 執行前檢查自己的 Marker。
- 只有該 script 成功後才建立自己的 Marker。
- script 或 Marker 建立失敗時立即 `exit 1`。

## 禁止事項

不要：

- 只用 `INSTALL_REQUIRED=N` 同時跳過兩個 root scripts。
- 用 `/etc/oraInst.loc` 判斷 `orainstRoot.sh` 是否完成。
- 用 `/etc/oratab` 判斷 `root.sh` 是否完成。
- 用 `/usr/local/bin/oraenv` 是否存在判斷 `root.sh` 是否完成。
- 自動刪除 Oracle Home。
- 自動重做已完成的安裝步驟。
- 為縮短程式碼而刪除既有驗證與錯誤處理。

這些系統檔案可能由其他 Oracle Home 或舊安裝留下，不能準確代表本次安裝是否完成。

## DBA 摘要

```text
runInstaller
→ .oracle_19c_installer_complete

orainstRoot.sh
→ .orainstRoot_complete

root.sh
→ .root_sh_complete
```

每個安裝階段成功後留下自己的 Marker。下次重跑時，已完成的步驟略過，失敗的步驟從該處繼續。
