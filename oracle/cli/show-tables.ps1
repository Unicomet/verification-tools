<#
.SYNOPSIS
Prints selected Oracle tables as terminal evidence.

.DESCRIPTION
Reads host, port, username, and password from arguments or from the
docker-compose.yml of the project where the command runs. Each table is a
separate block and each field is on its own line, with the full value.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('host')]
    [string]$HostName,
    [int]$Port,
    [string]$Username,
    [string]$Password,
    [Alias('database')]
    [string]$Service,
    [string]$Compose,
    [int]$Limit = 0,
    [string]$Where,
    [int]$Width = 0,
    [switch]$List,
    [switch]$ShowConnection,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Table
)

function Get-UsageText {
    $lines = @(
        'Show records from selected Oracle tables.'
        ''
        'Each table is a separate block. Each field is on its own line, with the full value.'
        ''
        'Pass -HostName, -Port, -Username, and -Password to choose the database.'
        'When you omit one, the command reads docker-compose.yml, walking up from'
        'the directory where you run it. It uses the published host port, APP_USER,'
        'APP_USER_PASSWORD, and ORACLE_DATABASE. The host defaults to 127.0.0.1.'
        'The service defaults to XEPDB1 when ORACLE_DATABASE is absent.'
        'A flag replaces the value read from Compose.'
        ''
        '  .\show-tables.ps1 -List'
        '  .\show-tables.ps1 REP_PERSON REP_PERSON_ADDRESS BATCH_PROCESS'
        '  .\show-tables.ps1 -Limit 20 REPORT_SNAPSHOT'
        '  .\show-tables.ps1 -Where "PERSON_ID = 1" REP_PERSON REP_PERSON_ADDRESS'
        '  .\show-tables.ps1 -HostName 127.0.0.1 -Port 1522 -Username PUI_ADM -Password secret -Service XEPDB1 REP_PERSON'
        '  .\show-tables.ps1 -ShowConnection'
        ''
        'Example tables:'
        ''
        '  REPORT_SNAPSHOT, REPORT_INGEST_CURSOR, REPORT_INGEST_FAILURE,'
        '  REP_PERSON, REP_PERSON_ADDRESS, BATCH_PROCESS, REPORT_REQUEST'
        ''
        '-Limit N prints the first N rows in primary-key order and the total count.'
        'Omit -Limit to print every row.'
        '-Where is appended to the query. Do not put a semicolon or a comment in it.'
    )
    return ($lines -join "`r`n")
}

function ConvertFrom-ComposeScalar {
    param([string]$Text)
    $text = $Text.Trim()
    if ($text.StartsWith('"')) {
        $end = $text.LastIndexOf('"')
        if ($end -gt 0) { return $text.Substring(1, $end - 1) }
    }
    if ($text.StartsWith("'")) {
        $end = $text.LastIndexOf("'")
        if ($end -gt 0) { return $text.Substring(1, $end - 1) }
    }
    $comment = $text.IndexOf(' #')
    if ($comment -ge 0) { $text = $text.Substring(0, $comment).Trim() }
    return $text
}

function Expand-ComposeValue {
    param(
        [string]$Value,
        [hashtable]$Variables
    )
    $pattern = '\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $name = $match.Groups[1].Value
        $hasDefault = $match.Groups[2].Success
        $present = $Variables.ContainsKey($name) -and $null -ne $Variables[$name] -and "$($Variables[$name])" -ne ''
        if ($present) { return [string]$Variables[$name] }
        if ($hasDefault) { return $match.Groups[2].Value }
        return ''
    }
    return [regex]::Replace($Value, $pattern, $evaluator)
}

function Read-DotEnv {
    param([string]$Path)
    $values = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).Trim() }
        $split = $line.IndexOf('=')
        if ($split -lt 1) { continue }
        $key = $line.Substring(0, $split).Trim()
        $value = ConvertFrom-ComposeScalar $line.Substring($split + 1)
        $values[$key] = $value
    }
    return $values
}

function ConvertFrom-PortMapping {
    param([string]$Mapping)
    $bits = $Mapping.Split(':')
    if ($bits.Count -eq 1) {
        throw "Compose port '$Mapping' has no fixed host port. Pass -Port."
    }
    if ($bits.Count -eq 2 -and $bits[0] -match '^\d+$') {
        return @{ HostName = '127.0.0.1'; Port = [int]$bits[0] }
    }
    if ($bits.Count -eq 3 -and $bits[1] -match '^\d+$') {
        return @{ HostName = $bits[0]; Port = [int]$bits[1] }
    }
    throw "Cannot read the published port from '$Mapping'."
}

