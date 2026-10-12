# Kafka send CLI reference

Entrypoint: `send-kafka.ps1`

## Parameters

| Parameter | Type | Default | Required | Description |
|---|---|---|---|---|
| `-Topic` | string | | yes | Kafka topic name |
| `-Message` | string | | one of `-Message` or `-File` | Payload text |
| `-File` | string | | one of `-Message` or `-File` | Path to a payload file |
| `-Schema` | string | | no | Path to a `.avsc` file. When set, the CLI uses Avro mode and Schema Registry |
| `-SchemaExtra` | string[] | `@()` | no | Extra dependency `.avsc` paths. Repeatable |
| `-Key` | string | | no | Kafka message key |
| `-HostName` | string | `localhost` | no | Host used to build broker and Schema Registry URLs |
| `-KafkaPort` | int | `9092` | no | Kafka port when `-Brokers` is omitted |
| `-SchemaRegistryPort` | int | `8089` | no | Schema Registry port when `-SchemaRegistry` is omitted |
| `-Brokers` | string | | no | Full `host:port` broker list. Overrides `-HostName` and `-KafkaPort` |
| `-SchemaRegistry` | string | | no | Full Schema Registry URL. Overrides `-HostName` and `-SchemaRegistryPort` |
| `-Help` | switch | | no | Print usage and exit 0 |

## Modes

| Mode | How you select it | Payload | Extra checks |
|---|---|---|---|
| String | Omit `-Schema` | `-Message` or `-File` | Kafka must accept a TCP connection |
| Avro | Pass `-Schema` | JSON from `-Message` or `-File` | Schema Registry must respond. Sibling and `-SchemaExtra` schemas must exist on disk |

## Defaults when endpoints are omitted

| Endpoint | Value |
|---|---|
| Brokers | `{HostName}:{KafkaPort}` → `localhost:9092` |
| Schema Registry | `http://{HostName}:{SchemaRegistryPort}` → `http://localhost:8089` |

## Files in this directory

| File | Role |
|---|---|
| `send-kafka.ps1` | CLI entrypoint |
| `SendKafkaMessage.java` | Producer |
| `pom.xml` | Maven dependencies for the producer classpath |
| `kafka-compose.yml` | Local Kafka and Schema Registry |

## Errors the CLI raises before publish

- Missing `-Topic`
- Both `-Message` and `-File`, or neither
- Missing payload file, schema file, or `-SchemaExtra` file
- Kafka not reachable at the resolved brokers
- Schema Registry not reachable when `-Schema` is set
- Maven classpath resolve failure
- Producer compilation failure
- Publish process non-zero exit
