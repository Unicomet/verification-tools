<#
.SYNOPSIS
  Send a message to a local Kafka topic.

.DESCRIPTION
  Generic producer for any topic/payload.
  - With -Schema: publishes Avro via Schema Registry (JSON payload).
  - Without -Schema: publishes a plain string.

  Defaults: Kafka localhost:9092, Schema Registry http://localhost:8089.

.EXAMPLE
  .\send-kafka.ps1 -Topic my-topic -Message "hello"

.EXAMPLE
  .\send-kafka.ps1 -Topic my-topic -Schema schema.avsc -File message.json

.EXAMPLE
  .\send-kafka.ps1 -Topic my-topic -Schema schema.avsc -Message '{"id":"1"}' -KafkaPort 19092 -SchemaRegistryPort 18089
#>
[CmdletBinding()]
param(
    [string]$Topic,

    [string]$Message,

    [string]$File,

    [string]$Schema,

    [string[]]$SchemaExtra = @(),

    [string]$Key,

    [string]$HostName = "localhost",

    [int]$KafkaPort = 9092,

    [int]$SchemaRegistryPort = 8089,

    [string]$Brokers,

    [string]$SchemaRegistry,

    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Get-JavaHomeExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME "bin\$Name.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "$Name was not found. Install JDK 17 or set JAVA_HOME."
    }
    return $command.Source
}

function Get-MavenCommand {
    $command = Get-Command mvn -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "mvn was not found on PATH."
    }
    return $command.Source
}

if ($Help) {
    Write-Output @"
Send a message to local Kafka.

String:
  .\send-kafka.ps1 -Topic my-topic -Message "hello"

Avro:
  .\send-kafka.ps1 -Topic my-topic -Schema schema.avsc -File message.json

Options:
  -Topic <topic>                   required
  -Message <text>                  payload text/JSON
  -File <path>                     payload from file
  -Schema <path.avsc>              Avro mode + Schema Registry (loads sibling *.avsc too)
  -SchemaExtra <path.avsc>         Extra dependency schema(s), repeatable
  -Key <key>
  -HostName <host>                 default: localhost
  -KafkaPort <port>                default: 9092
  -SchemaRegistryPort <port>       default: 8089
  -Brokers <host:port>             overrides HostName/KafkaPort
  -SchemaRegistry <url>            overrides HostName/SchemaRegistryPort
  -Help
"@
    exit 0
}

if (-not $Topic) {
    throw "Provide -Topic."
}
if ($Message -and $File) {
    throw "Use only one of -Message or -File."
}
if (-not $Message -and -not $File) {
    throw "Provide -Message or -File."
}
if ($File -and -not (Test-Path -LiteralPath $File)) {
    throw "Payload file not found: $File"
}
if ($Schema -and -not (Test-Path -LiteralPath $Schema)) {
    throw "Schema file not found: $Schema"
}
foreach ($extra in $SchemaExtra) {
    if (-not (Test-Path -LiteralPath $extra)) {
        throw "Extra schema file not found: $extra"
    }
}

$toolRoot = $PSScriptRoot
Set-Location -LiteralPath $toolRoot

$javaExecutable = Get-JavaHomeExecutable -Name "java"
$javacExecutable = Get-JavaHomeExecutable -Name "javac"
$mavenCommand = Get-MavenCommand

$classpathFile = Join-Path $toolRoot "target\producer-cp.txt"
$producerClasses = Join-Path $toolRoot "target\classes"
$producerSource = Join-Path $toolRoot "SendKafkaMessage.java"
$pomFile = Join-Path $toolRoot "pom.xml"

$resolvedBrokers = if ($Brokers) { $Brokers } else { "${HostName}:${KafkaPort}" }
$resolvedSchemaRegistry = if ($SchemaRegistry) { $SchemaRegistry } else { "http://${HostName}:${SchemaRegistryPort}" }

Write-Host "Checking Kafka at $resolvedBrokers ..."
$kafkaHost, $kafkaPortValue = $resolvedBrokers.Split(":", 2)
$kafkaTcp = Test-NetConnection -ComputerName $kafkaHost -Port ([int]$kafkaPortValue) -WarningAction SilentlyContinue
if (-not $kafkaTcp.TcpTestSucceeded) {
    throw "Kafka is not reachable at $resolvedBrokers. Start Docker Kafka or pass -KafkaPort."
}

if ($Schema) {
    Write-Host "Checking Schema Registry at $resolvedSchemaRegistry ..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$resolvedSchemaRegistry/subjects" -TimeoutSec 5 | Out-Null
    } catch {
        throw "Schema Registry is not reachable at $resolvedSchemaRegistry. Start Docker Schema Registry or pass -SchemaRegistryPort. $($_.Exception.Message)"
    }
}

Write-Host "Ensuring producer classpath..."
New-Item -ItemType Directory -Force -Path (Join-Path $toolRoot "target") | Out-Null
& $mavenCommand -f $pomFile -q dependency:build-classpath `
    "-Dmdep.outputFile=$classpathFile" `
    "-Dmdep.includeScope=runtime"
if ($LASTEXITCODE -ne 0) {
    throw "Maven classpath failed with exit code $LASTEXITCODE"
}

$dependencyClasspath = (Get-Content -Raw -LiteralPath $classpathFile).Trim()
if ([string]::IsNullOrWhiteSpace($dependencyClasspath)) {
    throw "Producer classpath file was empty: $classpathFile"
}

New-Item -ItemType Directory -Force -Path $producerClasses | Out-Null
& $javacExecutable -proc:none -cp $dependencyClasspath -d $producerClasses $producerSource
if ($LASTEXITCODE -ne 0) {
    throw "Producer compilation failed with exit code $LASTEXITCODE"
}

$javaArgs = @(
    "--host", $HostName,
    "--kafka-port", "$KafkaPort",
    "--schema-registry-port", "$SchemaRegistryPort",
    "--topic", $Topic
)

if ($Brokers) { $javaArgs += @("--brokers", $Brokers) }
if ($SchemaRegistry) { $javaArgs += @("--schema-registry", $SchemaRegistry) }
if ($Key) { $javaArgs += @("--key", $Key) }
if ($Schema) { $javaArgs += @("--schema", (Resolve-Path -LiteralPath $Schema).Path) }
foreach ($extra in $SchemaExtra) {
    $javaArgs += @("--schema-extra", (Resolve-Path -LiteralPath $extra).Path)
}
# PowerShell mangles double-quotes when splatting JSON into a native java.exe
# process. Always hand the payload to Java via --file.
$tempPayloadFile = $null
if ($File) {
    $javaArgs += @("--file", (Resolve-Path -LiteralPath $File).Path)
} else {
    $tempPayloadFile = Join-Path ([System.IO.Path]::GetTempPath()) ("send-kafka-payload-" + [guid]::NewGuid().ToString("N") + ".txt")
    [System.IO.File]::WriteAllText($tempPayloadFile, $Message, [System.Text.UTF8Encoding]::new($false))
    $javaArgs += @("--file", $tempPayloadFile)
}

$runClasspath = "$producerClasses;$dependencyClasspath"
$format = if ($Schema) { "avro" } else { "string" }
Write-Host "Sending $format message to $Topic ..."
try {
    & $javaExecutable -cp $runClasspath SendKafkaMessage @javaArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Kafka publish failed with exit code $LASTEXITCODE"
    }
} finally {
    if ($tempPayloadFile -and (Test-Path -LiteralPath $tempPayloadFile)) {
        Remove-Item -LiteralPath $tempPayloadFile -Force -ErrorAction SilentlyContinue
    }
}