function Read-OracleCompose {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Compose file not found: $Path"
    }
    $variables = @{}
    $envPath = Join-Path (Split-Path -Parent $Path) '.env'
    if (Test-Path -LiteralPath $envPath) {
        foreach ($entry in (Read-DotEnv $envPath).GetEnumerator()) {
            $variables[$entry.Key] = [string]$entry.Value
        }
    }
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $variables[[string]$entry.Key] = [string]$entry.Value
    }

    $inServices = $false
    $servicesIndent = -1
    $service = $null
    $serviceIndent = -1
    $section = $null
    $sectionIndent = -1
    $found = New-Object System.Collections.Generic.List[object]

    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Replace("`t", '  ')
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        $indent = $line.Length - $line.TrimStart(' ').Length
        $trim = $line.Trim()

        if ($trim -eq 'services:') {
            $inServices = $true
            $servicesIndent = $indent
            $service = $null
            $section = $null
            continue
        }
        if (-not $inServices) { continue }
        if ($indent -le $servicesIndent) {
            $inServices = $false
            $service = $null
            $section = $null
            continue
        }
        if ($service -and $indent -le $serviceIndent) {
            $service = $null
            $section = $null
        }
        if ($section -and $indent -le $sectionIndent) {
            $section = $null
        }
        if (-not $service) {
            if ($trim -match '^([A-Za-z0-9_-]+):\s*$') {
                $service = @{
                    Name = $Matches[1]
                    Image = ''
                    Env = @{}
                    Ports = New-Object System.Collections.Generic.List[string]
                }
                $serviceIndent = $indent
                $found.Add($service)
            }
            continue
        }
        if (-not $section) {
            if ($trim -match '^image:\s*(.+)$') {
                $service.Image = Expand-ComposeValue (ConvertFrom-ComposeScalar $Matches[1]) $variables
                continue
            }
            if ($trim -eq 'environment:' -or $trim -eq 'ports:') {
                $section = $trim.TrimEnd(':')
                $sectionIndent = $indent
                continue
            }
            continue
        }
        if ($section -eq 'environment') {
            $item = $trim
            if ($item -match '^-\s*(.+)$') { $item = $Matches[1].Trim() }
            if ($item -match '^([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(.*)$') {
                $key = $Matches[1]
                $value = Expand-ComposeValue (ConvertFrom-ComposeScalar $Matches[2]) $variables
                $service.Env[$key] = $value
            }
            continue
        }
        if ($section -eq 'ports' -and $trim -match '^-\s*(.+)$') {
            $published = Expand-ComposeValue (ConvertFrom-ComposeScalar $Matches[1]) $variables
            $service.Ports.Add($published)
        }
    }

    $oracle = $null
    foreach ($item in $found) {
        if ($item.Name -eq 'oracle' -or $item.Image -match 'oracle') {
            $oracle = $item
            break
        }
    }
    if (-not $oracle) {
        foreach ($item in $found) {
            if ($item.Env.ContainsKey('APP_USER')) {
                $oracle = $item
                break
            }
        }
    }
    if (-not $oracle) {
        throw "No Oracle service found in $Path."
    }

    $hostName = '127.0.0.1'
    $port = 0
    if ($oracle.Ports.Count -gt 0) {
        $mapped = ConvertFrom-PortMapping $oracle.Ports[0]
        if ($mapped.HostName) { $hostName = $mapped.HostName }
        $port = $mapped.Port
    }
    $serviceName = [string]$oracle.Env['ORACLE_DATABASE']
    if (-not $serviceName) { $serviceName = 'XEPDB1' }
    return @{
        HostName = $hostName
        Port = $port
        Username = [string]$oracle.Env['APP_USER']
        Password = [string]$oracle.Env['APP_USER_PASSWORD']
        Service = $serviceName
        ComposePath = (Resolve-Path -LiteralPath $Path).Path
    }
}

