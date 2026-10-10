package com.enterprise.openfinance.openproducts.infrastructure.config;

import com.zaxxer.hikari.HikariDataSource;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.core.env.Environment;

/**
 * Checks the effective connection pool, not only the properties: after
 * spring.datasource.hikari.* is bound onto the HikariDataSource and before the pool opens
 * (it opens on the first getConnection), its jdbcUrl must pass the same verify-full rule as
 * {@link DatabaseTlsEnvironmentPostProcessor}, no data-source property may touch TLS (ssl*,
 * service), and no dataSourceClassName or DataSource may replace the URL (Hikari would ignore
 * jdbcUrl, sslmode included). Active under the same condition: the deployment marker or the
 * aws profile.
 */
final class HikariPoolTlsAssertion implements BeanPostProcessor {

    private final Environment environment;
    private final Function<String, String> processEnvironment;

    HikariPoolTlsAssertion(Environment environment, Function<String, String> processEnvironment) {
        this.environment = environment;
        this.processEnvironment = processEnvironment;
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        if (bean instanceof HikariDataSource pool
            && DatabaseTlsEnvironmentPostProcessor.enforced(environment, processEnvironment)) {
            String where = "DataSource " + beanName;
            if (pool.getDataSourceClassName() != null || pool.getDataSource() != null) {
                throw new IllegalStateException(where + " must connect through its verified jdbcUrl, not a"
                    + " dataSourceClassName or DataSource (spring.datasource.hikari.data-source-class-name)");
            }
            DatabaseTlsEnvironmentPostProcessor.requireVerifiedTls(where + " jdbcUrl", pool.getJdbcUrl());
            List<String> names = new ArrayList<>();
            pool.getDataSourceProperties().keySet().forEach(key -> names.add(String.valueOf(key)));
            DatabaseTlsEnvironmentPostProcessor.requireNoTlsDriverProperties(where + " dataSourceProperties", names);
        }
        return bean;
    }
}
