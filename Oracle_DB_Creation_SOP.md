# Oracle Database 建庫流程與規則評估

## 適用範圍

- 以 Oracle Database 19c 單機環境為基準。
- Oracle 軟體已安裝完成，直接從第 2 步開始。
- Listener 未由 Grid Infrastructure 或 Oracle Restart 管理；此類環境應另訂管理流程。
- 本文件為建庫與網路設定 SOP，不代表已在目標環境執行。

## 評估結論

流程可行：先由 NETCA 建立 Listener，再由 DBCA 建庫並指定 Listener，確認註冊位址後主動註冊，最後確認或更新連線 alias 並驗證。

必要規則：

- Listener 命名為 `LSNR_<SID>`，指定監聽埠 `<PORT>`。
- `LSNR_<SID>:<PORT>` 表示名稱與埠，Listener 名稱本身不包含 `:<PORT>`。
- DBCA 使用 `-listeners LSNR_<SID>`。
- 非 1521 埠的 `LOCAL_LISTENER` 直接設定 `ADDRESS`，避免依賴 Listener alias 的名稱解析。
- `<SID>` 可作為 DB connection alias，但不代表 `SERVICE_NAME` 必須與 SID 相同。
- 驗證時明確指定 Listener 名稱，並以 SQL*Plus 實際登入作為最終驗收。

## 執行前確認

- 確認 `ORACLE_HOME`、`ORACLE_SID` 與執行工具所屬的 Oracle Home 正確。
- 確認 `TNS_ADMIN` 是否設定，以及實際使用的 `listener.ora`、`tnsnames.ora` 位置。
- 確認預定的 HOST/IP 與 PORT 可用，避免同一 IP 的監聽埠衝突。
- 修改既有網路設定檔前先備份；保留其他資料庫的設定。

以下範例值需依環境替換：

| 項目 | 範例 |
|---|---|
| SID | `ORCL` |
| Listener 名稱 | `LSNR_ORCL` |
| HOST | `dbhost.example.com` |
| PORT | `1522` |
| DB connection alias | `ORCL` |
| 目標 SERVICE_NAME | `orcl.example.com` |

## 2. NETCA：建立並啟動 Listener

使用 NETCA 建立以下設定：

| 設定 | 規則 |
|---|---|
| Listener Name | `LSNR_<SID>` |
| Protocol | `TCP` |
| Port | `<PORT>` |

建立後，確認 Listener 已啟動且監聽位址正確：

```text
lsnrctl status LSNR_ORCL
```

若尚未啟動：

```text
lsnrctl start LSNR_ORCL
```

此時資料庫尚未建立，沒有資料庫服務註冊屬於正常情況。

## 3. DBCA：建立 Database

DBCA 建庫時指定第 2 步建立的 Listener。下列為參數片段，並非完整建庫命令：

```text
-listeners LSNR_ORCL
```

其他建庫參數，例如資料檔位置、字元集、記憶體、CDB/PDB 與密碼，依環境的建庫規格設定。

## 4. 建庫後：確認 LOCAL_LISTENER

以 SYSDBA 連線；若為 CDB，於 `CDB$ROOT` 執行。

```sql
SHOW PARAMETER local_listener;
```

### 非 1521 埠

直接設定 Listener 的 ADDRESS：

```sql
ALTER SYSTEM SET LOCAL_LISTENER =
  '(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost.example.com)(PORT=1522))'
  SCOPE=BOTH;
```

- HOST 必須對應 Listener 實際監聽且資料庫主機可到達的位址。
- `SCOPE=BOTH` 適用於使用 SPFILE 的資料庫；使用 PFILE 時，需另行同步修改 PFILE，以保留重啟後的設定。
- 此設定不需要在 `tnsnames.ora` 中建立 Listener alias。

### 1521 埠

當預設本機 TCP/1521 位址符合實際 Listener 位址，且沒有錯誤的顯式設定時，可以使用預設值。

不可僅因 PORT 為 1521 就跳過檢查；若 `LOCAL_LISTENER` 已指向其他位址，仍應修正。

## 5. 要求立即註冊

確認 Listener 已啟動且 `LOCAL_LISTENER` 正確後，執行：

```sql
ALTER SYSTEM REGISTER;
```

此命令要求資料庫立即向 Listener 註冊，不會啟動 Listener。

## 6. 建立／更新 tnsnames.ora DB connection alias

