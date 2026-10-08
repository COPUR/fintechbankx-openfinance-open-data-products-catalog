package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.model.ProductStatus;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Instant;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * Test-only catalogue holding the same sample rows as db/seed/R__sample_products.sql
 * plus one withdrawn product. Active only with openproducts.catalog.store=in-memory.
 */
@Component
@ConditionalOnProperty(name = "openproducts.catalog.store", havingValue = "in-memory")
public class InMemoryProductCatalogAdapter implements ProductCatalogPort {

    static final List<CatalogueEntry> SAMPLE = List.of(
        active(new ProductOffer("PCA-001", "Everyday Current", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z"))),
        active(new ProductOffer("SAV-001", "Smart Saver", "SAVINGS", "RETAIL", "AED", "0.00", "1.25", Instant.parse("2026-03-02T00:00:00Z"))),
        active(new ProductOffer("SME-LOAN-01", "SME Growth Loan", "LOAN", "SME", "AED", "0.00", "6.75", Instant.parse("2026-03-03T00:00:00Z"))),
        active(new ProductOffer("SME-PCA-01", "SME Current", "PCA", "SME", "AED", "35.00", "0.00", Instant.parse("2026-03-04T00:00:00Z"))),
        new CatalogueEntry(
            new ProductOffer("PCA-OLD", "Legacy Current", "PCA", "RETAIL", "AED", "5.00", "0.00", Instant.parse("2026-01-01T00:00:00Z")),
            ProductStatus.WITHDRAWN, Instant.parse("2025-01-01T00:00:00Z"), null)
    );

    private final List<CatalogueEntry> entries;

    public InMemoryProductCatalogAdapter() {
        this(SAMPLE);
    }

    public InMemoryProductCatalogAdapter(List<CatalogueEntry> entries) {
        this.entries = List.copyOf(entries);
    }

    /** Returns everything; the application applies the offer rules. */
    @Override
    public List<CatalogueEntry> findOfferable(ListProductsQuery query, Instant asOf) {
        return entries;
    }

    private static CatalogueEntry active(ProductOffer offer) {
        return new CatalogueEntry(offer, ProductStatus.ACTIVE, offer.updatedAt(), null);
    }
}
