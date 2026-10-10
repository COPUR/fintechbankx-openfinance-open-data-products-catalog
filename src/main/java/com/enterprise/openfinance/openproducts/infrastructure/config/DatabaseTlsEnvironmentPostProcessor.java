package com.enterprise.openfinance.openproducts.infrastructure.config;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;

/**
 * Fails startup under the aws profile, and whenever the chart-owned deployment marker
 * FBX_DEPLOYED is in the process environment (the chart renders it directly on every
 * container, never from values, and refuses config.FBX_DEPLOYED), unless every JDBC URL
 * the service uses (spring.datasource.url, and spring.datasource.hikari.jdbc-url and
 * spring.flyway.url when set) verifies Aurora's
 * certificate: exactly one sslmode, set to verify-full, and exactly one
 * sslrootcert, set to the platform RDS CA bundle the Helm chart mounts. Any
 * other ssl* parameter, or service, is refused too, because it can switch the
 * verification off or redirect the connection. The Helm chart checks the same
 * rule at render time and sets SPRING_PROFILES_ACTIVE=aws on every container;
 * this is the runtime half, so a URL that reaches the pod another way still
 * cannot connect without verification. No Hikari data-source property may touch TLS
 * (ssl*, service). With the marker, startup also fails unless the aws profile is active
 * and no local, test or in-memory profile is, so a profile set or baked in some other
 * way cannot switch the check off; {@link HikariPoolTlsAssertion} then checks the
 * effective pool after binding.
 *
 * Runs after the config data is loaded and before any bean is created, so no
 * connection is tried. Without the marker and the aws profile (tests, local
 * runs) it does nothing.
 */
public class DatabaseTlsEnvironmentPostProcessor implements EnvironmentPostProcessor, Ordered {

    static final String PROFILE = "aws";
    static final String ROOT_CERT = "/etc/fintechbankx/rds-ca/global-bundle.pem";
    /** Rendered by the chart on every container; read from the process environment only. */
    static final String DEPLOYED_MARKER = "FBX_DEPLOYED";
    /** Profiles for local runs and tests (in-memory catalogue); never active in a deployment. */
    static final Set<String> LOCAL_PROFILES = Set.of("local", "test", "in-memory");

    private final Function<String, String> processEnvironment;

    public DatabaseTlsEnvironmentPostProcessor() {
        this(System::getenv);
    }

    DatabaseTlsEnvironmentPostProcessor(Function<String, String> processEnvironment) {
        this.processEnvironment = processEnvironment;
    }

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        if (isDeployed(processEnvironment)) {
            requireDeployedProfiles(environment);
        }
        if (!enforced(environment, processEnvironment)) {
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

    /** Any value counts: the chart renders "true", and values can neither set nor clear it. */
    static boolean isDeployed(Function<String, String> processEnvironment) {
        return processEnvironment.apply(DEPLOYED_MARKER) != null;
    }

    static boolean enforced(Environment environment, Function<String, String> processEnvironment) {
        return isDeployed(processEnvironment) || environment.acceptsProfiles(Profiles.of(PROFILE));
    }

    static void requireDeployedProfiles(Environment environment) {
        List<String> active = Arrays.asList(environment.getActiveProfiles());
        String hint = DEPLOYED_MARKER + " is set (chart-rendered deployment), so the active profiles must include "
            + PROFILE + " and no local profile " + LOCAL_PROFILES + "; active: " + active;
        if (!active.contains(PROFILE)) {
            throw new IllegalStateException(hint + " (the " + PROFILE + " profile is missing)");
        }
        active.stream().filter(profile -> LOCAL_PROFILES.contains(profile.toLowerCase(Locale.ROOT))).findFirst()
            .ifPresent(profile -> {
                throw new IllegalStateException(hint + " (local profile " + profile + " is active)");
            });
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
        return new IllegalStateException(property + " " + reason + " under the " + PROFILE
            + " profile: the service connects to Aurora only with a verified certificate");
    }
}
