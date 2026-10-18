package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.zaxxer.hikari.HikariDataSource;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.PropertiesPropertySourceLoader;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.core.env.PropertySource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.mock.env.MockEnvironment;

/**
 * Guardrail 4a, single form (governance, lending's TlsEnforcement): the startup TLS
 * assertion is on by default. fintechbankx.tls.enforce is true in application.yml and only
 * explicit local and test configuration sets it false: the local profile
 * (application-local.yml) and the test resources (application.properties). No profile, no
 * deployment marker and no other setting is needed for the check to run, and no profile
 * (local, test, in-memory) switches it off by itself; the chart never sets the switch and
 * refuses the key and every profile name.
 */
class TlsEnforcementByDefaultTest {

    private static final String VERIFIED = "jdbc:postgresql://writer.example.internal:5432/db_of_open_products_catalog_dev"
        + "?sslmode=verify-full&sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem";
    private static final String UNVERIFIED = "jdbc:postgresql://localhost:5432/db_of_open_products_catalog_local";

    private static MockEnvironment environment(String url, String... profiles) {
        MockEnvironment environment = new MockEnvironment().withProperty("spring.datasource.url", url);
        environment.setActiveProfiles(profiles);
        return environment;
    }

    private static void postProcess(MockEnvironment environment) {
        new DatabaseTlsEnvironmentPostProcessor().postProcessEnvironment(environment, new SpringApplication());
    }

    private static PropertySource<?> yaml(String name) throws Exception {
        return new YamlPropertySourceLoader().load(name, new ClassPathResource(name)).getFirst();
    }

    @Test
    void theCheckRunsWithNoProfileAndNoMarker() {
        assertThatThrownBy(() -> postProcess(environment(UNVERIFIED)))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageStartingWith("spring.datasource.url must set sslmode=verify-full");
        assertThatCode(() -> postProcess(environment(VERIFIED))).doesNotThrowAnyException();
    }

    @Test
    void noProfileSwitchesItOffByItself() {
        for (String profile : List.of("local", "test", "in-memory", "default")) {
            assertThatThrownBy(() -> postProcess(environment(UNVERIFIED, profile)))
                .as(profile).isInstanceOf(IllegalStateException.class)
                .hasMessageStartingWith("spring.datasource.url must set sslmode=verify-full");
        }
    }

    @Test
    void enforceFalseSwitchesItOffWhateverTheProfiles() {
        for (String[] profiles : List.of(new String[0], new String[] {"aws"})) {
            assertThatCode(() -> postProcess(environment(UNVERIFIED, profiles).withProperty("fintechbankx.tls.enforce", "false")))
                .as(String.join(",", profiles)).doesNotThrowAnyException();
        }
    }

    @Test
    void theEffectivePoolIsCheckedWithNoProfileAndNoMarker() {
        new ApplicationContextRunner()
            .withUserConfiguration(DatabaseTlsPoolConfiguration.class)
            .withBean("dataSource", HikariDataSource.class, () -> {
                HikariDataSource pool = new HikariDataSource();
                pool.setJdbcUrl(VERIFIED.replace("sslmode=verify-full", "sslmode=require"));
                return pool;
            })
            .run(context -> {
                assertThat(context).hasFailed();
                assertThat(NestedExceptionUtils.getMostSpecificCause(context.getStartupFailure()).getMessage())
                    .startsWith("DataSource dataSource jdbcUrl must set sslmode=verify-full");
            });
    }

    @Test
    void theServiceEnforcesTlsByDefault() throws Exception {
        List<PropertySource<?>> documents = new YamlPropertySourceLoader()
            .load("application.yml", new ClassPathResource("application.yml"));

        assertThat(documents).hasSize(1);
        assertThat(documents.getFirst().getProperty("fintechbankx.tls.enforce")).isEqualTo(true);
    }

    @Test
    void onlyTheLocalProfileSwitchesItOff() throws Exception {
        assertThat(yaml("application-local.yml").getProperty("fintechbankx.tls.enforce")).isEqualTo(false);
        assertThat(yaml("application-in-memory.yml").getProperty("fintechbankx.tls.enforce")).isNull();
    }

    @Test
    void theTestResourcesSwitchItOffForTheIntegrationTests() throws Exception {
        PropertySource<?> tests = new PropertiesPropertySourceLoader()
            .load("application.properties", new ClassPathResource("application.properties")).getFirst();

        assertThat(tests.getProperty("fintechbankx.tls.enforce")).isEqualTo("false");
    }
}
