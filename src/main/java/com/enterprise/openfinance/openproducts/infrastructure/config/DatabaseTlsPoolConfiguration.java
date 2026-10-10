package com.enterprise.openfinance.openproducts.infrastructure.config;

import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/**
 * Registers {@link HikariPoolTlsAssertion} whatever the profiles; it does nothing without the
 * deployment marker FBX_DEPLOYED and the aws profile (tests, local runs).
 */
@Configuration(proxyBeanMethods = false)
public class DatabaseTlsPoolConfiguration {

    @Bean
    static BeanPostProcessor databaseTlsPoolAssertion(Environment environment) {
        return new HikariPoolTlsAssertion(environment, System::getenv);
    }
}
