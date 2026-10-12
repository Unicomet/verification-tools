import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Blob;
import java.sql.Clob;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import oracle.sql.TIMESTAMPTZ;

/**
 * Reads Oracle tables for show-tables.ps1.
 * stdout is an ASCII protocol. PowerShell 5.1 decodes the child process
 * with the console code page, so every other character is a JSON escape.
 */
public final class DbEvidence {
    private static final String PRIMARY_KEY_SQL =
            "select cols.column_name "
                    + "from all_constraints cons "
                    + "join all_cons_columns cols "
                    + "on cons.owner = cols.owner "
                    + "and cons.constraint_name = cols.constraint_name "
                    + "where cons.constraint_type = 'P' "
                    + "and cons.owner = ? "
                    + "and cons.table_name = ? "
                    + "order by cols.position";

    private DbEvidence() {
    }

    public static void main(String[] args) {
        int code = 1;
        try {
            if (args.length != 1) {
                throw new IllegalArgumentException("Usage: DbEvidence <request-file>");
            }
            code = run(Path.of(args[0]));
        } catch (Exception exception) {
            String message = exception.getMessage();
            System.err.println(message == null || message.isBlank() ? exception.toString() : message);
            code = 1;
        }
        System.exit(code);
    }

    private static int run(Path requestPath) throws Exception {
        Map<String, List<String>> request = readRequest(requestPath);
        String command = one(request, "command");
        if ("encode".equals(command)) {
            try (Protocol protocol = new Protocol()) {
                protocol.line(jsonString(one(request, "text")));
            }
            return 0;
        }
        String password = System.getenv("SHOW_TABLES_PASSWORD");
        if (password == null || password.isEmpty()) {
            throw new IllegalArgumentException("Missing database password.");
        }
        String host = required(request, "host");
        int port = Integer.parseInt(required(request, "port"));
        String service = required(request, "service").toUpperCase();
        String username = required(request, "username").toUpperCase();
        int limit = parseLimit(one(request, "limit"));
        String where = one(request, "where").trim();
        if (!where.isEmpty()) {
            checkWhere(where);
        }
        quote(service);
        quote(username);
        try {
            Class.forName("oracle.jdbc.OracleDriver");
        } catch (ClassNotFoundException exception) {
            throw new IllegalStateException("Oracle JDBC driver is not on the classpath.");
        }
        String url = "jdbc:oracle:thin:@//" + host + ":" + port + "/" + service;
        Properties properties = new Properties();
        properties.setProperty("user", username);
        properties.setProperty("password", password);
        properties.setProperty("oracle.net.CONNECT_TIMEOUT", "15000");
        properties.setProperty("oracle.jdbc.ReadTimeout", "120000");
        DriverManager.setLoginTimeout(15);
        try (Connection connection = DriverManager.getConnection(url, properties)) {
            connection.setReadOnly(true);
            connection.setAutoCommit(true);
            if ("list".equals(command)) {
                try (Protocol protocol = new Protocol()) {
                    writeList(connection, username, protocol);
                }
                return 0;
            }
            if (!"query".equals(command)) {
                throw new IllegalArgumentException("Unknown command.");
            }
            List<String> tables = request.getOrDefault("table", List.of());
            if (tables.isEmpty()) {
                throw new IllegalArgumentException("Name at least one table.");
            }
            int code = 0;
            try (Protocol protocol = new Protocol()) {
                for (String tableName : tables) {
                    if (!writeTable(connection, tableName, where, limit, protocol)) {
                        code = 2;
                    }
                }
            }
            return code;
        } catch (SQLException exception) {
            throw new IllegalStateException(
                    "Could not connect to " + host + ":" + port + "/" + service
                            + " as " + username + ". " + exception.getMessage(),
                    exception);
        }
    }

    private static void writeList(Connection connection, String owner, Protocol protocol) throws Exception {
        List<String> names = new ArrayList<>();
        try (PreparedStatement statement = connection.prepareStatement(
                "select table_name from all_tables where owner = ? order by table_name")) {
            statement.setString(1, owner);
            statement.setQueryTimeout(60);
            try (ResultSet result = statement.executeQuery()) {
                while (result.next()) {
                    names.add(result.getString(1));
                }
            }
        }
        for (String name : names) {
            try (Statement statement = connection.createStatement()) {
                statement.setQueryTimeout(60);
                try (ResultSet result = statement.executeQuery(
                        "select count(*) from " + quote(owner) + "." + quote(name))) {
                    result.next();
                    protocol.line("LIST " + name + " " + result.getLong(1));
                }
            } catch (SQLException exception) {
                protocol.line("LIST " + name + " ERROR " + ascii(exception.getMessage()));
            }
        }
    }

