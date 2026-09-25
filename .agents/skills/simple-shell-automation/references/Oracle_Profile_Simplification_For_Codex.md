# Oracle Profile 單向載入簡化規格

## 目的

簡化 Oracle 使用者的 Profile 載入邏輯，保留現有檔案分工，但移除不必要的 recursive loading 防呆變數。

設計原則：

- 簡單
- Profile 管理邏輯在同一次受支援的新安裝流程中可安全執行
- 容易維護
- 容易除錯
- 不使用進階 Shell 技巧
- Profile 載入關係必須保持單向
- 不讓 `.oracle_env` 再回頭載入 `.bash_profile` 或 `.bashrc`

## 目標載入順序

```text
.bash_profile
      ↓
.oracle_env
      ↓
.<hostname>.profile
      ↓
.bash_alias
```

登入 oracle 帳號後：

```text
Login
 ↓
.bash_profile
 ↓
.oracle_env
 ├─ Oracle Home / PATH
 ├─ Host SID
 └─ DBA Alias
```

## 檔案分工

### `~/.bash_profile`

只負責載入 `.oracle_env`，不要在這裡設定 Oracle 環境變數。

```bash
if [ -f "$HOME/.oracle_env" ]; then
    . "$HOME/.oracle_env"
fi
```

### `~/.oracle_env`

負責 Oracle 共用環境，只往下載入 Host Profile 與 Alias，不得 source `.bash_profile` 或 `.bashrc`。

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

### `~/.<hostname>.profile`

只放主機專屬的 Database 設定，不要放 `ORACLE_HOME`、`PATH` 或 Alias。

```bash
export ORACLE_SID=ORCL
DB_NAME=$ORACLE_SID
DB_UNIQUE_NAME=$ORACLE_SID
```

### `~/.bash_alias`

只放 DBA Alias。`ORADATA` 的路徑必須由 `oracle_install.conf` 的 `DATA_DIR` 產生，不得使用與設定值無關的 hard-coded storage root。

以下範例假設 `DATA_DIR="/opt/oracle/oradata"`；顯示的是 Alias 產生後的實際內容，不是固定路徑標準。

```bash
alias ORADATA="ls -lur /opt/oracle/oradata/*_*/*/data/*.dbf"
alias ORAPS="ps -ef | grep -iv 'grep' | egrep -i -n 'smon|lsnr'; df -h | grep -i /ora"
alias dba="sqlplus / as sysdba"
```

## `.bashrc` 處理原則

如果需求只涵蓋 `su - oracle` 或一般 login shell，`.bashrc` 不參與 Oracle 環境載入：

```text
.bash_profile
    ↓
.oracle_env
```

只有明確要求 non-login interactive shell 也自動載入 Oracle 環境時，才考慮：

```text
.bash_profile
   ↓
.bashrc
   ↓
.oracle_env
```

即使採用此方式，也必須維持單向載入。

## 移除不必要的 recursion guard

改成單向載入後，移除下列變數與相關判斷：

```text
ORACLE_ENV_LOADING
ORACLE_ENV_SHELL_PID
BASHPID
```

沒有任何檔案回頭 source 上層檔案時，不需要額外的 recursive loading 防護。

## ## 必須保留的安全措施

1. 修改下列既有 Profile 檔案前，建立一次性的首次備份：

```text
.bash_profile.pre_oracle_install.bak.oracle_env.pre_oracle_install.bak.bash_alias.pre_oracle_install.bak
```

適用檔案：

```text
~/.bash_profile~/.oracle_env~/.bash_alias
```

首次備份已存在時不得覆蓋。

2. Host Profile (`~/.<hostname>.profile`) 不使用首次備份。

Host Profile 屬於本專案管理的主機 Database identity 設定，固定內容只有：

```bash
export ORACLE_SID=ORCLDB_NAME=$ORACLE_SIDDB_UNIQUE_NAME=$ORACLE_SID
```

Host Profile 的處理規則：

```text
不存在→ 建立已存在且為 regular file→ 不備份→ 直接覆寫固定內容symbolic link 或非 regular file→ FAIL
```

不得解析、merge、migration 或保留既有 Host Profile 內容。

3. 所有 Profile 路徑都必須拒絕 symbolic link 或非 regular file。

對 `~/.bash_profile`、`~/.oracle_env`、`~/.bash_alias`：

```text
regular file→ 可以依專案規則備份後覆寫symbolic link / 非 regular file→ FAIL
```

對 Host Profile：

```text
regular file→ 可以直接覆寫symbolic link / 非 regular file→ FAIL
```

4. 固定由安裝腳本管理的 Profile 檔案，可以依專案規則覆蓋固定內容。

不解析或合併未知的舊 Oracle Profile 設定。

5. 寫入後對每個 Bash Profile 檔案執行 `bash -n`。

6. 必要操作失敗立即 `exit 1`。

7. 錯誤訊息必須指出實際失敗的檔案或操作。

8. Host Profile 可以直接覆寫不代表允許接管既有 Oracle Database。

Oracle Software、SID、Listener Name、Listener Port、Database artifact 等新安裝檢查仍必須遵守 `Oracle_New_Server_Install_Rerun_Rules_For_Codex.md`。

## 修改與驗證要求

- 保留 `~/.oracle_env`、`~/.<hostname>.profile` 與 `~/.bash_alias`。

- `.oracle_env` 不得 source `.bash_profile` 或 `.bashrc`。

- 沒有 non-login shell 明確需求時，`.bashrc` 不參與 Oracle 環境載入。

- `.bash_profile`、`.oracle_env`、`.bash_alias` 修改前保留首次備份。

- Host Profile 不建立備份；既有 regular file 可以直接覆寫固定內容。

- 所有 Profile 路徑仍必須拒絕 symbolic link 或非 regular file。

- Host Profile 不做 parsing、merge、migration 或 adoption。

- 不要為縮短程式碼而移除必要的檔案型態檢查、`bash -n` 或錯誤處理。

- 不要使用進階 Shell 技巧。

- 確認 login shell 能取得 `ORACLE_HOME`。

- 確認 `PATH` 包含 `$ORACLE_HOME/bin`。

- 確認 Host Profile 能設定 `ORACLE_SID`。

- 確認 `.bash_alias` 能正常使用。

- 確認沒有重複或 recursive source。

完成修改後，列出修改內容、修改原因、新的 Profile 載入順序，以及是否符合一次性 Installer 的安全停止規則。
