import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.TimeUnit;

import org.apache.avro.SchemaParseException;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.confluent.kafka.serializers.AbstractKafkaSchemaSerDeConfig;
import io.confluent.kafka.serializers.KafkaAvroSerializer;
import io.confluent.kafka.serializers.KafkaAvroSerializerConfig;
import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.serialization.StringSerializer;

/**
 * Minimal local Kafka producer CLI.
 *
 * Avro mode:  --topic --schema --message|--file  (+ Schema Registry)
 * String mode: --topic --message|--file
 */
public final class SendKafkaMessage {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String DEFAULT_HOST = "localhost";
    private static final int DEFAULT_KAFKA_PORT = 9092;
    private static final int DEFAULT_SCHEMA_REGISTRY_PORT = 8089;

    private SendKafkaMessage() {
    }

    public static void main(String[] args) throws Exception {
        Options options = Options.parse(args);
        Properties properties = baseProperties(options.brokers);

        if (options.schemaPath != null) {
            properties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, KafkaAvroSerializer.class.getName());
            properties.put(AbstractKafkaSchemaSerDeConfig.SCHEMA_REGISTRY_URL_CONFIG, options.schemaRegistry);
            properties.put(AbstractKafkaSchemaSerDeConfig.AUTO_REGISTER_SCHEMAS, true);
            properties.put(KafkaAvroSerializerConfig.AVRO_REMOVE_JAVA_PROPS_CONFIG, true);

            Schema schema = loadSchema(Path.of(options.schemaPath), options.extraSchemaPaths);
            Object value = convert(schema, MAPPER.readTree(stripBom(options.payload)));
            send(properties, options.topic, options.key, value, options.schemaRegistry);
            return;
        }

