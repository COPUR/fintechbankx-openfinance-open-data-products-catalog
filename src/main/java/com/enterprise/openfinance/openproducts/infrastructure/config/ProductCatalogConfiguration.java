package com.enterprise.openfinance.openproducts.infrastructure.config;

import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.JpaProductCatalogAdapter;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.SnapshotProductCatalog;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.SpringDataProductRepository;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** PostgreSQL is the catalogue authority (ADR-0001), read through a short-lived in-process snapshot. */
@Configuration
@ConditionalOnProperty(name = "openproducts.catalog.store", havingValue = "postgres", matchIfMissing = true)
public class ProductCatalogConfiguration {

    @Bean
    ProductCatalogPort productCatalogPort(
        SpringDataProductRepository repository,
        @Value("${openproducts.catalog.snapshot-refresh:10s}") Duration refreshInterval
    ) {
        return new SnapshotProductCatalog(new JpaProductCatalogAdapter(repository), refreshInterval);
    }
}
