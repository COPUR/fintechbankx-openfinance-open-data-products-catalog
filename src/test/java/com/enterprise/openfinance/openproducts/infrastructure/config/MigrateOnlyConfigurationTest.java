package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import org.junit.jupiter.api.Test;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.DefaultApplicationArguments;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.ConfigurableApplicationContext;

class MigrateOnlyConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
        .withUserConfiguration(MigrateOnlyConfiguration.class);

    @Test
    void securityChainIsOnlyBuiltWhenThereIsAWebServer() {
        new ApplicationContextRunner().withUserConfiguration(SecurityConfiguration.class)
            .run(context -> assertThat(context).hasNotFailed().doesNotHaveBean(SecurityConfiguration.class));
    }

    @Test
    void servesRequestsByDefault() {
        runner.run(context -> assertThat(context).doesNotHaveBean(ApplicationRunner.class));
    }

    @Test
    void migrateOnlyRunStopsOnceFlywayAndSchemaValidationHaveRun() throws Exception {
        runner.withPropertyValues("openproducts.migrate-only=true").run(context -> {
            assertThat(context).hasSingleBean(ApplicationRunner.class);
        });

        ConfigurableApplicationContext application = mock(ConfigurableApplicationContext.class);
        new MigrateOnlyConfiguration().stopAfterMigration(application).run(new DefaultApplicationArguments());

        verify(application).close();
    }
}
