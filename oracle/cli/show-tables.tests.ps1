$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\show-tables.ps1"

$failures = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param($Name, $Actual, $Expected)
    if ("$Actual" -ne "$Expected") {
        $failures.Add("$Name expected [$Expected] actual [$Actual]")
    }
}

function Assert-True {
    param($Name, [bool]$Condition)
    if (-not $Condition) { $failures.Add($Name) }
}

function New-TempDir {
    $dir = Join-Path $env:TEMP ("show-tables-test-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

$root = New-TempDir
try {
    $child = Join-Path $root 'nested'
    New-Item -ItemType Directory -Path $child | Out-Null
    $compose = Join-Path $root 'docker-compose.yml'
    @(
        'services:'
        '  redis:'
        '    image: redis:7'
        '    ports:'
        '      - "6379:6379"'
        '  oracle:'
        '    image: gvenzl/oracle-xe:21-slim'
        '    environment:'
        '      APP_USER: PUI_ADM'
        '      APP_USER_PASSWORD: secret'
        '    ports:'
        '      - "1522:1521"'
    ) | Set-Content -LiteralPath $compose -Encoding Ascii
    $found = Find-ComposeFile $child
    Assert-Equal 'compose walk' $found $compose
    $parsed = Read-OracleCompose $compose
    Assert-Equal 'host' $parsed.HostName '127.0.0.1'
    Assert-Equal 'port' $parsed.Port 1522
    Assert-Equal 'user' $parsed.Username 'PUI_ADM'
    Assert-Equal 'password' $parsed.Password 'secret'
    Assert-Equal 'service' $parsed.Service 'XEPDB1'

    $listCompose = Join-Path $root 'compose.yml'
    @(
        'services:'
        '  oracle:'
        '    image: gvenzl/oracle-xe:21-slim'
        '    environment:'
        '      - APP_USER=APP_USER_NAME'
        '      - APP_USER_PASSWORD=list-secret'
        '      - ORACLE_DATABASE=FREEPDB1'
        '    ports:'
        '      - "10.1.2.3:1529:1521"'
    ) | Set-Content -LiteralPath $listCompose -Encoding Ascii
    $listed = Read-OracleCompose $listCompose
    Assert-Equal 'list host' $listed.HostName '10.1.2.3'
    Assert-Equal 'list port' $listed.Port 1529
    Assert-Equal 'list user' $listed.Username 'APP_USER_NAME'
    Assert-Equal 'list service' $listed.Service 'FREEPDB1'

    $envDir = Join-Path $root 'envcase'
    New-Item -ItemType Directory -Path $envDir | Out-Null
    @(
        'SHOW_TABLES_TEST_PORT=1600'
        'SHOW_TABLES_TEST_PASSWORD=from-env-file'
    ) | Set-Content -LiteralPath (Join-Path $envDir '.env') -Encoding Ascii
    @(
        'services:'
        '  db:'
        '    image: gvenzl/oracle-xe:21-slim'
        '    environment:'
        '      APP_USER: ${SHOW_TABLES_TEST_USER:-PUI_ADM}'
        '      APP_USER_PASSWORD: ${SHOW_TABLES_TEST_PASSWORD:-unused}'
        '    ports:'
        '      - "${SHOW_TABLES_TEST_PORT:-1522}:1521"'
    ) | Set-Content -LiteralPath (Join-Path $envDir 'docker-compose.yml') -Encoding Ascii
    $substituted = Read-OracleCompose (Join-Path $envDir 'docker-compose.yml')
    Assert-Equal 'subst port' $substituted.Port 1600
    Assert-Equal 'subst user' $substituted.Username 'PUI_ADM'
    Assert-Equal 'subst password' $substituted.Password 'from-env-file'

    $none = Join-Path $root 'none.yml'
    @(
        'services:'
        '  api:'
        '    image: example/api:1'
    ) | Set-Content -LiteralPath $none -Encoding Ascii
    $threw = $false
    try { Read-OracleCompose $none } catch { $threw = $true }
    Assert-True 'missing oracle service fails' $threw

    $overridden = Resolve-DbConnection -Compose $parsed -Bound @{ Password = 'from-arg'; Port = 1700 } -HostName '' -Port 1700 -Username '' -Password 'from-arg' -Service ''
    Assert-Equal 'override password' $overridden.Password 'from-arg'
    Assert-Equal 'override port' $overridden.Port 1700
    Assert-Equal 'override keeps user' $overridden.Username 'PUI_ADM'

    $explicit = Get-ShowTablesConnection -HostName '10.0.0.5' -Port 1522 -Username 'pui_adm' -Password 'secret' -Service '' -Compose '' -Bound @{
        HostName = '10.0.0.5'
        Port = 1522
        Username = 'pui_adm'
        Password = 'secret'
    }
    Assert-Equal 'explicit host' $explicit.HostName '10.0.0.5'
    Assert-Equal 'explicit user' $explicit.Username 'PUI_ADM'
    Assert-Equal 'explicit service' $explicit.Service 'XEPDB1'
    Assert-Equal 'explicit compose unused' $explicit.ComposePath ''

    $badName = $false
    try { Resolve-TableRef 'REP_PERSON;DROP' 'PUI_ADM' } catch { $badName = $true }
    Assert-True 'rejects unsafe table name' $badName
    $ref = Resolve-TableRef 'rep_person' 'pui_adm'
    Assert-Equal 'schema' $ref.Schema 'PUI_ADM'
    Assert-Equal 'table' $ref.Table 'REP_PERSON'

    $whereBad = $false
    try { Test-WhereText '1=1; delete from REP_PERSON' } catch { $whereBad = $true }
    Assert-True 'rejects semicolon in where' $whereBad

    $long = 'Z' * 50
    $parts = @(Split-EvidenceValue -Text $long -Width 20)
    Assert-Equal 'wrap keeps every character' (-join $parts) $long
    Assert-True 'wrap uses more than one line' ($parts.Count -gt 1)

    $sentence = 'alpha beta gamma delta epsilon'
    $wordParts = @(Split-EvidenceValue -Text $sentence -Width 12)
    Assert-Equal 'word wrap keeps spaces' (-join $wordParts) $sentence

    $json = '{"telefono":"5512345678","nombre":"Ana, \"N\""}'
    $pretty = Format-JsonText $json
    Assert-True 'json is split onto lines' ($pretty.Contains("`n"))
    $again = $pretty | ConvertFrom-Json
    Assert-Equal 'json phone' $again.telefono '5512345678'
    Assert-Equal 'json name' $again.nombre 'Ana, "N"'

    $rows = @(
        @{ ALPHA_COLUMN = $long; BETA_COLUMN = $null }
        @{ ALPHA_COLUMN = 'short'; BETA_COLUMN = 'second' }
    )
    $rendered = Format-TableEvidence -Title 'PUI_ADM.SAMPLE' -Columns @('ALPHA_COLUMN', 'BETA_COLUMN') -Rows $rows -Total 2 -ValueWidth 20
    $zCount = @($rendered.ToCharArray() | Where-Object { $_ -eq 'Z' }).Count
    Assert-Equal 'full wide value' $zCount 50
    Assert-True 'beta is on its own line' ($rendered -match '(?m)^BETA_COLUMN +\(null\)\r?$')
    Assert-True 'second row is separated' ($rendered.Contains('-- row 2 of 2 --'))
    Assert-True 'no line holds both column names' (-not ($rendered -match 'ALPHA_COLUMN.*BETA_COLUMN'))

    $oneRow = New-Object 'System.Collections.Generic.List[object]'
    $oneRow.Add(@{ ALPHA_COLUMN = 'one'; BETA_COLUMN = $null })
    $fromList = Format-TableEvidence -Title 'PUI_ADM.SAMPLE' -Columns @('ALPHA_COLUMN', 'BETA_COLUMN') -Rows $oneRow -Total 1 -ValueWidth 20
    Assert-True 'one generic-list row shows its value' ($fromList.Contains('one'))
    Assert-True 'one generic-list row shows null' ($fromList -match '(?m)^BETA_COLUMN +\(null\)\r?$')

    $empty = Format-TableEvidence -Title 'PUI_ADM.EMPTY' -Columns @('ID', 'NAME') -Rows @() -Total 0 -ValueWidth 40
    Assert-True 'empty table names its columns' ($empty.Contains('columns ID, NAME'))
    Assert-True 'empty table says no rows' ($empty.Contains('(no rows)'))
    Assert-True 'tables use a rule' ($empty.Contains(('=' * 80)))

    $other = Format-TableEvidence -Title 'PUI_ADM.OTHER' -Columns @('ID') -Rows @(@{ ID = '1' }) -Total 5 -ValueWidth 40
    $report = $rendered + "`r`n`r`n" + $other
    $first = $report.IndexOf('PUI_ADM.SAMPLE')
    $second = $report.IndexOf('PUI_ADM.OTHER')
    Assert-True 'second table follows the first' ($second -gt $first)
    Assert-True 'limited rows say the total' ($other.Contains('rows 1 of 5'))

    $protocol = @"
TABLE PUI_ADM.REP_PERSON
COLUMNS ["ID","PHONE"]
TOTAL 1
ROW {"ID":"abc","PHONE":null}
END
TABLE PUI_ADM.MISSING
ERROR ORA-00942: table or view does not exist
END
"@
    $parsedProtocol = @(Read-EvidenceProtocol $protocol)
    Assert-Equal 'protocol tables' $parsedProtocol.Count 2
    Assert-Equal 'protocol id' $parsedProtocol[0].Rows[0]['ID'] 'abc'
    Assert-True 'protocol null phone' ($null -eq $parsedProtocol[0].Rows[0]['PHONE'])
    Assert-Equal 'protocol error' $parsedProtocol[1].Error 'ORA-00942: table or view does not exist'

    $check = Format-ConnectionCheck @{
        HostName = '127.0.0.1'
        Port = 1522
        Service = 'XEPDB1'
        Username = 'PUI_ADM'
        Password = 'secret'
        ComposePath = $compose
    }
    Assert-True 'connection check hides the password' ($check.Contains('password   (set)'))
    Assert-True 'connection check does not print the password' (-not $check.Contains('secret'))

    $repoCompose = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\docker-compose.yml'))
    if (Test-Path -LiteralPath $repoCompose) {
        $real = Read-OracleCompose $repoCompose
        Assert-Equal 'repo host' $real.HostName '127.0.0.1'
        Assert-Equal 'repo port' $real.Port 1522
        Assert-Equal 'repo user' $real.Username 'PUI_ADM'
        Assert-Equal 'repo service' $real.Service 'XEPDB1'
        Assert-True 'repo password is present' (-not [string]::IsNullOrWhiteSpace($real.Password))
    }

    $javaHome = Find-JavaHome
    $jar = Find-OjdbcJar $PSScriptRoot
    $classDir = Compile-DbEvidence -JavaHome $javaHome -JarPath $jar
    $text = 'Ana ' + [char]0x00E1 + ' "\path'
    $requestPath = Join-Path $env:TEMP ("show-tables-encode-" + [guid]::NewGuid().ToString('n') + '.txt')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllLines($requestPath, @('command=encode', "text=$text"), $utf8)
    try {
        $encoded = Invoke-DbEvidence -JavaHome $javaHome -ClassDir $classDir -JarPath $jar -RequestPath $requestPath -Password 'unused'
    } finally {
        Remove-Item -LiteralPath $requestPath -ErrorAction SilentlyContinue
    }
    Assert-Equal 'encode exit' $encoded.Code 0
    $roundTrip = ($encoded.Out.Trim()) | ConvertFrom-Json
    Assert-Equal 'encode round trip' $roundTrip $text
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output $_ }
    exit 1
}
Write-Output "show-tables tests passed"
exit 0
