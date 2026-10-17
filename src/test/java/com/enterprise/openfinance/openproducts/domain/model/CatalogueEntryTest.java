package com.enterprise.openfinance.openproducts.domain.model;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class CatalogueEntryTest {

    private static final Instant MARCH_1 = Instant.parse("2026-03-01T00:00:00Z");
    private static final Instant JUNE_1 = Instant.parse("2026-06-01T00:00:00Z");

    private static final ProductOffer SME_CURRENT = new ProductOffer(
        "SME-PCA-01", "SME Current", "PCA", "SME", "AED", "35.00", "0.00", MARCH_1);

    @Test
    void activeProductIsOfferedFromItsEffectiveStartInclusive() {
        CatalogueEntry entry = new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, MARCH_1, JUNE_1);

        assertThat(entry.isOfferedAt(MARCH_1)).isTrue();
        assertThat(entry.isOfferedAt(Instant.parse("2026-05-31T23:59:59Z"))).isTrue();
    }

    @Test
    void activeProductIsNotOfferedBeforeStartOrFromItsEffectiveEnd() {
        CatalogueEntry entry = new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, MARCH_1, JUNE_1);

        assertThat(entry.isOfferedAt(Instant.parse("2026-02-28T23:59:59Z"))).isFalse();
        assertThat(entry.isOfferedAt(JUNE_1)).isFalse();
    }

    @Test
    void openEndedActiveProductStaysOffered() {
        CatalogueEntry entry = new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, MARCH_1, null);

        assertThat(entry.isOfferedAt(Instant.parse("2036-03-01T00:00:00Z"))).isTrue();
    }

    @Test
    void draftAndWithdrawnProductsAreNeverOffered() {
        assertThat(new CatalogueEntry(SME_CURRENT, ProductStatus.DRAFT, MARCH_1, null).isOfferedAt(JUNE_1)).isFalse();
        assertThat(new CatalogueEntry(SME_CURRENT, ProductStatus.WITHDRAWN, MARCH_1, null).isOfferedAt(JUNE_1)).isFalse();
    }

    @Test
    void effectiveEndMustBeAfterEffectiveStart() {
        assertThatThrownBy(() -> new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, JUNE_1, JUNE_1))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("effectiveTo");
        assertThatThrownBy(() -> new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, JUNE_1, MARCH_1))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("effectiveTo");
    }

    @Test
    void offerStatusAndEffectiveStartAreRequired() {
        assertThatThrownBy(() -> new CatalogueEntry(null, ProductStatus.ACTIVE, MARCH_1, null))
            .isInstanceOf(NullPointerException.class).hasMessageContaining("offer");
        assertThatThrownBy(() -> new CatalogueEntry(SME_CURRENT, null, MARCH_1, null))
            .isInstanceOf(NullPointerException.class).hasMessageContaining("status");
        assertThatThrownBy(() -> new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, null, null))
            .isInstanceOf(NullPointerException.class).hasMessageContaining("effectiveFrom");
    }

    @Test
    void matchesTypeAndSegmentIgnoringCase() {
        CatalogueEntry entry = new CatalogueEntry(SME_CURRENT, ProductStatus.ACTIVE, MARCH_1, null);

        assertThat(entry.matches(new ListProductsQuery(null, null))).isTrue();
        assertThat(entry.matches(new ListProductsQuery("pca", "sme"))).isTrue();
        assertThat(entry.matches(new ListProductsQuery("PCA", null))).isTrue();
        assertThat(entry.matches(new ListProductsQuery(null, "RETAIL"))).isFalse();
        assertThat(entry.matches(new ListProductsQuery("LOAN", "SME"))).isFalse();
    }
}
