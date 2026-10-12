# How to print Oracle table evidence

Use this CLI when you need readable terminal evidence of rows in a local Oracle database. Each table is its own block. Each field is on its own line, with the full value. JSON-looking values are pretty-printed when they parse as JSON.

## Requirements

- JDK 17 or newer
- Maven 3+ the first time `ojdbc11` is not already in your local Maven repository
- An Oracle database reachable with the Compose user, for example gvenzl Oracle XE

## Connection defaults

Pass `-HostName`, `-Port`, `-Username`, and `-Password` when you want an explicit connection.

When you omit any of those, the command walks up from the current directory and reads the first `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, or `compose.yaml` it finds. From the Oracle service it takes:

- the published host port
- `APP_USER`
- `APP_USER_PASSWORD`
- `ORACLE_DATABASE`

The host defaults to `127.0.0.1`. The service name defaults to `XEPDB1` when `ORACLE_DATABASE` is absent. A flag you pass replaces the matching Compose value.

Run the command from the project that owns that Compose file, or pass `-Compose` with the file path.

## Check the resolved connection

```powershell
.\show-tables.ps1 -ShowConnection
```

The output shows host, port, service, username, whether the password is set, and which Compose file was used. It does not print the password.

## List tables in the user schema

```powershell
.\show-tables.ps1 -List
```

## Print every row of selected tables

Pass one or more table names after the flags:

```powershell
.\show-tables.ps1 REP_PERSON REP_PERSON_ADDRESS BATCH_PROCESS
```

Unqualified names use the connected username as the schema. You can also pass `SCHEMA.TABLE`.

## Limit how many rows print

```powershell
.\show-tables.ps1 -Limit 20 REPORT_SNAPSHOT
```

`-Limit N` prints the first N rows in primary-key order and shows the total count. Omit `-Limit`, or pass `0`, to print every row.

## Filter rows

```powershell
.\show-tables.ps1 -Where "PERSON_ID = 1" REP_PERSON
```

`-Where` is appended to the query for every selected table. Keep semicolons and SQL comments out of it.

## Pass an explicit connection

```powershell
.\show-tables.ps1 -HostName 127.0.0.1 -Port 1522 -Username PUI_ADM -Password secret -Service XEPDB1 REP_PERSON
```

## Point at a specific Compose file

```powershell
.\show-tables.ps1 -Compose C:\path\to\docker-compose.yml -List
```

## Show built-in help

```powershell
.\show-tables.ps1 -Help
```

## Flag reference

See [REFERENCE.md](REFERENCE.md) for every parameter, default, and constraint.