以 `<SID>` 作為 DB connection alias。DBCA 可能已建立資料庫的 net service name，因此先檢查實際使用的 `tnsnames.ora`，確認 `<SID>` alias 是否已存在：

- 已存在且設定正確：保留，不重複建立。
- 已存在但設定不符：更新該 alias。
- 不存在：新增該 alias。

實作時可選擇 NETCA，或由 Shell 安全更新 `tnsnames.ora`；依既有設定與自動化需求選擇工具，不限定必須由 NETCA 建立。使用 NETCA 時，也應先處理既有 alias，避免重複新增。

**新增或更新對應項目，不要覆蓋整份既有檔案。**

若使用 Shell，修改前應備份、保留其他項目，並正確處理跨行與巢狀括號，避免簡單文字替換誤改其他連線設定。再次執行時，設定已正確就不修改，以確保流程可重複執行。

連線設定範例：

```text
ORCL =
  (DESCRIPTION =
    (ADDRESS =
      (PROTOCOL = TCP)
      (HOST = dbhost.example.com)
      (PORT = 1522)
    )
    (CONNECT_DATA =
      (SERVICE_NAME = orcl.example.com)
    )
  )
```

- `ORCL` 是用戶端連線 alias。
- `SERVICE_NAME` 必須是實際註冊的目標服務，不可直接假設與 SID 相同。
- 如果目標為 PDB，使用該 PDB 的服務，並確認 PDB 已開啟。
- 設定應放在執行連線工具之用戶端實際讀取的位置；遠端用戶端也需有相應設定。

## 7. 驗證與驗收

### 7.1 Listener 狀態與服務

```text
lsnrctl status LSNR_ORCL
lsnrctl services LSNR_ORCL
```

確認：

- Listener 名稱與 HOST/PORT 正確。
- 目標服務已註冊。
- 目標動態註冊 Instance 的狀態為 `READY`。

### 7.2 名稱解析與 Listener 可達性

```text
tnsping ORCL
```

確認 alias 解析至預期 HOST/PORT，且測試成功。`tnsping` 不會驗證資料庫是否開啟，也不會驗證帳號密碼；不能單獨作為建庫成功的依據。

### 7.3 實際登入

```text
sqlplus system@ORCL
```

在提示時輸入密碼。登入後執行：

```sql
SELECT
  SYS_CONTEXT('USERENV', 'INSTANCE_NAME') AS instance_name,
  SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS service_name,
  SYS_CONTEXT('USERENV', 'CON_NAME') AS container_name
FROM dual;
```

確認實際連到預期的 Instance、Service 與 Container。若需要提供遠端連線，應在實際用戶端再完成 `tnsping` 與 SQL*Plus 驗證。

## 驗收清單

- [ ] NETCA 已建立並啟動 `LSNR_<SID>`。
- [ ] Listener 使用正確的 HOST/PORT。
- [ ] DBCA 已完成建庫並指定 `-listeners LSNR_<SID>`。
- [ ] `LOCAL_LISTENER` 已確認，非 1521 埠使用直接 ADDRESS。
- [ ] 已執行 `ALTER SYSTEM REGISTER`。
- [ ] 已檢查 `tnsnames.ora` 的既有 `<SID>` alias；正確則保留，否則新增或更新。
- [ ] 未重複新增 alias，且保留其他既有連線設定。
- [ ] Alias 的 `SERVICE_NAME` 對應實際目標服務。
- [ ] `lsnrctl services LSNR_<SID>` 顯示目標服務與 `READY` 狀態。
- [ ] `tnsping <SID>` 成功。
- [ ] `sqlplus system@<SID>` 成功，且 Instance、Service、Container 正確。

## Oracle 官方參考文件

- [Creating and Configuring an Oracle Database — DBCA 參數](https://docs.oracle.com/en/database/oracle/oracle-database/19/admin/creating-and-configuring-an-oracle-database.html)
- [Configuring and Administering Oracle Net Listener](https://docs.oracle.com/en/database/oracle/oracle-database/19/netag/configuring-and-administering-oracle-net-listener.html)
- [LOCAL_LISTENER](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/LOCAL_LISTENER.html)
- [Configuring the Network Environment](https://docs.oracle.com/en/database/oracle/oracle-database/19/admqs/configuring-the-network-environment.html)
- [Testing Connections](https://docs.oracle.com/en/database/oracle/oracle-database/19/netag/testing-connections.html)