        properties.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        send(properties, options.topic, options.key, stripBom(options.payload), null);
    }

    /**
     * Loads the main schema plus named-type dependencies.
     * By default every {@code .avsc} beside the main file is loaded (multi-pass) so
     * references like {@code NoblePipelineMetadata} resolve.
     */
    static Schema loadSchema(Path mainSchemaPath, List<Path> extraSchemaPaths) throws IOException {
        Path main = mainSchemaPath.toAbsolutePath().normalize();
        if (!Files.isRegularFile(main)) {
            throw new IllegalArgumentException("Schema file not found: " + main);
        }

        Set<Path> candidates = new LinkedHashSet<>();
        Path parent = main.getParent();
        if (parent != null && Files.isDirectory(parent)) {
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(parent, "*.avsc")) {
                for (Path path : stream) {
                    candidates.add(path.toAbsolutePath().normalize());
                }
            }
        }
        candidates.add(main);
        if (extraSchemaPaths != null) {
            for (Path extra : extraSchemaPaths) {
                Path normalized = extra.toAbsolutePath().normalize();
                if (!Files.isRegularFile(normalized)) {
                    throw new IllegalArgumentException("Extra schema file not found: " + normalized);
                }
                candidates.add(normalized);
            }
        }

        Schema.Parser parser = new Schema.Parser();
        Map<Path, Schema> parsed = new LinkedHashMap<>();
        Set<Path> remaining = new LinkedHashSet<>(candidates);
        SchemaParseException lastError = null;

        while (!remaining.isEmpty()) {
            boolean progress = false;
            Iterator<Path> iterator = remaining.iterator();
            while (iterator.hasNext()) {
                Path path = iterator.next();
                try {
                    Schema schema = parser.parse(path.toFile());
                    parsed.put(path, schema);
                    iterator.remove();
                    progress = true;
                } catch (SchemaParseException exception) {
                    lastError = exception;
                }
            }
            if (!progress) {
                String detail = lastError == null ? "" : lastError.getMessage();
                throw new SchemaParseException(
                        "Could not resolve Avro named types while parsing "
                                + main
                                + ". Put dependency .avsc files next to the main schema, or pass --schema-extra. "
                                + detail);
            }
        }

        Schema mainSchema = parsed.get(main);
        if (mainSchema == null) {
            throw new IllegalStateException("Main schema was not parsed: " + main);
        }
        return mainSchema;
    }

    private static String stripBom(String payload) {
        if (payload != null && !payload.isEmpty() && payload.charAt(0) == '\uFEFF') {
            return payload.substring(1);
        }
        return payload;
    }

    private static Properties baseProperties(String brokers) {
        Properties properties = new Properties();
        properties.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, brokers);
        properties.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        properties.put(ProducerConfig.ACKS_CONFIG, "all");
        properties.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 10_000);
        return properties;
    }

    private static void send(
            Properties properties,
            String topic,
            String key,
            Object value,
            String schemaRegistry) throws Exception {
        try (KafkaProducer<String, Object> producer = new KafkaProducer<>(properties)) {
            RecordMetadata metadata = producer.send(new ProducerRecord<>(topic, key, value))
                    .get(30, TimeUnit.SECONDS);
            producer.flush();
            if (schemaRegistry == null) {
                System.out.printf(
                        "topic=%s partition=%d offset=%d key=%s format=string brokers=%s%n",
                        metadata.topic(),
                        metadata.partition(),
                        metadata.offset(),
                        key,
                        properties.get(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG));
            } else {
                System.out.printf(
                        "topic=%s partition=%d offset=%d key=%s format=avro brokers=%s schemaRegistry=%s%n",
                        metadata.topic(),
                        metadata.partition(),
                        metadata.offset(),
                        key,
                        properties.get(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG),
                        schemaRegistry);
            }
        }
    }

    static Object convert(Schema schema, JsonNode node) {
        if (schema.getType() == Schema.Type.UNION) {
            return convertUnion(schema, node);
        }
        if (node == null || node.isNull()) {
            if (schema.getType() == Schema.Type.NULL) {
                return null;
            }
            throw new IllegalArgumentException("Null JSON does not match schema type " + schema.getType());
        }

        switch (schema.getType()) {
            case RECORD:
                return convertRecord(schema, node);
            case ARRAY:
                return convertArray(schema, node);
            case MAP:
                return convertMap(schema, node);
            case ENUM:
                return new GenericData.EnumSymbol(schema, node.asText());
            case STRING:
                return node.asText();
            case BYTES:
                return node.asText().getBytes(StandardCharsets.UTF_8);
            case INT:
                return node.intValue();
            case LONG:
                return node.longValue();
            case FLOAT:
                return node.floatValue();
            case DOUBLE:
                return node.doubleValue();
            case BOOLEAN:
                return node.booleanValue();
            case FIXED:
                byte[] fixed = node.asText().getBytes(StandardCharsets.UTF_8);
                return new GenericData.Fixed(schema, fixed);
            case NULL:
                return null;
            default:
                throw new IllegalArgumentException("Unsupported Avro type: " + schema.getType());
        }
    }

    private static Object convertUnion(Schema schema, JsonNode node) {
        if (node == null || node.isNull()) {
            for (Schema branch : schema.getTypes()) {
                if (branch.getType() == Schema.Type.NULL) {
                    return null;
                }
            }
            throw new IllegalArgumentException("Null JSON does not match union " + schema);
        }

        List<String> errors = new ArrayList<>();
        for (Schema branch : schema.getTypes()) {
            if (branch.getType() == Schema.Type.NULL) {
                continue;
            }
            try {
                return convert(branch, node);
            } catch (RuntimeException exception) {
                errors.add(branch.getType() + ": " + exception.getMessage());
            }
        }
        throw new IllegalArgumentException("JSON does not match union " + schema + " (" + String.join("; ", errors) + ")");
    }

    private static GenericRecord convertRecord(Schema schema, JsonNode node) {
        if (!node.isObject()) {
            throw new IllegalArgumentException("Expected JSON object for record " + schema.getFullName());
        }
        GenericRecord record = new GenericData.Record(schema);
        for (Schema.Field field : schema.getFields()) {
            JsonNode child = node.get(field.name());
            if (child == null || child.isNull()) {
                if (field.hasDefaultValue()) {
                    record.put(field.name(), GenericData.get().getDefaultValue(field));
                } else if (isNullable(field.schema())) {
                    record.put(field.name(), null);
                } else {
                    throw new IllegalArgumentException(
                            "Missing required field '" + field.name() + "' for record " + schema.getFullName());
                }
                continue;
            }
            record.put(field.name(), convert(field.schema(), child));
        }
        return record;
    }

    private static List<Object> convertArray(Schema schema, JsonNode node) {
        if (!node.isArray()) {
            throw new IllegalArgumentException("Expected JSON array for Avro array");
        }
        List<Object> values = new ArrayList<>(node.size());
        for (JsonNode child : node) {
            values.add(convert(schema.getElementType(), child));
        }
        return values;
    }

    private static Map<String, Object> convertMap(Schema schema, JsonNode node) {
        if (!node.isObject()) {
            throw new IllegalArgumentException("Expected JSON object for Avro map");
        }
        Map<String, Object> values = new LinkedHashMap<>();
        Iterator<Map.Entry<String, JsonNode>> fields = node.fields();
        while (fields.hasNext()) {
            Map.Entry<String, JsonNode> entry = fields.next();
            values.put(entry.getKey(), convert(schema.getValueType(), entry.getValue()));
        }
        return values;
    }

    private static boolean isNullable(Schema schema) {
        if (schema.getType() == Schema.Type.NULL) {
            return true;
        }
        if (schema.getType() != Schema.Type.UNION) {
            return false;
        }
        for (Schema branch : schema.getTypes()) {
            if (branch.getType() == Schema.Type.NULL) {
                return true;
            }
        }
        return false;
    }

    private static final class Options {
        private final String brokers;
        private final String schemaRegistry;
        private final String topic;
        private final String key;
        private final String schemaPath;
        private final List<Path> extraSchemaPaths;
        private final String payload;

        private Options(
                String brokers,
                String schemaRegistry,
                String topic,
                String key,
                String schemaPath,
                List<Path> extraSchemaPaths,
                String payload) {
            this.brokers = brokers;
            this.schemaRegistry = schemaRegistry;
            this.topic = topic;
            this.key = key;
            this.schemaPath = schemaPath;
            this.extraSchemaPaths = extraSchemaPaths;
            this.payload = payload;
        }

        private static Options parse(String[] args) throws Exception {
            String host = DEFAULT_HOST;
            Integer kafkaPort = null;
            Integer schemaRegistryPort = null;
            String brokers = null;
            String schemaRegistry = null;
            String topic = null;
            String key = null;
            String schemaPath = null;
            List<Path> extraSchemaPaths = new ArrayList<>();
            String message = null;
            String file = null;

            for (int i = 0; i < args.length; i++) {
                String arg = args[i];
                switch (arg) {
                    case "-h":
                    case "--help":
                        printHelp();
                        System.exit(0);
                        return null;
                    case "--host":
                        host = requireValue(args, ++i, arg);
                        break;
                    case "--kafka-port":
                        kafkaPort = Integer.parseInt(requireValue(args, ++i, arg));
                        break;
                    case "--schema-registry-port":
                        schemaRegistryPort = Integer.parseInt(requireValue(args, ++i, arg));
                        break;
                    case "--brokers":
                        brokers = requireValue(args, ++i, arg);
                        break;
                    case "--schema-registry":
                        schemaRegistry = requireValue(args, ++i, arg);
                        break;
                    case "--topic":
                        topic = requireValue(args, ++i, arg);
                        break;
                    case "--key":
                        key = requireValue(args, ++i, arg);
                        break;
                    case "--schema":
                        schemaPath = requireValue(args, ++i, arg);
                        break;
                    case "--schema-extra":
                        extraSchemaPaths.add(Path.of(requireValue(args, ++i, arg)));
                        break;
                    case "--message":
                        message = requireValue(args, ++i, arg);
                        break;
                    case "--file":
                        file = requireValue(args, ++i, arg);
                        break;
                    default:
                        throw new IllegalArgumentException("Unknown argument: " + arg + "\n" + usage());
                }
            }

            if (topic == null || topic.isBlank()) {
                throw new IllegalArgumentException("Missing --topic\n" + usage());
            }
            if (message != null && file != null) {
                throw new IllegalArgumentException("Use only one of --message or --file\n" + usage());
            }

            String payload;
            if (file != null) {
                payload = Files.readString(Path.of(file), StandardCharsets.UTF_8);
            } else if (message != null) {
                payload = message;
            } else if (System.in.available() > 0) {
                payload = new String(System.in.readAllBytes(), StandardCharsets.UTF_8);
            } else {
                throw new IllegalArgumentException("Missing --message, --file, or stdin payload\n" + usage());
            }

            int resolvedKafkaPort = kafkaPort != null ? kafkaPort : DEFAULT_KAFKA_PORT;
            int resolvedSchemaRegistryPort =
                    schemaRegistryPort != null ? schemaRegistryPort : DEFAULT_SCHEMA_REGISTRY_PORT;
            String resolvedBrokers = brokers != null ? brokers : host + ":" + resolvedKafkaPort;
            String resolvedSchemaRegistry = schemaRegistry != null
                    ? schemaRegistry
                    : "http://" + host + ":" + resolvedSchemaRegistryPort;

            return new Options(
                    resolvedBrokers,
                    resolvedSchemaRegistry,
                    topic,
                    key,
                    schemaPath,
                    extraSchemaPaths,
                    payload);
        }

        private static String requireValue(String[] args, int index, String flag) {
            if (index >= args.length) {
                throw new IllegalArgumentException("Missing value for " + flag + "\n" + usage());
            }
            return args[index];
        }

        private static String usage() {
            return "Usage: SendKafkaMessage --topic <topic> (--message <text>|--file <path>) [options]\n"
                    + "\n"
                    + "Required:\n"
                    + "  --topic <topic>\n"
                    + "  --message <text>                 raw string, or JSON when --schema is set\n"
                    + "  --file <path>                    read payload from file instead of --message\n"
                    + "\n"
                    + "Avro:\n"
                    + "  --schema <path.avsc>             enable Avro + Schema Registry\n"
                    + "                                  also loads sibling *.avsc as named-type deps\n"
                    + "  --schema-extra <path.avsc>       extra dependency schema (repeatable)\n"
                    + "\n"
                    + "Connection (defaults match local Docker):\n"
                    + "  --host <host>                    default: localhost\n"
                    + "  --kafka-port <port>              default: 9092\n"
                    + "  --schema-registry-port <port>    default: 8089\n"
                    + "  --brokers <host:port>            overrides host/kafka-port\n"
                    + "  --schema-registry <url>          overrides host/schema-registry-port\n"
                    + "  --key <key>\n"
                    + "  -h, --help";
        }

        private static void printHelp() {
            System.out.println(usage());
        }
    }
}
