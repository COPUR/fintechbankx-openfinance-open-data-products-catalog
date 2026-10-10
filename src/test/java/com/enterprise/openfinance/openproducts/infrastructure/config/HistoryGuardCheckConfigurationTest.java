package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.DefaultApplicationArguments;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;

class HistoryGuardCheckConfigurationTest {

    private static final String VERIFY = "SELECT fbx_history_guard.verify()";

    @Test
    void servesRequestsByDefault() {
        new ApplicationContextRunner().withUserConfiguration(HistoryGuardCheckConfiguration.class)
            .withBean(JdbcTemplate.class, () -> mock(JdbcTemplate.class))
            .run(context -> assertThat(context).doesNotHaveBean(ApplicationRunner.class));
    }

    @Test
    void armedAndIntactStopsTheRun() throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(VERIFY, String.class)).thenReturn("armed, intact");
        ConfigurableApplicationContext application = mock(ConfigurableApplicationContext.class);

        new HistoryGuardCheckConfiguration().checkHistoryGuard(jdbc, application).run(new DefaultApplicationArguments());

        verify(application).close();
    }

    @ParameterizedTest
    @ValueSource(strings = {"DISARMED", "CHANGED SINCE ARMED", "EVENT TRIGGERS MISSING OR DISABLED", "GUARD STATE NOT APPEND-ONLY"})
    void anyOtherAnswerFailsTheRun(String answer) {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(VERIFY, String.class)).thenReturn(answer);
        ConfigurableApplicationContext application = mock(ConfigurableApplicationContext.class);

        assertThatThrownBy(() -> new HistoryGuardCheckConfiguration().checkHistoryGuard(jdbc, application)
                .run(new DefaultApplicationArguments()))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageStartingWith("history guard check failed: verify() answered '" + answer + "'");
        verify(application, never()).close();
    }

    @Test
    void aMissingAnswerFails() {
        assertThatThrownBy(() -> HistoryGuardCheckConfiguration.require(null))
            .hasMessageStartingWith("history guard check failed: verify() answered 'null'");
    }
}
