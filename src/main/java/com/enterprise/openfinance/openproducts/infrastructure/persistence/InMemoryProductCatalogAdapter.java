package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import java.time.Instant;
import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class InMemoryProductCatalogAdapter implements ProductCatalogPort {

    private final List<ProductOffer> productOffers = List.of(
        new ProductOffer("PCA-001", "Everyday Current", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z")),
        new ProductOffer("SAV-001", "Smart Saver", "SAVINGS", "RETAIL", "AED", "0.00", "1.25", Instant.parse("2026-03-02T00:00:00Z")),
        new ProductOffer("SME-LOAN-01", "SME Growth Loan", "LOAN", "SME", "AED", "0.00", "6.75", Instant.parse("2026-03-03T00:00:00Z")),
        new ProductOffer("SME-PCA-01", "SME Current", "PCA", "SME", "AED", "35.00", "0.00", Instant.parse("2026-03-04T00:00:00Z"))
    );

    @Override
    public List<ProductOffer> findAll() {
        return productOffers;
    }
}
