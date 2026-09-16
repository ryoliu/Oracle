# Inventory root 完成紀錄恢復

本文件搭配同目錄的 `oracle_linux_7_8_19c_full_install.sh` 使用。將腳本複製到主機時，請一併保留本文件。

適用情況：既有 Inventory 缺少 `.orainst_root_complete`，或 `orainstRoot.sh` 成功後，完成紀錄寫入失敗。腳本會保守停止；本文件不改變其停止條件。

此紀錄只代表指定 Inventory 路徑與群組的 root 設定已完成，不能代替 Oracle 軟體安裝成功紀錄或 Oracle Home 的 `root.sh` 完成紀錄。不可只建立空白 marker，也不可只因 `/etc/oraInst.loc` 存在便認定成功。

## 1. 確認實際 Inventory

在目標 Oracle Linux 主機以 root 的 Bash 操作。若合併腳本修改了 `ORAINST_FILE`，以下也使用相同路徑。

```bash
RECOVERY_ORAINST_FILE="/etc/oraInst.loc"
cat "$RECOVERY_ORAINST_FILE"
RECOVERY_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$RECOVERY_ORAINST_FILE")"
RECOVERY_GROUP="$(sed -n 's/^inst_group=//p' "$RECOVERY_ORAINST_FILE")"

if [ -z "$RECOVERY_INVENTORY" ] || [ -z "$RECOVERY_GROUP" ] ||
   [ ! -d "$RECOVERY_INVENTORY" ]; then
    echo "ERROR: Review the Inventory path and group before continuing."
    exit 1
fi
if ! getent group "$RECOVERY_GROUP"; then
    echo "ERROR: Inventory group does not exist."
    exit 1
fi

RECOVERY_MARKER="$RECOVERY_INVENTORY/.orainst_root_complete"
ls -ld "$RECOVERY_INVENTORY"
if [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ]; then
    ls -l "$RECOVERY_MARKER"
fi
```

確認路徑、群組與實際安裝一致。若 `oraInst.loc` 缺少、內容重複、路徑不符或格式異常，先依安裝紀錄排查；不要猜測路徑或任意改指向另一個 Inventory。共用 Inventory 也需確認其他 Oracle Home 使用相同位置。

## 2. 確認 root 設定成功

- 有先前執行紀錄時，確認執行的是此 Inventory 的 `orainstRoot.sh`、返回碼為 `0`，且相關設定沒有後續被修改。只有 `oraInst.loc` 的路徑符合並不足以證明成功。
- 若無法確認，先檢查該 `orainstRoot.sh` 的內容、現有設定及先前錯誤。由 DBA 判斷可重新執行後，才以 root 執行下列指令；失敗時先排除原因，不建立 marker。

```bash
if "$RECOVERY_INVENTORY/orainstRoot.sh"; then
    echo "Inventory root script completed successfully."
else
    echo "ERROR: Inventory root script failed. Do not create the marker."
    exit 1
fi
```

如果已有可信的成功證據，只是 marker 寫入失敗，不需要為了補紀錄而再次執行 root 腳本。

## 3. 排除寫入失敗並補上紀錄

先依錯誤訊息檢查磁碟空間、inode、檔案系統是否唯讀，以及目錄與 marker 的權限／屬性。不要用遞迴 `chown`、`chmod` 或 `chmod 777` 作為通用修復。

僅在第 2 步已確認成功、寫入問題已排除後執行以下指令。若既有 marker 為符號連結或非一般檔案，先停止排查。既有一般檔案會保留一份備份，再以暫存檔替換，避免寫入中斷留下半份紀錄。

```bash
(
    if ! grep -Fxq "inventory_loc=$RECOVERY_INVENTORY" "$RECOVERY_ORAINST_FILE" ||
       ! grep -Fxq "inst_group=$RECOVERY_GROUP" "$RECOVERY_ORAINST_FILE"; then
        echo "ERROR: Inventory configuration does not match the reviewed values."
        exit 1
    fi
    if [ -L "$RECOVERY_MARKER" ] ||
       { [ -e "$RECOVERY_MARKER" ] && [ ! -f "$RECOVERY_MARKER" ]; }; then
        echo "ERROR: Review the existing marker path before continuing."
        exit 1
    fi
    if [ -f "$RECOVERY_MARKER" ]; then
        RECOVERY_BACKUP="$(mktemp "$RECOVERY_MARKER.backup.XXXXXX")" || exit 1
        cp -p "$RECOVERY_MARKER" "$RECOVERY_BACKUP" || exit 1
        echo "Previous marker backup: $RECOVERY_BACKUP"
    fi
    RECOVERY_TEMP="$(mktemp "$RECOVERY_INVENTORY/.orainst_root_complete.tmp.XXXXXX")" || exit 1
    trap 'rm -f -- "$RECOVERY_TEMP"' EXIT
    if ! printf 'inventory_loc=%s\ninst_group=%s\n' "$RECOVERY_INVENTORY" "$RECOVERY_GROUP" > "$RECOVERY_TEMP" ||
       ! chmod 644 "$RECOVERY_TEMP" ||
       ! mv -f -- "$RECOVERY_TEMP" "$RECOVERY_MARKER"; then
        echo "ERROR: Failed to write the Inventory completion record."
        exit 1
    fi
    cat "$RECOVERY_MARKER"
    echo "Inventory completion record restored."
)
```

## 4. 重跑合併腳本

確認上一步成功後，以原本的選項重跑，例如：

```bash
bash oracle_linux_7_8_19c_full_install.sh
```

腳本會比對完成紀錄與 `oraInst.loc` 的 Inventory 路徑、群組，符合時略過 `orainstRoot.sh`。若接著因缺少 installer 批次標記而停止，需另外核對軟體安裝狀態；本恢復流程不建立或修改 `.oracle_19c_installer_complete`、`.oracle_19c_root_complete`。
