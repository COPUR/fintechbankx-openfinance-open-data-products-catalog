package com.enterprise.openfinance.openproducts.application;

import static org.assertj.core.api.Assertions.assertThat;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.model.ProductStatus;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.InMemoryProductCatalogAdapter;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import org.junit.jupiter.api.Test;

class OpenProductsServiceTest {

    private static final Instant NOW = Instant.parse("2026-04-15T10:00:00Z");
    private static final Clock CLOCK = Clock.fixed(NOW, ZoneOffset.UTC);

    private static CatalogueEntry entry(String id, String type, String segment, ProductStatus status,
                                        String from, String to) {
        return new CatalogueEntry(
            new ProductOffer(id, "Product " + id, type, segment, "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z")),
            status, Instant.parse(from), to == null ? null : Instant.parse(to));
    }

    private final List<CatalogueEntry> catalogue = List.of(
        entry("3-SME-LOAN", "LOAN", "SME", ProductStatus.ACTIVE, "2026-03-01T00:00:00Z", null),
        entry("2-SME-PCA", "PCA", "SME", ProductStatus.ACTIVE, "2026-03-01T00:00:00Z", null),
        entry("1-RETAIL-PCA", "PCA", "RETAIL", ProductStatus.ACTIVE, "2026-03-01T00:00:00Z", "2026-12-31T00:00:00Z"),
        entry("4-SME-PCA-DRAFT", "PCA", "SME", ProductStatus.DRAFT, "2026-03-01T00:00:00Z", null),
        entry("5-SME-PCA-WITHDRAWN", "PCA", "SME", ProductStatus.WITHDRAWN, "2026-03-01T00:00:00Z", null),
        entry("6-SME-PCA-FROM-MAY", "PCA", "SME", ProductStatus.ACTIVE, "2026-05-01T00:00:00Z", null),
        entry("7-SME-PCA-ENDED", "PCA", "SME", ProductStatus.ACTIVE, "2026-03-01T00:00:00Z", "2026-04-15T10:00:00Z")
    );

    private final OpenProductsService service =
        new OpenProductsService(new InMemoryProductCatalogAdapter(catalogue), CLOCK);

    @Test
    void filtersByTypeAndSegmentIgnoringCase() {
        var result = service.listProducts(new ListProductsQuery("pca", "Sme"));

        assertThat(result.products()).extracting(ProductOffer::productId).containsExactly("2-SME-PCA");
    }

    @Test
    void returnsOnlyProductsOfferedNowOrderedByProductId() {
        var result = service.listProducts(new ListProductsQuery(null, null));

        assertThat(result.products()).extracting(ProductOffer::productId)
            .containsExactly("1-RETAIL-PCA", "2-SME-PCA", "3-SME-LOAN");
    }

    @Test
    void returnsEmptyListForUnknownType() {
        assertThat(service.listProducts(new ListProductsQuery("MORTGAGE", null)).products()).isEmpty();
    }
}
