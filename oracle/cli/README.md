# Oracle table CLI

Prints selected tables from a local Oracle database. Each table is a separate block. Each field is on its own line, with the full value.

Connection values come from `-HostName`, `-Port`, `-Username`, and `-Password`. When you omit one, the command reads `docker-compose.yml` from the project where you run it. It uses the published host port, `APP_USER`, `APP_USER_PASSWORD`, and `ORACLE_DATABASE`. The host defaults to `127.0.0.1`. The service defaults to `XEPDB1` when `ORACLE_DATABASE` is absent.

## Requirements

- JDK 17+
- Maven 3+, the first time `ojdbc11` is not already in the local Maven repository
- An Oracle database reachable with the user in Compose, for example gvenzl Oracle XE

## Usage

From this directory, or pass the script path from the project that has Compose:

```powershell
.\show-tables.ps1 -List
.\show-tables.ps1 REP_PERSON REP_PERSON_ADDRESS BATCH_PROCESS
.\show-tables.ps1 -Limit 20 REPORT_SNAPSHOT
.\show-tables.ps1 -Where "PERSON_ID = 1" REP_PERSON
.\show-tables.ps1 -ShowConnection
```

`-Limit N` prints the first N rows in primary-key order and the total count. Omit `-Limit` to print every row. `-Where` is appended to the query. Do not put a semicolon or a comment in it.

```powershell
.\show-tables.ps1 -Help
```

## Files

| File | Role |
|---|---|
| `show-tables.ps1` | CLI entrypoint |
| `DbEvidence.java` | JDBC reader |
| `pom.xml` | Oracle JDBC dependency |
| `show-tables.tests.ps1` | Formatter and Compose parser checks |
