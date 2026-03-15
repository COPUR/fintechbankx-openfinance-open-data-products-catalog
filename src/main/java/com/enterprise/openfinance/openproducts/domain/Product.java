package com.enterprise.openfinance.openproducts.domain;

import java.time.OffsetDateTime;

public record Product(
        String productId,
        String name,
        String type,
        String segment,
        String currency,
        String monthlyFee,
        String annualRate,
        OffsetDateTime updatedAt
) {
}
