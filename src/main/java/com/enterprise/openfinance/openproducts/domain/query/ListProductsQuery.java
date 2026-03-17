package com.enterprise.openfinance.openproducts.domain.query;

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
        return trimmed.isEmpty() ? null : trimmed;
    }
}
