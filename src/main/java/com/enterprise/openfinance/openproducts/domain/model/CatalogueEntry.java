package com.enterprise.openfinance.openproducts.domain.model;

import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Instant;
import java.util.Objects;

/**
 * A product as held in the catalogue: the published offer plus the lifecycle
 * facts that decide whether it may be offered at a given instant.
 *
 * @param effectiveFrom first instant the product may be offered (inclusive)
 * @param effectiveTo   instant the offer ends (exclusive), or null when open-ended
 */
public record CatalogueEntry(
    ProductOffer offer,
    ProductStatus status,
    Instant effectiveFrom,
    Instant effectiveTo
) {
    public CatalogueEntry {
        Objects.requireNonNull(offer, "offer must not be null");
        Objects.requireNonNull(status, "status must not be null");
        Objects.requireNonNull(effectiveFrom, "effectiveFrom must not be null");
        if (effectiveTo != null && !effectiveTo.isAfter(effectiveFrom)) {
            throw new IllegalArgumentException("effectiveTo must be after effectiveFrom");
        }
    }

    /** A product is offered when it is ACTIVE and {@code instant} lies in [effectiveFrom, effectiveTo). */
    public boolean isOfferedAt(Instant instant) {
        return status == ProductStatus.ACTIVE
            && !instant.isBefore(effectiveFrom)
            && (effectiveTo == null || instant.isBefore(effectiveTo));
    }

    /** Type and segment filters compare case-insensitively; an absent filter matches everything. */
    public boolean matches(ListProductsQuery query) {
        return (query.type() == null || offer.type().equalsIgnoreCase(query.type()))
            && (query.segment() == null || offer.segment().equalsIgnoreCase(query.segment()));
    }
}
