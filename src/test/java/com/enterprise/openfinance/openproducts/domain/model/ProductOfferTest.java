package com.enterprise.openfinance.openproducts.domain.model;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class ProductOfferTest {

    @Test
    void shouldCreateValidProductOffer() {
        ProductOffer offer = new ProductOffer(
            "PCA-001",
            "Everyday Current",
            "PCA",
            "RETAIL",
            "AED",
            "0.00",
            "1.25",
            Instant.parse("2026-03-01T00:00:00Z")
        );

        assertEquals("PCA-001", offer.productId());
    }

    @Test
    void shouldRejectInvalidMoneyFormat() {
        assertThrows(IllegalArgumentException.class, () -> new ProductOffer(
            "PCA-001",
            "Everyday Current",
            "PCA",
            "RETAIL",
            "AED",
            "-1",
            "1.25",
            Instant.parse("2026-03-01T00:00:00Z")
        ));
    }
}
