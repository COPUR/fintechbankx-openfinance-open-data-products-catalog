package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Objects;

/**
 * Keeps the whole offerable catalogue in memory and reloads it at most once
 * per refresh interval, whatever the filters or request rate. The catalogue is
 * small, and ProductCatalogPort allows returning a superset: the application
 * re-applies the offer window and the filters to every request, so ETag
 * revalidation (304) costs no database round trip.
 *
 * A product whose effective_from falls inside the interval appears up to one
 * interval late; an import becomes visible within one interval. A zero
 * interval disables the snapshot (every call reaches the delegate).
 */
public final class SnapshotProductCatalog implements ProductCatalogPort {

    private static final ListProductsQuery EVERYTHING = new ListProductsQuery(null, null);

    private record Snapshot(List<CatalogueEntry> entries, Instant loadedAt) {
    }

    private final ProductCatalogPort delegate;
    private final Duration refreshInterval;
    private volatile Snapshot snapshot;

    public SnapshotProductCatalog(ProductCatalogPort delegate, Duration refreshInterval) {
        this.delegate = Objects.requireNonNull(delegate, "delegate must not be null");
        this.refreshInterval = Objects.requireNonNull(refreshInterval, "refreshInterval must not be null");
        if (refreshInterval.isNegative()) {
            throw new IllegalArgumentException("refreshInterval must not be negative");
        }
    }

    @Override
    public List<CatalogueEntry> findOfferable(ListProductsQuery query, Instant asOf) {
        if (refreshInterval.isZero()) {
            return delegate.findOfferable(query, asOf);
        }
        Snapshot current = snapshot;
        return isFresh(current, asOf) ? current.entries() : reload(asOf).entries();
    }

    ProductCatalogPort delegate() {
        return delegate;
    }

    private boolean isFresh(Snapshot current, Instant asOf) {
        return current != null && asOf.isBefore(current.loadedAt().plus(refreshInterval));
    }

    // One reload at a time: concurrent requests on a stale snapshot wait for it
    // instead of each querying the database.
    private synchronized Snapshot reload(Instant asOf) {
        Snapshot current = snapshot;
        if (isFresh(current, asOf)) {
            return current;
        }
        Snapshot fresh = new Snapshot(List.copyOf(delegate.findOfferable(EVERYTHING, asOf)), asOf);
        snapshot = fresh;
        return fresh;
    }
}
