package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Collectors;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * Applies db/bootstrap/history-guard.sql, the file the DBA runs with psql, over
 * JDBC, so the PostgreSQL integration tests exercise the real guard. The file
 * uses only ON_ERROR_STOP and the optional schema variable; any other psql
 * meta-command fails here instead of being skipped silently.
 */
final class HistoryGuardBootstrap {

    static final Path FILE = Path.of("db", "bootstrap", "history-guard.sql");

    private static final List<String> KNOWN_META_COMMANDS = List.of(
        "\\set ON_ERROR_STOP on", "\\if :{?schema}", "\\else", "\\set schema sc_of_open_products_catalog", "\\endif");

    private HistoryGuardBootstrap() {
    }

    /** The bootstrap as plain SQL for the given schema. */
    static String sql(String schema) {
        String script;
        try {
            script = Files.readString(FILE, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("cannot read " + FILE, e);
        }
        String plain = script.lines()
            .filter(line -> {
                if (!line.startsWith("\\")) {
                    return true;
                }
                if (!KNOWN_META_COMMANDS.contains(line.strip())) {
                    throw new IllegalStateException("history-guard.sql uses a psql meta-command the tests cannot apply: " + line);
                }
                return false;
            })
            .collect(Collectors.joining("\n"));
        return plain.replace(":'schema'", "'" + schema.replace("'", "''") + "'");
    }

    /** Installs (or, while disarmed, re-installs) the guard. */
    static void install(JdbcTemplate jdbc, String schema) {
        jdbc.execute(sql(schema));
    }
}
