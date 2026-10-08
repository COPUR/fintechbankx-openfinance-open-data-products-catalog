package com.enterprise.openfinance.openproducts.domain.query;

import java.util.Locale;

/** Optional type and segment filters, trimmed and upper-cased; blank means no filter. */
public record ListProductsQuery(String type, String segment) {
    public ListProductsQuery {
        type = normalize(type);
        segment = normalize(segment);
    }

    private static String normalize(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed.toUpperCase(Locale.ROOT);
    }
}
