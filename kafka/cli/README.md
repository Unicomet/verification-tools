# How to send a Kafka message

Use this CLI when you need to put one message on a local Kafka topic from PowerShell. You can send plain text, or JSON that Schema Registry encodes as Avro.

## Requirements

- JDK 17 or newer (`java` and `javac` on `PATH`, or `JAVA_HOME` set)
- Maven 3+ (`mvn` on `PATH`)
- A reachable Kafka broker
- For Avro mode, a reachable Schema Registry

## Start local Kafka (optional)

From this directory, start the bundled broker and Schema Registry:

```powershell
docker compose -f kafka-compose.yml up -d
```

That compose file publishes Kafka on `localhost:9092` and Schema Registry on `http://localhost:8089`. Those are the CLI defaults.

## Send a string message

```powershell
.\send-kafka.ps1 -Topic my-topic -Message "hello"
```

The command fails if Kafka is not reachable at the configured brokers.

## Send a payload from a file

```powershell
.\send-kafka.ps1 -Topic my-topic -File .\message.txt
```

Pass exactly one of `-Message` or `-File`.

## Send an Avro message

1. Put the primary `.avsc` schema next to any named-type dependency schemas it references.
2. Put the JSON payload in a file.
3. Run:

```powershell
.\send-kafka.ps1 -Topic my-topic -Schema .\schema.avsc -File .\message.json
```

The CLI loads sibling `.avsc` files in the same folder as `-Schema` only when the primary schema references those named types. Unrelated sibling schemas are ignored.

If a dependency schema lives outside that folder, pass it with `-SchemaExtra`:

```powershell
.\send-kafka.ps1 -Topic my-topic -Schema .\main.avsc -SchemaExtra .\deps\OtherType.avsc -File .\message.json
```

You can repeat `-SchemaExtra`.

## Point at a different broker or Schema Registry

Override the host and ports:

```powershell
.\send-kafka.ps1 -Topic my-topic -Message "hello" -HostName 127.0.0.1 -KafkaPort 19092 -SchemaRegistryPort 18089
```

Or pass full endpoints:

```powershell
.\send-kafka.ps1 -Topic my-topic -Message "hello" -Brokers 127.0.0.1:19092
.\send-kafka.ps1 -Topic my-topic -Schema .\schema.avsc -File .\message.json -SchemaRegistry http://127.0.0.1:18089
```

`-Brokers` replaces `-HostName` and `-KafkaPort`. `-SchemaRegistry` replaces `-HostName` and `-SchemaRegistryPort`.

## Set a message key

```powershell
.\send-kafka.ps1 -Topic my-topic -Message "hello" -Key order-42
```

## Show built-in help

```powershell
.\send-kafka.ps1 -Help
```

## Flag reference

See [REFERENCE.md](REFERENCE.md) for every parameter, default, and constraint.
