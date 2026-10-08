package com.enterprise.openfinance.openproducts.infrastructure.config;

import java.util.Arrays;
import java.util.stream.Stream;
import org.flywaydb.core.api.Location;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.autoconfigure.flyway.FlywayConfigurationCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Adds the sample catalogue (classpath:db/seed) to Flyway only when
 * OPEN_PRODUCTS_SEED_ENABLED=true (dev and CI). Staging and production load
 * the real catalogue with db/import/import-products.sh instead.
 */
@Configuration
@ConditionalOnProperty(name = "openproducts.catalog.seed-enabled", havingValue = "true")
public class CatalogueSeedConfiguration {

    public static final String SEED_LOCATION = "classpath:db/seed";

    @Bean
    FlywayConfigurationCustomizer catalogueSeedLocation() {
        return configuration -> configuration.locations(Stream.concat(
                Arrays.stream(configuration.getLocations()),
                Stream.of(new Location(SEED_LOCATION)))
            .toArray(Location[]::new));
    }
}
