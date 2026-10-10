package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import java.util.Map;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Assumptions;
import org.springframework.test.context.DynamicPropertyRegistry;

/**
 * PostgreSQL for integration tests, from TEST_DB_URL (TEST_DB_USERNAME,
 * TEST_DB_PASSWORD). GitHub ci/test provides a service container; the
 * Jenkinsfile Quality Gate starts a postgres:16 container. Locally point
 * TEST_DB_URL at any PostgreSQL 16.
 *
 * Without TEST_DB_URL the tests are skipped on a developer machine but fail
 * in CI (CI=true, as GitHub Actions and GitLab set it, or JENKINS_URL), so a
 * pipeline can never go green while silently skipping them.
 */
public final class PostgresTestDatabase {

    private PostgresTestDatabase() {
    }

    /** Call from a static @BeforeAll. */
    public static void assumeAvailable() {
        assumeAvailable(System.getenv());
    }

    static void assumeAvailable(Map<String, String> env) {
        if (isConfigured(env)) {
            return;
        }
        if (runsInCi(env)) {
            Assertions.fail("TEST_DB_URL is not set in CI: the PostgreSQL integration tests must run, not be skipped");
        }
        Assumptions.abort("Set TEST_DB_URL to run PostgreSQL integration tests");
    }

    static boolean runsInCi(Map<String, String> env) {
        return "true".equalsIgnoreCase(env.getOrDefault("CI", "").trim())
            || !env.getOrDefault("JENKINS_URL", "").isBlank();
    }

    static boolean isConfigured(Map<String, String> env) {
        String url = env.get("TEST_DB_URL");
        return url != null && !url.isBlank();
    }

    public static void register(DynamicPropertyRegistry registry) {
        Map<String, String> env = System.getenv();
        if (!isConfigured(env)) {
            return;
        }
        registry.add("spring.datasource.url", () -> env.get("TEST_DB_URL"));
        registry.add("spring.datasource.username", () -> env(env, "TEST_DB_USERNAME", "open_products_test"));
        registry.add("spring.datasource.password", () -> env(env, "TEST_DB_PASSWORD", "open_products_test"));
    }

    /** The same database as command-line arguments, for a second SpringApplication started by a test. */
    public static String[] springArguments() {
        Map<String, String> env = System.getenv();
        return new String[] {
            "--spring.datasource.url=" + env.get("TEST_DB_URL"),
            "--spring.datasource.username=" + env(env, "TEST_DB_USERNAME", "open_products_test"),
            "--spring.datasource.password=" + env(env, "TEST_DB_PASSWORD", "open_products_test"),
        };
    }

    private static String env(Map<String, String> env, String name, String fallback) {
        String value = env.get(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
