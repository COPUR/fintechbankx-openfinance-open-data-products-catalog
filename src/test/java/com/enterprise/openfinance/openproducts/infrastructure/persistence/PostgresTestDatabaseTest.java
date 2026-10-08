package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.opentest4j.AssertionFailedError;
import org.opentest4j.TestAbortedException;

class PostgresTestDatabaseTest {

    @Test
    void skipsOnADeveloperMachineWithoutADatabase() {
        assertThatThrownBy(() -> PostgresTestDatabase.assumeAvailable(Map.of()))
            .isInstanceOf(TestAbortedException.class);
    }

    @Test
    void failsInGitHubActionsOrGitLabWithoutADatabase() {
        assertThatThrownBy(() -> PostgresTestDatabase.assumeAvailable(Map.of("CI", "true")))
            .isInstanceOf(AssertionFailedError.class)
            .hasMessageContaining("TEST_DB_URL");
        assertThatThrownBy(() -> PostgresTestDatabase.assumeAvailable(Map.of("CI", "true", "TEST_DB_URL", " ")))
            .isInstanceOf(AssertionFailedError.class);
    }

    @Test
    void failsInJenkinsWithoutADatabase() {
        assertThatThrownBy(() -> PostgresTestDatabase.assumeAvailable(Map.of("JENKINS_URL", "https://ci.example.internal/")))
            .isInstanceOf(AssertionFailedError.class)
            .hasMessageContaining("TEST_DB_URL");
    }

    @Test
    void runsWhenADatabaseIsConfigured() {
        assertThatCode(() -> PostgresTestDatabase.assumeAvailable(
            Map.of("CI", "true", "TEST_DB_URL", "jdbc:postgresql://localhost:5432/x"))).doesNotThrowAnyException();
    }
}
