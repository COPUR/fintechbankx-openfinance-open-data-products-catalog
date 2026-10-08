package com.enterprise.openfinance.openproducts.domain.query;

import com.enterprise.openfinance.openproducts.domain.exception.InvalidProductFilterException;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Optional type and segment filters, trimmed and upper-cased; blank means no
 * filter. A filter must be a product code: 2 to 30 ASCII letters, digits,
 * underscores or hyphens, so it matches {@value #CODE_PATTERN} once upper-cased
 * (the same rule the product table enforces on stored codes).
 */
public record ListProductsQuery(String type, String segment) {

    public static final String CODE_PATTERN = "^[A-Z0-9_-]{2,30}$";
    // Checked before upper-casing so that non-ASCII letters with ASCII upper
    // cases (dotless i, long s) are rejected too.
    private static final Pattern CODE = Pattern.compile("^[A-Za-z0-9_-]{2,30}$");

    public ListProductsQuery {
        type = normalize(type, "type");
        segment = normalize(segment, "segment");
    }

    private static String normalize(String value, String field) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if (trimmed.isEmpty()) {
            return null;
        }
        if (!CODE.matcher(trimmed).matches()) {
            throw new InvalidProductFilterException(field + " must match " + CODE_PATTERN);
        }
        return trimmed.toUpperCase(Locale.ROOT);
    }
}
