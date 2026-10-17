package com.enterprise.openfinance.openproducts.infrastructure.config;

import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OPEN_PRODUCTS_MIGRATE_ONLY=true runs the schema migration and stops: the
 * context starts (Flyway migrates as FLYWAY_USER, Hibernate validates the
 * mapping), then closes and the JVM exits 0; a failed migration fails startup
 * with a non-zero exit. The Helm chart runs this in an init container with the
 * owner credential, so the serving container only holds the runtime role.
 */
@Configuration
@ConditionalOnProperty(name = "openproducts.migrate-only", havingValue = "true")
public class MigrateOnlyConfiguration {

    @Bean
    ApplicationRunner stopAfterMigration(ConfigurableApplicationContext context) {
        return arguments -> context.close();
    }
}
