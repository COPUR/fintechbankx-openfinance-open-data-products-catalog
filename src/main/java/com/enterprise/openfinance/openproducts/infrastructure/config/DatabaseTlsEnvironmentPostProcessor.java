package com.enterprise.openfinance.openproducts.infrastructure.config;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.Environment;

/**
 * Startup TLS check (guardrail 4a, single form: on by default). It runs in every context
 * that is not explicitly local or test, on every container the chart renders (migrate init
 * container, service container, history guard check): fintechbankx.tls.enforce is true in
 * application.yml (and when unset), and only the local profile (application-local.yml) and
 * the test resources (application.properties) set it false. The chart never sets it and
 * refuses the key, every spring.profiles.* name and the JVM options that could carry them.
 * No profile or deployment marker is needed. It fails startup unless every JDBC URL the
 * service uses (spring.datasource.url, and spring.datasource.hikari.jdbc-url and
 * spring.flyway.url when set) verifies Aurora's certificate: exactly one sslmode, set to
 * verify-full, and exactly one sslrootcert, set to the platform RDS CA bundle the Helm
 * chart mounts. Any other ssl* parameter, or service, is refused too, because it can
 * switch the verification off or redirect the connection. No Hikari data-source property
 * may touch TLS (ssl*, service). The Helm chart checks the same rule at render time; this
 * is the runtime half, so a URL that reaches the pod another way still cannot connect
 * without verification. {@link HikariPoolTlsAssertion} then checks the effective pool
 * after binding, under the same switch.
 *
 * Runs after the config data is loaded and before any bean is created, so no
 * connection is tried.
 */
public class DatabaseTlsEnvironmentPostProcessor implements EnvironmentPostProcessor, Ordered {

    /** The only switch; true unless local or test configuration says otherwise. */
    public static final String ENFORCE_PROPERTY = "fintechbankx.tls.enforce";
    static final String ROOT_CERT = "/etc/fintechbankx/rds-ca/global-bundle.pem";

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        if (!enforced(environment)) {
            return;
        }
        requireVerifiedTls("spring.datasource.url", environment.getProperty("spring.datasource.url"));
        String flywayUrl = environment.getProperty("spring.flyway.url");
        if (flywayUrl != null && !flywayUrl.isBlank()) {
            requireVerifiedTls("spring.flyway.url", flywayUrl);
        }
        // Bound onto the HikariDataSource after spring.datasource.url, so it would replace the checked URL.
        Binder binder = Binder.get(environment);
        binder.bind("spring.datasource.hikari.jdbc-url", String.class)
            .ifBound(url -> requireVerifiedTls("spring.datasource.hikari.jdbc-url", url));
        requireNoTlsDriverProperties("spring.datasource.hikari.data-source-properties",
            binder.bind("spring.datasource.hikari.data-source-properties", Bindable.mapOf(String.class, String.class))
                .orElse(Map.of()).keySet());
    }

    /** True unless the property says false; an unreadable value fails the start. */
    static boolean enforced(Environment environment) {
        return environment.getProperty(ENFORCE_PROPERTY, Boolean.class, true);
    }

    /** Driver properties set outside the URL (Hikari data-source-properties) must not touch TLS. */
    static void requireNoTlsDriverProperties(String property, Iterable<String> names) {
        for (String name : names) {
            String lower = name.toLowerCase(Locale.ROOT);
            if (lower.startsWith("ssl") || lower.equals("service")) {
                throw new IllegalStateException(property + "." + name
                    + " is refused: TLS settings come only from the verified JDBC URL");
            }
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
        return new IllegalStateException(property + " " + reason + ": the service connects to Aurora only with a"
            + " verified certificate (" + ENFORCE_PROPERTY + " is true; only the local profile and the test resources"
            + " set it false, the chart never does)");
    }
}