function Find-ComposeFile {
    param([string]$Start)
    $dir = [IO.Path]::GetFullPath($Start)
    while ($true) {
        foreach ($name in @('docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml')) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}

function Resolve-DbConnection {
    param(
        [hashtable]$Compose,
        [hashtable]$Bound,
        [string]$HostName,
        [int]$Port,
        [string]$Username,
        [string]$Password,
        [string]$Service
    )
    $result = @{
        HostName = [string]$Compose.HostName
        Port = [int]$Compose.Port
        Username = [string]$Compose.Username
        Password = [string]$Compose.Password
        Service = [string]$Compose.Service
        ComposePath = [string]$Compose.ComposePath
    }
    if ($Bound.ContainsKey('HostName') -and $HostName) { $result.HostName = $HostName }
    if ($Bound.ContainsKey('Port')) { $result.Port = $Port }
    if ($Bound.ContainsKey('Username') -and $Username) { $result.Username = $Username }
    if ($Bound.ContainsKey('Password') -and $null -ne $Password -and $Password -ne '') {
        $result.Password = $Password
    }
    if ($Bound.ContainsKey('Service') -and $Service) { $result.Service = $Service }
    if (-not $result.Service) { $result.Service = 'XEPDB1' }

    $missing = @()
    if (-not $result.HostName) { $missing += 'host (-HostName)' }
    if ($result.Port -lt 1 -or $result.Port -gt 65535) { $missing += 'port (-Port)' }
    if (-not $result.Username) { $missing += 'username (-Username)' }
    if (-not $result.Password) { $missing += 'password (-Password)' }
    if (-not $result.Service) { $missing += 'service (-Service)' }
    if ($missing.Count -gt 0) {
        throw ("Missing connection settings: " + ($missing -join ', ') + ". Pass them, or run the command in a project whose docker-compose.yml defines the Oracle service.")
    }
    if ($result.HostName -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "Invalid host '$($result.HostName)'."
    }
    if ($result.Username -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$') {
        throw "Invalid username '$($result.Username)'."
    }
    if ($result.Service -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$') {
        throw "Invalid service '$($result.Service)'."
    }
    $result.Username = $result.Username.ToUpperInvariant()
    $result.Service = $result.Service.ToUpperInvariant()
    return $result
}

function Get-ShowTablesConnection {
    param(
        [string]$HostName,
        [int]$Port,
        [string]$Username,
        [string]$Password,
        [string]$Service,
        [string]$Compose,
        [hashtable]$Bound
    )
    $composeData = @{
        HostName = ''
        Port = 0
        Username = ''
        Password = ''
        Service = ''
        ComposePath = ''
    }
    $explicit = $Bound.ContainsKey('HostName') -and $Bound.ContainsKey('Port') -and $Bound.ContainsKey('Username') -and $Bound.ContainsKey('Password')
    if ($Compose -or -not $explicit) {
        $path = $Compose
        if (-not $path) { $path = Find-ComposeFile (Get-Location) }
        if (-not $path) {
            if (-not $explicit) {
                throw 'docker-compose.yml was not found from the current directory, and host, port, username, and password were not all provided.'
            }
        } else {
            $composeData = Read-OracleCompose $path
        }
    }
    return Resolve-DbConnection -Compose $composeData -Bound $Bound -HostName $HostName -Port $Port -Username $Username -Password $Password -Service $Service
}

function Resolve-TableRef {
    param(
        [string]$Name,
        [string]$DefaultSchema
    )
    $parts = $Name.Split('.')
    if ($parts.Count -lt 1 -or $parts.Count -gt 2 -or $Name.Length -eq 0) {
        throw "Invalid table name '$Name'."
    }
    foreach ($part in $parts) {
        if ($part -notmatch '^[A-Za-z][A-Za-z0-9_$#]{0,127}$') {
            throw "Invalid table name '$Name'."
        }
    }
    if ($parts.Count -eq 1) {
        return @{ Schema = $DefaultSchema.ToUpperInvariant(); Table = $parts[0].ToUpperInvariant() }
    }
    return @{ Schema = $parts[0].ToUpperInvariant(); Table = $parts[1].ToUpperInvariant() }
}

function Test-WhereText {
    param([string]$Where)
    if ($Where -match ';|--|/\*|\*/') {
        throw 'The where clause cannot contain ; or comments.'
    }
    foreach ($ch in $Where.ToCharArray()) {
        if ([int]$ch -lt 32 -and $ch -ne "`t") {
            throw 'The where clause cannot contain control characters.'
        }
    }
}

function Format-JsonText {
    param([string]$Text)
    $trim = $Text.Trim()
    if ($trim.Length -lt 2) { return $Text }
    $first = $trim[0]
    if ($first -ne '{' -and $first -ne '[') { return $Text }
    try {
        $null = $trim | ConvertFrom-Json
    } catch {
        return $Text
    }
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escape = $false
    foreach ($c in $trim.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($c)
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ([char]::IsWhiteSpace($c)) { continue }
        switch ($c) {
            '"' {
                $inString = $true
                [void]$sb.Append($c)
            }
            '{' {
                [void]$sb.Append('{')
                $indent++
                [void]$sb.Append("`r`n" + ('    ' * $indent))
            }
            '[' {
                [void]$sb.Append('[')
                $indent++
                [void]$sb.Append("`r`n" + ('    ' * $indent))
            }
            '}' {
                $indent = [Math]::Max(0, $indent - 1)
                [void]$sb.Append("`r`n" + ('    ' * $indent))
                [void]$sb.Append('}')
            }
            ']' {
                $indent = [Math]::Max(0, $indent - 1)
                [void]$sb.Append("`r`n" + ('    ' * $indent))
                [void]$sb.Append(']')
            }
            ',' { [void]$sb.Append(',' + "`r`n" + ('    ' * $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

function Format-EvidenceValue {
    param(
        $Value,
        [int]$ValueWidth
    )
    if ($null -eq $Value) { return '(null)' }
    $text = [string]$Value
    if ($text.Length -eq 0) { return '(empty)' }
    if ($ValueWidth -gt 0 -and $text.Length -le $ValueWidth -and $text.IndexOf("`n") -lt 0) {
        return $text
    }
    $pretty = Format-JsonText $text
    if ($pretty -ne $text) { return $pretty }
    return $text
}

function Split-EvidenceValue {
    param(
        [string]$Text,
        [int]$Width
    )
    $result = New-Object System.Collections.Generic.List[string]
    $paragraphs = $Text -split "`r?`n", -1
    foreach ($paragraph in $paragraphs) {
        if ($Width -le 0 -or $paragraph.Length -le $Width) {
            $result.Add($paragraph)
            continue
        }
        $rest = $paragraph
        while ($rest.Length -gt $Width) {
            $chunk = $rest.Substring(0, $Width)
            $break = $chunk.LastIndexOf(' ')
            if ($break -ge [Math]::Floor($Width / 2)) {
                $result.Add($rest.Substring(0, $break))
                $rest = $rest.Substring($break)
            } else {
                $result.Add($chunk)
                $rest = $rest.Substring($Width)
            }
        }
        $result.Add($rest)
    }
    if ($result.Count -eq 0) { $result.Add('') }
    return $result
}

function Get-EvidenceWidth {
    param(
        [int]$Requested,
        [int]$LabelWidth
    )
    if ($Requested -gt 0) { return $Requested }
    $window = 100
    try {
        $consoleWidth = [int]$Host.UI.RawUI.WindowSize.Width
        if ($consoleWidth -ge 60 -and $consoleWidth -le 200) { $window = $consoleWidth }
    } catch {
        $window = 100
    }
    $value = $window - $LabelWidth - 2
    if ($value -lt 24) { return 24 }
    return $value
}

function Copy-ItemList {
    param($Value)
    $items = New-Object System.Collections.ArrayList
    if ($null -eq $Value) { return ,$items }
    if ($Value -is [string]) {
        [void]$items.Add($Value)
        return ,$items
    }
    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            [void]$items.Add($Value[$index])
        }
        return ,$items
    }
    [void]$items.Add($Value)
    return ,$items
}

function Format-TableEvidence {
    param(
        [string]$Title,
        [string[]]$Columns,
        $Rows,
        [long]$Total,
        [string]$ErrorMessage,
        [int]$ValueWidth = 0
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $rule = '=' * 80
    $lines.Add($rule)
    $lines.Add($Title)
    if ($ErrorMessage) {
        $lines.Add("error $($ErrorMessage.Trim())")
        $lines.Add($rule)
        return ($lines -join "`r`n")
    }
    $rowItems = Copy-ItemList $Rows
    $shown = $rowItems.Count
    if ($shown -ne $Total) {
        $lines.Add("rows $shown of $Total")
    } else {
        $lines.Add("rows $Total")
    }
    $lines.Add($rule)
    $lines.Add('')
    if ($shown -eq 0) {
        if ((Copy-ItemList $Columns).Count -gt 0) {
            $lines.Add('columns ' + ($Columns -join ', '))
            $lines.Add('')
        }
        $lines.Add('(no rows)')
        return ($lines -join "`r`n")
    }
    $labelWidth = 0
    foreach ($col in $Columns) {
        if ($col.Length -gt $labelWidth) { $labelWidth = $col.Length }
    }
    if ($ValueWidth -le 0) {
        $ValueWidth = Get-EvidenceWidth -Requested 0 -LabelWidth $labelWidth
    }
    $rowNumber = 0
    foreach ($row in $rowItems) {
        $rowNumber++
        if ($rowNumber -gt 1) { $lines.Add('') }
        $lines.Add("-- row $rowNumber of $shown --")
        foreach ($col in $Columns) {
            $value = $null
            if ($row -is [System.Collections.IDictionary]) {
                if ($row.Contains($col)) { $value = $row[$col] }
            } elseif ($row.ContainsKey($col)) {
                $value = $row[$col]
            }
            $text = Format-EvidenceValue -Value $value -ValueWidth $ValueWidth
            $wrapped = Split-EvidenceValue -Text $text -Width $ValueWidth
            $pad = $col.PadRight($labelWidth)
            $first = $true
            foreach ($part in $wrapped) {
                if ($first) {
                    $lines.Add("$pad  $part")
                    $first = $false
                } else {
                    $lines.Add((' ' * ($labelWidth + 2)) + $part)
                }
            }
        }
    }
    return ($lines -join "`r`n")
}

function Format-TableList {
    param($Items)
    $itemList = Copy-ItemList $Items
    $nameWidth = 5
    foreach ($item in $itemList) {
        if ($item.Name.Length -gt $nameWidth) { $nameWidth = $item.Name.Length }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('TABLE'.PadRight($nameWidth) + '  ROWS'))
    $lines.Add(('-' * $nameWidth) + '  ----')
    if ($itemList.Count -eq 0) {
        $lines.Add('(no tables)')
    }
    foreach ($item in $itemList) {
        if ($item.Error) {
            $lines.Add($item.Name.PadRight($nameWidth) + '  error ' + $item.Error)
        } else {
            $lines.Add($item.Name.PadRight($nameWidth) + '  ' + $item.Count)
        }
    }
    return ($lines -join "`r`n")
}

function Format-ConnectionCheck {
    param($Connection)
    $passwordState = if ($Connection.Password) { '(set)' } else { '(missing)' }
    $compose = if ($Connection.ComposePath) { $Connection.ComposePath } else { '(not used)' }
    $lines = @(
        "host       $($Connection.HostName)"
        "port       $($Connection.Port)"
        "service    $($Connection.Service)"
        "username   $($Connection.Username)"
        "password   $passwordState"
        "compose    $compose"
    )
    return ($lines -join "`r`n")
}

function Read-EvidenceProtocol {
    param([string]$Text)
    $lines = @($Text -split "`r?`n")
    $tables = New-Object System.Collections.Generic.List[object]
    $index = 0
    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        if ($line -notlike 'TABLE *') {
            $index++
            continue
        }
        $table = @{
            Title = $line.Substring(6).Trim()
            Error = $null
            Columns = @()
            Rows = New-Object System.Collections.Generic.List[object]
            Total = [long]0
        }
        $index++
        while ($index -lt $lines.Count -and $lines[$index] -ne 'END') {
            $rowLine = $lines[$index]
            if ($rowLine -like 'ERROR *') {
                $table.Error = $rowLine.Substring(6)
            } elseif ($rowLine -like 'COLUMNS *') {
                $parsedColumns = ConvertFrom-Json $rowLine.Substring(8)
                $names = New-Object System.Collections.Generic.List[string]
                if ($parsedColumns -is [System.Array]) {
                    foreach ($name in $parsedColumns) { $names.Add([string]$name) }
                } elseif ($null -ne $parsedColumns) {
                    $names.Add([string]$parsedColumns)
                }
                $table.Columns = $names.ToArray()
            } elseif ($rowLine -like 'TOTAL *') {
                $table.Total = [long]$rowLine.Substring(6)
            } elseif ($rowLine -like 'ROW *') {
                $obj = ConvertFrom-Json $rowLine.Substring(4)
                $map = @{}
                foreach ($col in $table.Columns) {
                    $prop = $obj.PSObject.Properties[$col]
                    if ($prop) { $map[$col] = $prop.Value } else { $map[$col] = $null }
                }
                $table.Rows.Add($map)
            }
            $index++
        }
        $tables.Add($table)
        $index++
    }
    return $tables
}

function Read-ListProtocol {
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -notlike 'LIST *') { continue }
        $rest = $line.Substring(5)
        if ($rest -match '^(\S+)\s+ERROR\s+(.*)$') {
            $items.Add(@{ Name = $Matches[1]; Count = $null; Error = $Matches[2] })
        } elseif ($rest -match '^(\S+)\s+(\d+)$') {
            $items.Add(@{ Name = $Matches[1]; Count = [long]$Matches[2]; Error = $null })
        }
    }
    return $items
}

function Find-JavaHome {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:JAVA_HOME) { $candidates.Add($env:JAVA_HOME) }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft'),
        (Join-Path $env:ProgramFiles 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Java')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -like 'jdk-*') { $candidates.Add($_.FullName) }
        }
    }
    foreach ($candidateHome in $candidates) {
        $java = Join-Path $candidateHome 'bin\java.exe'
        $release = Join-Path $candidateHome 'release'
        if (-not (Test-Path -LiteralPath $java)) { continue }
        if (-not (Test-Path -LiteralPath $release)) { continue }
        $text = Get-Content -LiteralPath $release -Raw
        if ($text -match 'JAVA_VERSION="(\d+)') {
            if ([int]$Matches[1] -ge 17) { return $candidateHome }
        }
    }
    throw 'Java 17 or newer is required. Set JAVA_HOME to that installation.'
}

function Find-OjdbcJar {
    param([string]$ToolRoot)
    $preferred = Join-Path $env:USERPROFILE '.m2\repository\com\oracle\database\jdbc\ojdbc11\21.9.0.0\ojdbc11-21.9.0.0.jar'
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    $mvn = Get-Command mvn -ErrorAction SilentlyContinue
    if (-not $mvn) {
        throw 'ojdbc11 21.9.0.0 was not found and mvn is not on PATH.'
    }
    $pom = Join-Path $ToolRoot 'pom.xml'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $mvn.Source -f $pom -q dependency:resolve
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "Could not resolve ojdbc11. Maven exited $code." }
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    throw "ojdbc11 21.9.0.0 was not found after Maven resolve. Expected $preferred."
}

