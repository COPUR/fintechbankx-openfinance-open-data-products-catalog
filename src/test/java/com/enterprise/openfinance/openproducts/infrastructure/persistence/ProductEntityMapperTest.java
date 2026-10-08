package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductStatus;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.entity.ProductEntity;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.mapper.ProductEntityMapper;
import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class ProductEntityMapperTest {

    private static final Instant FROM = Instant.parse("2026-03-04T00:00:00Z");
    private static final Instant TO = Instant.parse("2027-03-04T00:00:00Z");

    private static ProductEntity row(BigDecimal fee, String feeCurrency, BigDecimal rate) {
        return new ProductEntity("SME-PCA-01", "PCA", "SME", "SME Current", "AED",
            fee, feeCurrency, rate, "ACTIVE", FROM, TO, FROM, 3);
    }

    @Test
    void mapsRowToCatalogueEntryWithTwoDecimalAmounts() {
        CatalogueEntry entry = ProductEntityMapper.toDomain(row(new BigDecimal("35"), "AED", new BigDecimal("6.7")));

        assertThat(entry.offer().productId()).isEqualTo("SME-PCA-01");
        assertThat(entry.offer().type()).isEqualTo("PCA");
        assertThat(entry.offer().segment()).isEqualTo("SME");
        assertThat(entry.offer().currency()).isEqualTo("AED");
        assertThat(entry.offer().monthlyFee()).isEqualTo("35.00");
        assertThat(entry.offer().annualRate()).isEqualTo("6.70");
        assertThat(entry.offer().updatedAt()).isEqualTo(FROM);
        assertThat(entry.status()).isEqualTo(ProductStatus.ACTIVE);
        assertThat(entry.effectiveFrom()).isEqualTo(FROM);
        assertThat(entry.effectiveTo()).isEqualTo(TO);
    }

    @Test
    void rejectsFeeInAnotherCurrency() {
        assertThatThrownBy(() -> ProductEntityMapper.toDomain(row(new BigDecimal("35.00"), "USD", BigDecimal.ZERO)))
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("SME-PCA-01");
    }

    @Test
    void refusesToRoundAmountsSilently() {
        assertThatThrownBy(() -> ProductEntityMapper.toDomain(row(new BigDecimal("35.005"), "AED", BigDecimal.ZERO)))
            .isInstanceOf(ArithmeticException.class);
    }

    @Test
    void exposesRowValuesForDiagnostics() {
        ProductEntity entity = row(BigDecimal.ONE, "AED", BigDecimal.ONE);

        assertThat(entity.getVersion()).isEqualTo(3);
    }
}
