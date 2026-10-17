package com.enterprise.openfinance.openproducts.domain.port.out;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Instant;
import java.util.List;

/** Read access to the product catalogue (PostgreSQL is the authority). */
public interface ProductCatalogPort {

    /**
     * Catalogue entries that may be offered at {@code asOf} and match the query.
     * Adapters may narrow the result in storage (status, effective window,
     * type, segment); the caller re-applies {@link CatalogueEntry#isOfferedAt}
     * and {@link CatalogueEntry#matches}, so returning a superset is allowed.
     */
    List<CatalogueEntry> findOfferable(ListProductsQuery query, Instant asOf);
}
