package com.enterprise.openfinance.openproducts.infrastructure.etag;

import com.enterprise.openfinance.openproducts.domain.Product;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class ProductEtagServiceTest {

    private final ProductEtagService etagService = new ProductEtagService();

    @Test
    void shouldGenerateStableHashForSamePayload() {
        List<Product> products = List.of(
                new Product("P1", "Current Plus", "PCA", "RETAIL", "AED", "0.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        );

        String first = etagService.compute(products, "PCA", "RETAIL");
        String second = etagService.compute(products, "PCA", "RETAIL");
        assertThat(first).isEqualTo(second);
    }

    @Test
    void shouldChangeHashWhenAmountRelatedFieldChanges() {
        List<Product> left = List.of(
                new Product("P1", "Current Plus", "PCA", "RETAIL", "AED", "0.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        );
        List<Product> right = List.of(
                new Product("P1", "Current Plus", "PCA", "RETAIL", "AED", "2.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        );

        String first = etagService.compute(left, "PCA", "RETAIL");
        String second = etagService.compute(right, "PCA", "RETAIL");
        assertThat(first).isNotEqualTo(second);
    }
}
