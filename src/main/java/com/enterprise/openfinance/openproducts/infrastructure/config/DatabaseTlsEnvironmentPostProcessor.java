package com.enterprise.openfinance.openproducts.infrastructure.config;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.Profiles;

/**
 * Fails startup under the aws profile unless every JDBC URL the service uses
 * (spring.datasource.url, and spring.flyway.url when set) verifies Aurora's
 * certificate: exactly one sslmode, set to verify-full, and exactly one
 * sslrootcert, set to the platform RDS CA bundle the Helm chart mounts. Any
 * other ssl* parameter, or service, is refused too, because it can switch the
 * verification off or redirect the connection. The Helm chart checks the same
 * rule at render time and sets SPRING_PROFILES_ACTIVE=aws on every container;
 * this is the runtime half, so a URL that reaches the pod another way still
 * cannot connect without verification.
 *
 * Runs after the config data is loaded and before any bean is created, so no
 * connection is tried. Without the aws profile (tests, local runs) it does
 * nothing.
 */
public class DatabaseTlsEnvironmentPostProcessor implements EnvironmentPostProcessor, Ordered {

    static final String PROFILE = "aws";
    static final String ROOT_CERT = "/etc/fintechbankx/rds-ca/global-bundle.pem";

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        if (!environment.acceptsProfiles(Profiles.of(PROFILE))) {
            return;
        }
        requireVerifiedTls("spring.datasource.url", environment.getProperty("spring.datasource.url"));
        String flywayUrl = environment.getProperty("spring.flyway.url");
        if (flywayUrl != null && !flywayUrl.isBlank()) {
            requireVerifiedTls("spring.flyway.url", flywayUrl);
        }
    }

    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE;
    }

    /** Throws IllegalStateException naming the property unless the URL verifies the server certificate. */
    static void requireVerifiedTls(String property, String url) {
        String expected = "sslmode=verify-full&sslrootcert=" + ROOT_CERT;
        if (url == null || !url.startsWith("jdbc:postgresql://")) {
            throw refused(property, "must be a jdbc:postgresql:// URL with " + expected);
        }
        int query = url.indexOf('?');
        if (query < 0) {
            throw refused(property, "must set sslmode=verify-full (and sslrootcert=" + ROOT_CERT + ")");
        }
        String parameters = url.substring(query + 1);
        if (parameters.contains("?") || parameters.contains("#")) {
            throw refused(property, "must not contain a fragment or a second '?'");
        }
        List<String> sslmode = new ArrayList<>();
        List<String> sslrootcert = new ArrayList<>();
        for (String pair : parameters.split("&", -1)) {
            int equals = pair.indexOf('=');
            String name = (equals < 0 ? pair : pair.substring(0, equals)).toLowerCase(Locale.ROOT);
            String value = equals < 0 ? "" : pair.substring(equals + 1);
            switch (name) {
                case "sslmode" -> sslmode.add(value);
                case "sslrootcert" -> sslrootcert.add(value);
                default -> {
                    if (name.startsWith("ssl") || name.equals("service")) {
                        throw refused(property, "must not set " + name + ": only " + expected + " may configure TLS");
                    }
                }
            }
        }
        if (sslmode.size() > 1) {
            throw refused(property, "must set sslmode exactly once (found " + sslmode.size() + ")");
        }
        if (sslmode.isEmpty() || !sslmode.get(0).equals("verify-full")) {
            throw refused(property, "must set sslmode=verify-full");
        }
        if (sslrootcert.size() != 1 || !sslrootcert.get(0).equals(ROOT_CERT)) {
            throw refused(property, "must set sslrootcert=" + ROOT_CERT + " exactly once (the platform RDS CA bundle)");
        }
    }

    private static IllegalStateException refused(String property, String reason) {
        return new IllegalStateException(property + " " + reason + " under the " + PROFILE
            + " profile: the service connects to Aurora only with a verified certificate");
    }
}
