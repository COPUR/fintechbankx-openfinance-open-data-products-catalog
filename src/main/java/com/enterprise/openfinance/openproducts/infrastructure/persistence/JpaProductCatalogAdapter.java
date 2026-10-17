package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.mapper.ProductEntityMapper;
import java.time.Instant;
import java.util.List;
import org.springframework.transaction.annotation.Transactional;

/**
 * PostgreSQL-backed catalogue: the authority for products (ADR-0001). Wired by
 * ProductCatalogConfiguration behind a SnapshotProductCatalog.
 */
public class JpaProductCatalogAdapter implements ProductCatalogPort {

    private final SpringDataProductRepository repository;

    public JpaProductCatalogAdapter(SpringDataProductRepository repository) {
        this.repository = repository;
    }

    @Override
    @Transactional(readOnly = true)
    public List<CatalogueEntry> findOfferable(ListProductsQuery query, Instant asOf) {
        return repository.findOfferable(query.type(), query.segment(), asOf)
            .stream()
            .map(ProductEntityMapper::toDomain)
            .toList();
    }
}
