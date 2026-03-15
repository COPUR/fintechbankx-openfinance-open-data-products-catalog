package com.enterprise.openfinance.openproducts.domain.model;

import java.time.Instant;
import java.util.Objects;

public record ProductOffer(
    String productId,
    String name,
    String type,
    String segment,
    String currency,
    String monthlyFee,
    String annualRate,
    Instant updatedAt
) {
    public ProductOffer {
        requireNonBlank(productId, "productId");
        requireNonBlank(name, "name");
        requireNonBlank(type, "type");
        requireNonBlank(segment, "segment");
        requireNonBlank(currency, "currency");
        requireMoney(monthlyFee, "monthlyFee");
        requireMoney(annualRate, "annualRate");
        Objects.requireNonNull(updatedAt, "updatedAt must not be null");
    }

    private static void requireNonBlank(String value, String field) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(field + " must not be blank");
        }
    }

    private static void requireMoney(String value, String field) {
        requireNonBlank(value, field);
        if (!value.matches("^\\d+(\\.\\d{1,2})?$") ) {
            throw new IllegalArgumentException(field + " must be a non-negative decimal with up to 2 decimals");
        }
    }
}