function Compile-DbEvidence {
    param(
        [string]$JavaHome,
        [string]$JarPath
    )
    $source = Join-Path $PSScriptRoot 'DbEvidence.java'
    $out = Join-Path $env:TEMP 'verification-tools-show-tables'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $classFile = Join-Path $out 'DbEvidence.class'
    $stampPath = Join-Path $out 'stamp.txt'
    $sourceTime = (Get-Item -LiteralPath $source).LastWriteTimeUtc.Ticks
    $jarTime = (Get-Item -LiteralPath $JarPath).LastWriteTimeUtc.Ticks
    $expected = "$sourceTime|$jarTime|$JarPath"
    $current = ''
    if (Test-Path -LiteralPath $stampPath) { $current = (Get-Content -LiteralPath $stampPath -Raw).Trim() }
    if ((Test-Path -LiteralPath $classFile) -and $current -eq $expected) { return $out }
    $javac = Join-Path $JavaHome 'bin\javac.exe'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $javac -encoding UTF-8 -cp $JarPath -d $out $source
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw 'Could not compile DbEvidence.java.' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($stampPath, $expected, $utf8)
    return $out
}

function Invoke-DbEvidence {
    param(
        [string]$JavaHome,
        [string]$ClassDir,
        [string]$JarPath,
        [string]$RequestPath,
        [string]$Password
    )
    $java = Join-Path $JavaHome 'bin\java.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $java
    $psi.Arguments = "-Dfile.encoding=UTF-8 -cp `"$ClassDir;$JarPath`" DbEvidence `"$RequestPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['SHOW_TABLES_PASSWORD'] = [string]$Password
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    [void]$process.WaitForExit()
    return @{
        Code = $process.ExitCode
        Out = $outTask.Result
        Err = $errTask.Result
    }
}

