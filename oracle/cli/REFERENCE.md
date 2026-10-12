# Oracle table CLI reference

Entrypoint: `show-tables.ps1`

## Parameters

| Parameter | Type | Default | Required | Description |
|---|---|---|---|---|
| `-HostName` | string | Compose published host, else `127.0.0.1` | for a full explicit connection, yes with port, username, and password | Database host. Alias: `-host` |
| `-Port` | int | from Compose published port | for a full explicit connection, yes with host, username, and password | Database port |
| `-Username` | string | Compose `APP_USER` | for a full explicit connection, yes with host, port, and password | Database user. Uppercased before connect |
| `-Password` | string | Compose `APP_USER_PASSWORD` | for a full explicit connection, yes with host, port, and username | Database password. Passed to Java through `SHOW_TABLES_PASSWORD` |
| `-Service` | string | Compose `ORACLE_DATABASE`, else `XEPDB1` | no | Oracle service name. Alias: `-database`. Uppercased before connect |
| `-Compose` | string | first Compose file found walking up from the current directory | no | Path to a Compose file to read |
| `-Limit` | int | `0` | no | Max rows to print per table. `0` means every row. Rows are ordered by primary key when a limit is set |
| `-Where` | string | | no | SQL predicate appended to each selected-table query. Semicolons and comments are rejected |
| `-Width` | int | console-derived | no | Wrap width for field values. `0` means derive from the console width |
| `-List` | switch | | no | List tables in the user schema with row counts. Incompatible with table names |
| `-ShowConnection` | switch | | no | Print the resolved connection settings and exit without querying data |
| `-Help` | switch | | no | Print usage and exit 0 |
| table names | remaining arguments | | required unless `-List`, `-ShowConnection`, or `-Help` | One or more `TABLE` or `SCHEMA.TABLE` names |

Positional binding is off. Table names are remaining arguments only. Named parameters still need their own values.

## Commands the CLI runs

| Goal | Invocation shape |
|---|---|
| Help | `-Help`, or no tables and no `-List` / `-ShowConnection` |
| Connection check | `-ShowConnection` |
| Schema table list | `-List` |
| Row evidence | one or more table names, optional `-Limit` and `-Where` |

## Compose discovery

Search order from the current directory upward:

1. `docker-compose.yml`
2. `docker-compose.yaml`
3. `compose.yml`
4. `compose.yaml`

The parser picks the first service whose name is `oracle`, whose image name matches `oracle`, or whose environment defines `APP_USER`.

A sibling `.env` next to the Compose file is loaded before process environment variables. Compose `${VAR}` and `${VAR:-default}` forms are expanded.

## Output shape

### Connection header

```text
connection 127.0.0.1:1521/XEPDB1 user APP_USER
compose    C:\path\to\docker-compose.yml
```

### `-List`

```text
TABLE                 ROWS
-----                 ----
REP_PERSON            12
```

### Selected tables

Each table is a block bounded by `=` rules. Fields are labeled vertically. Null prints as `(null)`. Empty string prints as `(empty)`.

When `-Limit` shows fewer rows than the total, the block header is `rows N of TOTAL`.

## Files in this directory

| File | Role |
|---|---|
| `show-tables.ps1` | CLI entrypoint and formatter |
| `DbEvidence.java` | JDBC reader |
| `pom.xml` | `ojdbc11` dependency |
| `show-tables.tests.ps1` | Formatter and Compose parser checks |

## Errors the CLI raises before or during a run

- `-List` together with table names
- `-Where` together with `-List`
- Negative `-Limit`
- Missing Compose file when host, port, username, and password are not all provided
- Missing host, port, username, password, or service after Compose merge
- Invalid host, username, service, or table name characters
- `-Where` that contains `;`, `--`, `/*`, `*/`, or control characters
- Java 17+ not found
- `ojdbc11` 21.9.0.0 missing and Maven resolve failing
- `DbEvidence.java` compile failure
- Non-zero exit from the JDBC process
