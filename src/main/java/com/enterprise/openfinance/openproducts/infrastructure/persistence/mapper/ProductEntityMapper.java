package com.enterprise.openfinance.openproducts.infrastructure.persistence.mapper;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.model.ProductStatus;
import com.enterprise.openfinance.openproducts.infrastructure.persistence.entity.ProductEntity;
import java.math.BigDecimal;
import java.math.RoundingMode;

/** Maps catalogue rows to the domain; amounts are rendered with exactly two decimals. */
public final class ProductEntityMapper {

    private ProductEntityMapper() {
    }

    public static CatalogueEntry toDomain(ProductEntity row) {
        if (!row.getCurrency().equals(row.getMonthlyFeeCurrency())) {
            throw new IllegalStateException("product " + row.getProductId()
                + " has a monthly fee in a currency other than the product currency");
        }
        ProductOffer offer = new ProductOffer(
            row.getProductId(),
            row.getName(),
            row.getProductType(),
            row.getSegment(),
            row.getCurrency(),
            twoDecimals(row.getMonthlyFeeAmount()),
            twoDecimals(row.getAnnualRatePercent()),
            row.getUpdatedAt()
        );
        return new CatalogueEntry(offer, ProductStatus.valueOf(row.getStatus()),
            row.getEffectiveFrom(), row.getEffectiveTo());
    }

    // The column scale is 2; UNNECESSARY makes a wider value fail loudly instead of rounding money.
    static String twoDecimals(BigDecimal value) {
        return value.setScale(2, RoundingMode.UNNECESSARY).toPlainString();
    }
}