function Invoke-ShowTables {
    $script:ShowTablesCode = 1
    if ($Help) {
        Write-Output (Get-UsageText)
        $script:ShowTablesCode = 0
        return
    }
    $tableNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Table) {
        if ($name) { $tableNames.Add([string]$name) }
    }
    if ($List -and $tableNames.Count -gt 0) {
        throw 'Pass -List or table names, not both.'
    }
    if ($Where -and $List) {
        throw '-Where applies to selected tables. Omit -List.'
    }
    if ($Limit -lt 0) {
        throw '-Limit must be 0 or greater. 0 prints every row.'
    }
    if (-not $List -and -not $ShowConnection -and $tableNames.Count -eq 0) {
        Write-Output (Get-UsageText)
        return
    }
    if ($Where) { Test-WhereText $Where }

    $bound = $script:ShowTablesBound
    if (-not $bound) { $bound = @{} }
    $connection = Get-ShowTablesConnection -HostName $HostName -Port $Port -Username $Username -Password $Password -Service $Service -Compose $Compose -Bound $bound
    if ($ShowConnection) {
        Write-Output (Format-ConnectionCheck $connection)
        $script:ShowTablesCode = 0
        return
    }

    $javaHome = Find-JavaHome
    $jar = Find-OjdbcJar $PSScriptRoot
    $classDir = Compile-DbEvidence -JavaHome $javaHome -JarPath $jar

    $request = New-Object System.Collections.Generic.List[string]
    $request.Add("host=$($connection.HostName)")
    $request.Add("port=$($connection.Port)")
    $request.Add("service=$($connection.Service)")
    $request.Add("username=$($connection.Username)")
    if ($List) { $request.Add('command=list') } else { $request.Add('command=query') }
    $request.Add("limit=$Limit")
    $request.Add("where=$Where")
    if (-not $List) {
        $seen = @{}
        foreach ($name in $tableNames) {
            $ref = Resolve-TableRef -Name $name -DefaultSchema $connection.Username
            $key = "$($ref.Schema).$($ref.Table)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $request.Add("table=$key")
        }
    }

    $requestPath = Join-Path $env:TEMP ("show-tables-" + [guid]::NewGuid().ToString('n') + '.txt')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        [IO.File]::WriteAllLines($requestPath, $request.ToArray(), $utf8)
        $result = Invoke-DbEvidence -JavaHome $javaHome -ClassDir $classDir -JarPath $jar -RequestPath $requestPath -Password $connection.Password
    } finally {
        Remove-Item -LiteralPath $requestPath -ErrorAction SilentlyContinue
    }
    if ($result.Err -and $result.Err.Trim()) {
        [Console]::Error.WriteLine($result.Err.Trim())
    }
    $header = "connection $($connection.HostName):$($connection.Port)/$($connection.Service) user $($connection.Username)"
    if ($connection.ComposePath) {
        $header = $header + "`r`n" + "compose    $($connection.ComposePath)"
    }
    if ($List) {
        $items = Read-ListProtocol $result.Out
        Write-Output ($header + "`r`n`r`n" + (Format-TableList $items))
        $script:ShowTablesCode = $result.Code
        return
    }
    $tables = Read-EvidenceProtocol $result.Out
    $blocks = New-Object System.Collections.Generic.List[string]
    $blocks.Add($header)
    $blocks.Add('')
    foreach ($table in $tables) {
        $blocks.Add((Format-TableEvidence -Title $table.Title -Columns $table.Columns -Rows $table.Rows -Total $table.Total -ErrorMessage $table.Error -ValueWidth $Width))
        $blocks.Add('')
    }
    Write-Output (($blocks -join "`r`n").TrimEnd())
    $script:ShowTablesCode = $result.Code
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $script:ShowTablesBound = $PSBoundParameters
    $script:ShowTablesCode = 1
    try {
        Invoke-ShowTables | ForEach-Object { [Console]::Out.WriteLine($_) }
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        $script:ShowTablesCode = 1
    }
    exit $script:ShowTablesCode
}
