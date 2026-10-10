package com.enterprise.openfinance.openproducts.infrastructure.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * OPEN_PRODUCTS_HISTORY_GUARD_CHECK=true runs the history guard's integrity
 * check and stops: SELECT fbx_history_guard.verify() as the runtime role (the
 * function is granted to PUBLIC). 'armed, intact' closes the context and the
 * JVM exits 0; any other answer, or an error, fails startup with a non-zero
 * exit. The Helm chart runs this from a CronJob (the schedule) and from a
 * pre-upgrade hook Job (the release gate: helm upgrade fails), see the runbook,
 * section 2.3.
 */
@Configuration
@ConditionalOnProperty(name = "openproducts.history-guard-check", havingValue = "true")
public class HistoryGuardCheckConfiguration {

    static final String HEALTHY = "armed, intact";
    private static final Logger LOG = LoggerFactory.getLogger(HistoryGuardCheckConfiguration.class);

    @Bean
    ApplicationRunner checkHistoryGuard(JdbcTemplate jdbc, ConfigurableApplicationContext context) {
        return arguments -> {
            require(jdbc.queryForObject("SELECT fbx_history_guard.verify()", String.class));
            context.close();
        };
    }

    /** Throws unless the answer is 'armed, intact'. */
    static void require(String answer) {
        if (!HEALTHY.equals(answer)) {
            throw new IllegalStateException("history guard check failed: verify() answered '" + answer
                + "'; nothing may be released to this environment until it answers '" + HEALTHY + "' (runbook section 2.3)");
        }
        LOG.info("history guard check passed: verify() answered '{}'", answer);
    }
}
