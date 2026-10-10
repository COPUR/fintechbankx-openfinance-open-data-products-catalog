package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.enterprise.openfinance.openproducts.Application;
import org.junit.jupiter.api.Test;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;

/**
 * Under the aws profile (set by the Helm chart on every container), the
 * service refuses to start unless its JDBC URLs verify Aurora's certificate:
 * exactly one sslmode=verify-full and the platform RDS CA bundle as
 * sslrootcert. The check runs before any bean, so no connection is tried.
 * Port 1 on loopback makes any connection attempt fail differently.
 */
class DatabaseTlsStartupTest {

    private static final String CA = "sslrootcert=/etc/fintechbankx/rds-ca/global-bundle.pem";

    @Test
    void awsProfileRefusesToStartWithoutVerifiedTls() {
        assertThatThrownBy(() -> start("jdbc:postgresql://127.0.0.1:1/x?sslmode=require&" + CA))
            .hasStackTraceContaining("spring.datasource.url must set sslmode=verify-full");
    }

    @Test
    void awsProfileRefusesARepeatedSslmode() {
        assertThatThrownBy(() -> start("jdbc:postgresql://127.0.0.1:1/x?sslmode=verify-full&" + CA + "&SSLMODE=disable"))
            .hasStackTraceContaining("spring.datasource.url must set sslmode exactly once");
    }

    @Test
    void awsProfileRefusesAnotherRootCertificate() {
        assertThatThrownBy(() -> start("jdbc:postgresql://127.0.0.1:1/x?sslmode=verify-full&sslrootcert=/tmp/other.pem"))
            .hasStackTraceContaining("spring.datasource.url must set " + CA);
    }

    private static void start(String url) {
        new SpringApplicationBuilder(Application.class)
            .web(WebApplicationType.NONE)
            .profiles("aws")
            .properties("spring.datasource.url=" + url, "spring.datasource.hikari.connection-timeout=250",
                "spring.flyway.connect-retries=0")
            .run()
            .close();
    }
}
