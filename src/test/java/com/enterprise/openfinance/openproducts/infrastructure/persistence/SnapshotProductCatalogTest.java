package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.model.ProductStatus;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class SnapshotProductCatalogTest {

    private static final Instant T0 = Instant.parse("2026-04-15T10:00:00Z");

    /** Records every storage read so the test can count database round trips. */
    private static final class RecordingCatalog implements ProductCatalogPort {
        final List<ListProductsQuery> queries = new ArrayList<>();
        List<CatalogueEntry> rows = List.of(entry("SME-PCA-01"));

        @Override
        public List<CatalogueEntry> findOfferable(ListProductsQuery query, Instant asOf) {
            queries.add(query);
            return rows;
        }
    }

    private static CatalogueEntry entry(String id) {
        return new CatalogueEntry(new ProductOffer(id, "Product " + id, "PCA", "SME", "AED", "35.00", "0.00", T0),
            ProductStatus.ACTIVE, T0.minusSeconds(3600), null);
    }

    @Test
    void servesEveryFilterFromOneSnapshotUntilTheIntervalHasPassed() {
        RecordingCatalog storage = new RecordingCatalog();
        SnapshotProductCatalog catalog = new SnapshotProductCatalog(storage, Duration.ofSeconds(10));

        catalog.findOfferable(new ListProductsQuery("PCA", "SME"), T0);
        catalog.findOfferable(new ListProductsQuery("LOAN", null), T0.plusSeconds(5));
        catalog.findOfferable(new ListProductsQuery(null, "RETAIL"), T0.plusMillis(9_999));

        assertThat(storage.queries).hasSize(1);
        assertThat(storage.queries.get(0)).isEqualTo(new ListProductsQuery(null, null));
    }

    @Test
    void reloadsOnceTheIntervalHasPassed() {
        RecordingCatalog storage = new RecordingCatalog();
        SnapshotProductCatalog catalog = new SnapshotProductCatalog(storage, Duration.ofSeconds(10));

        assertThat(catalog.findOfferable(new ListProductsQuery(null, null), T0))
            .extracting(e -> e.offer().productId()).containsExactly("SME-PCA-01");
        storage.rows = List.of(entry("SME-PCA-01"), entry("SME-PCA-02"));

        assertThat(catalog.findOfferable(new ListProductsQuery(null, null), T0.plusSeconds(10)))
            .extracting(e -> e.offer().productId()).containsExactly("SME-PCA-01", "SME-PCA-02");
        assertThat(storage.queries).hasSize(2);
    }

    @Test
    void zeroIntervalPassesEveryQueryThroughUnchanged() {
        RecordingCatalog storage = new RecordingCatalog();
        SnapshotProductCatalog catalog = new SnapshotProductCatalog(storage, Duration.ZERO);

        catalog.findOfferable(new ListProductsQuery("PCA", "SME"), T0);
        catalog.findOfferable(new ListProductsQuery("PCA", "SME"), T0);

        assertThat(storage.queries).containsExactly(new ListProductsQuery("PCA", "SME"), new ListProductsQuery("PCA", "SME"));
        assertThat(catalog.delegate()).isSameAs(storage);
    }

    @Test
    void rejectsANegativeInterval() {
        assertThatThrownBy(() -> new SnapshotProductCatalog(new RecordingCatalog(), Duration.ofSeconds(-1)))
            .isInstanceOf(IllegalArgumentException.class);
    }
}
