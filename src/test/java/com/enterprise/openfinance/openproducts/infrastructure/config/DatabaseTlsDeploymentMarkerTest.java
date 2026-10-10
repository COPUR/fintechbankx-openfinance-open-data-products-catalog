package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.mock.env.MockEnvironment;

/**
 * Round 8: the chart renders FBX_DEPLOYED=true on the migrate init container, the service
 * container and the history guard check pods (never from values). With it the check runs
 * whatever the profiles, and startup fails unless aws is active and no local, test or
 * in-memory profile is. Without it behaviour is unchanged.
 */
class DatabaseTlsDeploymentMarkerTest {

    private static final String GOOD = "jdbc:postgresql://writer.example.internal:5432/db_of_open_products_catalog_dev"
        + "?sslmode=verify-full&sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem";
    private static final Function<String, String> DEPLOYED = name -> "FBX_DEPLOYED".equals(name) ? "true" : null;
    private static final Function<String, String> NOT_DEPLOYED = name -> null;

    private static MockEnvironment environment(String profiles, String url) {
        MockEnvironment environment = new MockEnvironment().withProperty("spring.datasource.url", url);
        environment.setActiveProfiles(profiles.isEmpty() ? new String[0] : profiles.split(","));
        return environment;
    }

    private static void run(Function<String, String> processEnvironment, MockEnvironment environment) {
        new DatabaseTlsEnvironmentPostProcessor(processEnvironment).postProcessEnvironment(environment, new SpringApplication());
    }

    @Test
    void withTheMarkerTheChartProfileWithVerifiedTlsStarts() {
        assertThatCode(() -> run(DEPLOYED, environment("aws", GOOD))).doesNotThrowAnyException();
    }

    @Test
    void withTheMarkerStartupFailsWithoutTheAwsProfile() {
        for (String profiles : List.of("", "default", "in-memory")) {
            assertThatThrownBy(() -> run(DEPLOYED, environment(profiles, GOOD)))
                .as(profiles).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("FBX_DEPLOYED is set");
        }
        assertThatThrownBy(() -> run(DEPLOYED, environment("", GOOD)))
            .hasMessageContaining("the aws profile is missing");
    }

    @Test
    void withTheMarkerALocalTestOrInMemoryProfileIsRefused() {
        for (String profiles : List.of("aws,in-memory", "local,aws", "aws,test", "aws,IN-MEMORY")) {
            assertThatThrownBy(() -> run(DEPLOYED, environment(profiles, GOOD)))
                .as(profiles).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("local profile");
        }
    }

    @Test
    void withTheMarkerTheUrlIsStillChecked() {
        assertThatThrownBy(() -> run(DEPLOYED, environment("aws", GOOD + "&sslmode=disable")))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageStartingWith("spring.datasource.url ");
    }

    @Test
    void anyMarkerValueEnforces() {
        assertThatThrownBy(() -> run(name -> "FBX_DEPLOYED".equals(name) ? "" : null, environment("", GOOD)))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("the aws profile is missing");
    }

    @Test
    void withoutTheMarkerBehaviourIsUnchanged() {
        assertThatCode(() -> run(NOT_DEPLOYED, environment("in-memory", "jdbc:postgresql://localhost:5432/x")))
            .doesNotThrowAnyException();
        assertThatThrownBy(() -> run(NOT_DEPLOYED, environment("aws", "jdbc:postgresql://localhost:5432/x")))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageStartingWith("spring.datasource.url ");
    }
}
