package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import org.junit.jupiter.api.Assumptions;
import org.springframework.test.context.DynamicPropertyRegistry;

/**
 * PostgreSQL for integration tests. CI provides one through TEST_DB_URL (a
 * service container in required-gates.yml); locally point TEST_DB_URL at any
 * PostgreSQL 16. Without it the tests are skipped, not failed.
 */
public final class PostgresTestDatabase {

    private PostgresTestDatabase() {
    }

    /** Call from a static @BeforeAll so the class is skipped without a database. */
    public static void assumeAvailable() {
        Assumptions.assumeTrue(isConfigured(), "Set TEST_DB_URL to run PostgreSQL integration tests");
    }

    static boolean isConfigured() {
        String url = System.getenv("TEST_DB_URL");
        return url != null && !url.isBlank();
    }

    public static void register(DynamicPropertyRegistry registry) {
        if (!isConfigured()) {
            return;
        }
        registry.add("spring.datasource.url", () -> System.getenv("TEST_DB_URL"));
        registry.add("spring.datasource.username", () -> env("TEST_DB_USERNAME", "open_products_test"));
        registry.add("spring.datasource.password", () -> env("TEST_DB_PASSWORD", "open_products_test"));
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
