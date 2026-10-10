package com.enterprise.openfinance.openproducts.infrastructure.config;

import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/**
 * Registers {@link HikariPoolTlsAssertion} whatever the profiles; it checks every pool unless
 * fintechbankx.tls.enforce is false (local profile and tests only).
 */
@Configuration(proxyBeanMethods = false)
public class DatabaseTlsPoolConfiguration {

    @Bean
    static BeanPostProcessor databaseTlsPoolAssertion(Environment environment) {
        return new HikariPoolTlsAssertion(environment);
    }
}
