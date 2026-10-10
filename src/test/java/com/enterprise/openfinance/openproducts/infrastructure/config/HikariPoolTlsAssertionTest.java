package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.zaxxer.hikari.HikariDataSource;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.mock.env.MockEnvironment;

/** Round 8: the effective pool after binding, before it opens (no connection is made here). */
class HikariPoolTlsAssertionTest {

    private static final String GOOD = "jdbc:postgresql://writer.example.internal:5432/db_of_open_products_catalog_dev"
        + "?sslmode=verify-full&sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem";
    private static final Function<String, String> DEPLOYED = name -> "FBX_DEPLOYED".equals(name) ? "true" : null;
    private static final Function<String, String> NOT_DEPLOYED = name -> null;

    private static HikariDataSource pool(String jdbcUrl) {
        HikariDataSource pool = new HikariDataSource();
        pool.setJdbcUrl(jdbcUrl);
        return pool;
    }

    private static HikariPoolTlsAssertion assertion(String profiles, Function<String, String> processEnvironment) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(profiles.isEmpty() ? new String[0] : profiles.split(","));
        return new HikariPoolTlsAssertion(environment, processEnvironment);
    }

    @Test
    void acceptsAVerifiedPoolAndLeavesOtherBeansAlone() {
        try (HikariDataSource pool = pool(GOOD)) {
            assertThat(assertion("", DEPLOYED).postProcessAfterInitialization(pool, "dataSource")).isSameAs(pool);
        }
        Object other = new Object();
        assertThat(assertion("aws", NOT_DEPLOYED).postProcessAfterInitialization(other, "other")).isSameAs(other);
    }

    @Test
    void refusesAPoolUrlWithATrailingWeakerSslmode() {
        try (HikariDataSource pool = pool(GOOD + "&sslmode=require")) {
            assertThatThrownBy(() -> assertion("", DEPLOYED).postProcessAfterInitialization(pool, "dataSource"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageStartingWith("DataSource dataSource jdbcUrl must set sslmode exactly once");
        }
    }

    @Test
    void refusesTlsDataSourcePropertiesAndADataSourceClassName() {
        for (String key : new String[] {"sslmode", "sslfactory", "SSLROOTCERT", "service"}) {
            try (HikariDataSource pool = pool(GOOD)) {
                pool.addDataSourceProperty(key, "x");
                assertThatThrownBy(() -> assertion("aws", NOT_DEPLOYED).postProcessAfterInitialization(pool, "dataSource"))
                    .as(key).isInstanceOf(IllegalStateException.class)
                    .hasMessageContaining("dataSourceProperties." + key + " is refused");
            }
        }
        try (HikariDataSource pool = pool(GOOD)) {
            pool.setDataSourceClassName("org.postgresql.ds.PGSimpleDataSource");
            assertThatThrownBy(() -> assertion("", DEPLOYED).postProcessAfterInitialization(pool, "dataSource"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("not a dataSourceClassName or DataSource");
        }
    }

    @Test
    void doesNothingWithoutTheMarkerOrTheAwsProfile() {
        try (HikariDataSource pool = pool("jdbc:postgresql://localhost:5432/x")) {
            pool.addDataSourceProperty("sslmode", "disable");
            assertThat(assertion("in-memory", NOT_DEPLOYED).postProcessAfterInitialization(pool, "dataSource")).isSameAs(pool);
        }
    }

    @Test
    void isWiredOntoTheAutoConfiguredPool() {
        // Hikari ignores jdbcUrl (sslmode included) when a dataSourceClassName is bound.
        ApplicationContextRunner withPool = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(DataSourceAutoConfiguration.class))
            .withUserConfiguration(DatabaseTlsPoolConfiguration.class)
            .withPropertyValues("spring.profiles.active=aws", "spring.datasource.url=" + GOOD);
        withPool.run(context -> assertThat(context).hasNotFailed().hasSingleBean(HikariDataSource.class));
        withPool.withPropertyValues("spring.datasource.hikari.data-source-class-name=org.postgresql.ds.PGSimpleDataSource")
            .run(context -> {
                assertThat(context).hasFailed();
                assertThat(NestedExceptionUtils.getMostSpecificCause(context.getStartupFailure()))
                    .isInstanceOf(IllegalStateException.class)
                    .hasMessageContaining("must connect through its verified jdbcUrl, not a dataSourceClassName");
            });
    }
}