    private static boolean writeTable(
            Connection connection,
            String qualifiedName,
            String where,
            int limit,
            Protocol protocol) throws Exception {
        String[] parts = qualifiedName.split("\\.", -1);
        if (parts.length != 2) {
            protocol.line("TABLE " + ascii(qualifiedName));
            protocol.line("ERROR Invalid table name.");
            protocol.line("END");
            return false;
        }
        String schema = parts[0].toUpperCase();
        String table = parts[1].toUpperCase();
        String title = schema + "." + table;
        protocol.line("TABLE " + title);
        try {
            quote(schema);
            quote(table);
            String from = quote(schema) + "." + quote(table);
            String filter = where.isEmpty() ? "" : " where (" + where + ")";
            long total = queryCount(connection, "select count(*) from " + from + filter);
            List<String> key = primaryKey(connection, schema, table);
            String sql = "select * from " + from + filter + " order by " + orderBy(key);
            if (limit > 0) {
                sql = sql + " fetch first " + limit + " rows only";
            }
            try (Statement statement = connection.createStatement()) {
                statement.setFetchSize(200);
                statement.setQueryTimeout(120);
                try (ResultSet result = statement.executeQuery(sql)) {
                    ResultSetMetaData metadata = result.getMetaData();
                    List<String> columns = new ArrayList<>();
                    for (int index = 1; index <= metadata.getColumnCount(); index++) {
                        columns.add(metadata.getColumnLabel(index));
                    }
                    protocol.columns(columns);
                    protocol.line("TOTAL " + total);
                    while (result.next()) {
                        protocol.row(columns, readRow(result, columns.size()));
                    }
                }
            }
            protocol.line("END");
            return true;
        } catch (SQLException exception) {
            protocol.line("ERROR " + ascii(exception.getMessage()));
            protocol.line("END");
            return false;
        } catch (IllegalArgumentException exception) {
            protocol.line("ERROR " + ascii(exception.getMessage()));
            protocol.line("END");
            return false;
        }
    }

    private static List<String> readRow(ResultSet result, int count) throws SQLException {
        List<String> values = new ArrayList<>();
        for (int index = 1; index <= count; index++) {
            values.add(formatValue(result, index));
        }
        return values;
    }

    private static String formatValue(ResultSet result, int index) throws SQLException {
        Object value = result.getObject(index);
        if (value == null || result.wasNull()) {
            return null;
        }
        if (value instanceof Clob clob) {
            try {
                return readClob(clob);
            } finally {
                clob.free();
            }
        }
        if (value instanceof Blob blob) {
            try {
                return "(binary " + blob.length() + " bytes)";
            } finally {
                blob.free();
            }
        }
        if (value instanceof byte[] bytes) {
            return "(binary " + bytes.length + " bytes)";
        }
        if (value instanceof java.sql.Date date) {
            return date.toLocalDate().toString();
        }
        if (value instanceof Timestamp timestamp) {
            return formatDateTime(timestamp.toLocalDateTime());
        }
        if (value instanceof OffsetDateTime offsetDateTime) {
            return offsetDateTime.toString();
        }
        if (value instanceof TIMESTAMPTZ timestampWithZone) {
            return timestampWithZone.stringValue(result.getStatement().getConnection());
        }
        if (value instanceof BigDecimal number) {
            return number.toPlainString();
        }
        return String.valueOf(value);
    }

    private static String readClob(Clob clob) throws SQLException {
        long length = clob.length();
        if (length == 0) {
            return "";
        }
        int take = (int) Math.min(length, Integer.MAX_VALUE);
        String text = clob.getSubString(1, take);
        if (length > take) {
            return text + "\n(truncated, " + length + " characters)";
        }
        return text;
    }

    private static String formatDateTime(LocalDateTime value) {
        return value.toString().replace('T', ' ');
    }

