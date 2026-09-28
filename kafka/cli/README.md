# Kafka send CLI

Minimal local producer for any Kafka topic.

- **String mode:** send plain text
- **Avro mode:** send JSON against an `.avsc` schema via Schema Registry

Defaults: Kafka `localhost:9092`, Schema Registry `http://localhost:8089`.

## Requirements

- JDK 17+
- Maven 3+
- Reachable Kafka (and Schema Registry for Avro)

## Start local Kafka (optional)

```powershell
docker compose -f kafka-compose.yml up -d
```

## Usage

From this directory:

```powershell
# string
.\send-kafka.ps1 -Topic my-topic -Message "hello"

# avro
.\send-kafka.ps1 -Topic my-topic -Schema .\schema.avsc -File .\message.json

# avro with named-type deps in the same folder (auto-loaded)
.\send-kafka.ps1 -Topic my-topic -Schema .\ScoringCompletenessKpi.avsc -File .\message.json

# avro with a dependency schema outside that folder
.\send-kafka.ps1 -Topic my-topic -Schema .\main.avsc -SchemaExtra .\deps\OtherType.avsc -File .\message.json

# custom ports
.\send-kafka.ps1 -Topic my-topic -Message "hello" -KafkaPort 19092 -SchemaRegistryPort 18089
```

```powershell
.\send-kafka.ps1 -Help
```

When `-Schema` points at a file that references other named Avro types (for example `NoblePipelineMetadata`), keep those dependency `.avsc` files in the same directory. The CLI loads sibling `*.avsc` files automatically.

## Files

| File | Role |
|---|---|
| `send-kafka.ps1` | CLI entrypoint |
| `SendKafkaMessage.java` | Producer |
| `pom.xml` | Runtime dependencies |
| `kafka-compose.yml` | Local Kafka + Schema Registry |
