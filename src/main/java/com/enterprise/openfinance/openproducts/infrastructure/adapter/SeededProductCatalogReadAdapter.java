package com.enterprise.openfinance.openproducts.infrastructure.adapter;

import com.enterprise.openfinance.openproducts.application.port.out.ProductCatalogReadPort;
import com.enterprise.openfinance.openproducts.domain.Product;
import org.springframework.stereotype.Component;

import java.time.OffsetDateTime;
import java.util.List;

@Component
public class SeededProductCatalogReadAdapter implements ProductCatalogReadPort {

    @Override
    public List<Product> findAll() {
        return List.of(
                new Product("PRD-PCA-001", "Current Plus", "PCA", "RETAIL", "AED", "0.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z")),
                new Product("PRD-SME-LOAN-001", "SME Growth Loan", "LOAN", "SME", "AED", "25.00", "5.20", OffsetDateTime.parse("2026-03-01T00:00:00Z")),
                new Product("PRD-CORP-CARD-001", "Corporate Rewards Card", "CARD", "CORPORATE", "AED", "45.00", "2.10", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        );
    }
}