    private static long queryCount(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.setQueryTimeout(120);
            try (ResultSet result = statement.executeQuery(sql)) {
                result.next();
                return result.getLong(1);
            }
        }
    }

    private static List<String> primaryKey(Connection connection, String schema, String table) throws SQLException {
        List<String> columns = new ArrayList<>();
        try (PreparedStatement statement = connection.prepareStatement(PRIMARY_KEY_SQL)) {
            statement.setString(1, schema);
            statement.setString(2, table);
            statement.setQueryTimeout(60);
            try (ResultSet result = statement.executeQuery()) {
                while (result.next()) {
                    columns.add(result.getString(1));
                }
            }
        }
        return columns;
    }

    private static String orderBy(List<String> key) {
        if (key.isEmpty()) {
            return "rowid";
        }
        StringBuilder order = new StringBuilder();
        for (int index = 0; index < key.size(); index++) {
            if (index > 0) {
                order.append(", ");
            }
            order.append(quote(key.get(index)));
        }
        return order.toString();
    }

    private static String quote(String identifier) {
        if (!identifier.matches("[A-Z][A-Z0-9_$#]{0,127}")) {
            throw new IllegalArgumentException("Invalid identifier: " + identifier);
        }
        return "\"" + identifier + "\"";
    }

    private static void checkWhere(String where) {
        if (where.indexOf(';') >= 0 || where.contains("--") || where.contains("/*") || where.contains("*/")) {
            throw new IllegalArgumentException("The where clause cannot contain ; or comments.");
        }
        for (int index = 0; index < where.length(); index++) {
            char character = where.charAt(index);
            if (character < 0x20 && character != '\t') {
                throw new IllegalArgumentException("The where clause cannot contain control characters.");
            }
        }
    }

    private static int parseLimit(String text) {
        if (text == null || text.isBlank()) {
            return 0;
        }
        int limit = Integer.parseInt(text);
        if (limit < 0) {
            throw new IllegalArgumentException("-Limit must be 0 or greater.");
        }
        return limit;
    }

    private static Map<String, List<String>> readRequest(Path path) throws IOException {
        Map<String, List<String>> values = new LinkedHashMap<>();
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            if (line.isEmpty()) {
                continue;
            }
            int split = line.indexOf('=');
            if (split < 1) {
                throw new IllegalArgumentException("Bad request line.");
            }
            values.computeIfAbsent(line.substring(0, split), key -> new ArrayList<>())
                    .add(line.substring(split + 1));
        }
        return values;
    }

    private static String one(Map<String, List<String>> values, String key) {
        List<String> found = values.get(key);
        if (found == null || found.isEmpty()) {
            return "";
        }
        return found.get(0);
    }

    private static String required(Map<String, List<String>> values, String key) {
        String value = one(values, key);
        if (value.isBlank()) {
            throw new IllegalArgumentException("Missing " + key + ".");
        }
        return value;
    }

    static String jsonString(String value) {
        StringBuilder builder = new StringBuilder(value.length() + 2);
        builder.append('"');
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"' -> builder.append("\\\"");
                case '\\' -> builder.append("\\\\");
                case '\n' -> builder.append("\\n");
                case '\r' -> builder.append("\\r");
                case '\t' -> builder.append("\\t");
                default -> {
                    if (character < 0x20 || character > 0x7e) {
                        builder.append(String.format("\\u%04x", (int) character));
                    } else {
                        builder.append(character);
                    }
                }
            }
        }
        builder.append('"');
        return builder.toString();
    }

    private static String ascii(String text) {
        if (text == null) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < text.length(); index++) {
            char character = text.charAt(index);
            if (character == '\n' || character == '\r' || character == '\t') {
                builder.append(' ');
            } else if (character >= 0x20 && character <= 0x7e) {
                builder.append(character);
            } else {
                builder.append(String.format("\\u%04x", (int) character));
            }
        }
        return builder.toString();
    }

    private static final class Protocol implements AutoCloseable {
        private final Writer writer = new OutputStreamWriter(System.out, StandardCharsets.US_ASCII);

        void line(String text) throws IOException {
            writer.write(text);
            writer.write('\n');
        }

        void columns(List<String> names) throws IOException {
            StringBuilder builder = new StringBuilder();
            builder.append('[');
            for (int index = 0; index < names.size(); index++) {
                if (index > 0) {
                    builder.append(',');
                }
                builder.append(jsonString(names.get(index)));
            }
            builder.append(']');
            line("COLUMNS " + builder);
        }

        void row(List<String> names, List<String> values) throws IOException {
            StringBuilder builder = new StringBuilder();
            builder.append('{');
            for (int index = 0; index < names.size(); index++) {
                if (index > 0) {
                    builder.append(',');
                }
                builder.append(jsonString(names.get(index)));
                builder.append(':');
                String value = values.get(index);
                builder.append(value == null ? "null" : jsonString(value));
            }
            builder.append('}');
            line("ROW " + builder);
        }

        @Override
        public void close() throws IOException {
            writer.flush();
        }
    }
}
