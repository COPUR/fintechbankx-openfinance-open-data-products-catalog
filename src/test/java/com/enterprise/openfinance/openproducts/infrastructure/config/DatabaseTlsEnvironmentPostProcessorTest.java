package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.SpringApplication;
import org.springframework.mock.env.MockEnvironment;

class DatabaseTlsEnvironmentPostProcessorTest {

    private static final String CA = "sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem";
    private static final String GOOD = "jdbc:postgresql://writer.example.internal:5432/db_of_open_products_catalog_dev?sslmode=verify-full&" + CA;

    private final DatabaseTlsEnvironmentPostProcessor processor = new DatabaseTlsEnvironmentPostProcessor();

    @Test
    void acceptsTheTerraformJdbcUrlAndAnAllowedExtraParameter() {
        assertThatCode(() -> processor.postProcessEnvironment(aws(GOOD), new SpringApplication())).doesNotThrowAnyException();
        assertThatCode(() -> DatabaseTlsEnvironmentPostProcessor.requireVerifiedTls("u", GOOD + "&connectTimeout=5"))
            .doesNotThrowAnyException();
    }

    @Test
    void withoutTheAwsProfileNothingIsChecked() {
        MockEnvironment local = new MockEnvironment().withProperty("spring.datasource.url", "jdbc:postgresql://localhost:5432/x");
        assertThatCode(() -> processor.postProcessEnvironment(local, new SpringApplication())).doesNotThrowAnyException();
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "jdbc:postgresql://h/x",
        "jdbc:postgresql://h/x?sslmode=require&" + CA,
        "jdbc:postgresql://h/x?sslmode=verify-ca&" + CA,
        "jdbc:postgresql://h/x?" + CA,
        "jdbc:postgresql://h/x?sslmode=verify-full",
        "jdbc:postgresql://h/x?sslmode=verify-full&sslrootcert=/tmp/other.pem",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&sslmode=disable",
        "jdbc:postgresql://h/x?sslmode=disable&sslmode=verify-full&" + CA,
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&SSLMODE=disable",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&sslrootcert=/tmp/other.pem",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&sslfactory=org.postgresql.ssl.NonValidatingFactory",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&sslhostnameverifier=x.AllowAll",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "&service=other",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "#sslmode=disable",
        "jdbc:postgresql://h/x?sslmode=verify-full&" + CA + "?sslmode=disable",
        "jdbc:mysql://h/x?sslmode=verify-full&" + CA,
    })
    void refusesAnyUrlThatDoesNotVerifyTheCertificate(String url) {
        assertThatThrownBy(() -> processor.postProcessEnvironment(aws(url), new SpringApplication()))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageStartingWith("spring.datasource.url ")
            .hasMessageContaining("under the aws profile");
    }

    @Test
    void refusesAMissingDatasourceUrl() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("aws");
        assertThatThrownBy(() -> processor.postProcessEnvironment(environment, new SpringApplication()))
            .hasMessageContaining("must be a jdbc:postgresql:// URL");
    }

    @Test
    void alsoChecksASeparateFlywayUrl() {
        MockEnvironment environment = aws(GOOD).withProperty("spring.flyway.url", "jdbc:postgresql://h/x?sslmode=disable");
        assertThatThrownBy(() -> processor.postProcessEnvironment(environment, new SpringApplication()))
            .hasMessageStartingWith("spring.flyway.url must set sslmode=verify-full");
        assertThatCode(() -> processor.postProcessEnvironment(aws(GOOD).withProperty("spring.flyway.url", GOOD), new SpringApplication()))
            .doesNotThrowAnyException();
    }

    private static MockEnvironment aws(String url) {
        MockEnvironment environment = new MockEnvironment().withProperty("spring.datasource.url", url);
        environment.setActiveProfiles("aws");
        return environment;
    }
}
