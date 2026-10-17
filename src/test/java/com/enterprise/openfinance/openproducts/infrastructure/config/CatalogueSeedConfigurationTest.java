package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Arrays;
import org.flywaydb.core.api.Location;
import org.flywaydb.core.api.configuration.FluentConfiguration;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.flyway.FlywayConfigurationCustomizer;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class CatalogueSeedConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
        .withUserConfiguration(CatalogueSeedConfiguration.class);

    @Test
    void seedLocationIsOffByDefault() {
        runner.run(context -> assertThat(context).doesNotHaveBean(FlywayConfigurationCustomizer.class));
    }

    @Test
    void seedLocationIsAppendedWhenEnabled() {
        runner.withPropertyValues("openproducts.catalog.seed-enabled=true").run(context -> {
            FluentConfiguration flyway = new FluentConfiguration().locations("classpath:db/migration");
            context.getBean(FlywayConfigurationCustomizer.class).customize(flyway);

            assertThat(Arrays.stream(flyway.getLocations()).map(Location::getDescriptor))
                .containsExactly("classpath:db/migration", "classpath:db/seed");
        });
    }
}
