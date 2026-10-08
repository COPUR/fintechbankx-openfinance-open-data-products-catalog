package com.enterprise.openfinance.openproducts.infrastructure.persistence.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import java.math.BigDecimal;
import java.time.Instant;
import org.hibernate.annotations.Immutable;

/**
 * Row of sc_of_open_products_catalog.product. The service only reads the
 * catalogue (it is loaded by db/import/import-products.sh), so the entity is
 * immutable. Description and eligibility columns exist in the table for the
 * import but are not part of the published offer yet, so they are not mapped.
 */
@Entity
@Immutable
@Table(name = "product")
public class ProductEntity {

    @Id
    @Column(name = "product_id", length = 64)
    private String productId;

    @Column(name = "product_type", nullable = false, length = 30)
    private String productType;

    @Column(name = "segment", nullable = false, length = 30)
    private String segment;

    @Column(name = "name", nullable = false, length = 200)
    private String name;

    @Column(name = "currency", nullable = false, length = 3)
    private String currency;

    @Column(name = "monthly_fee_amount", nullable = false, precision = 19, scale = 2)
    private BigDecimal monthlyFeeAmount;

    @Column(name = "monthly_fee_currency", nullable = false, length = 3)
    private String monthlyFeeCurrency;

    @Column(name = "annual_rate_percent", nullable = false, precision = 7, scale = 2)
    private BigDecimal annualRatePercent;

    @Column(name = "status", nullable = false, length = 16)
    private String status;

    @Column(name = "effective_from", nullable = false)
    private Instant effectiveFrom;

    @Column(name = "effective_to")
    private Instant effectiveTo;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Version
    @Column(name = "version", nullable = false)
    private long version;

    protected ProductEntity() {
    }

    public ProductEntity(String productId, String productType, String segment, String name, String currency,
                         BigDecimal monthlyFeeAmount, String monthlyFeeCurrency, BigDecimal annualRatePercent,
                         String status, Instant effectiveFrom, Instant effectiveTo, Instant updatedAt, long version) {
        this.productId = productId;
        this.productType = productType;
        this.segment = segment;
        this.name = name;
        this.currency = currency;
        this.monthlyFeeAmount = monthlyFeeAmount;
        this.monthlyFeeCurrency = monthlyFeeCurrency;
        this.annualRatePercent = annualRatePercent;
        this.status = status;
        this.effectiveFrom = effectiveFrom;
        this.effectiveTo = effectiveTo;
        this.updatedAt = updatedAt;
        this.version = version;
    }

    public String getProductId() { return productId; }
    public String getProductType() { return productType; }
    public String getSegment() { return segment; }
    public String getName() { return name; }
    public String getCurrency() { return currency; }
    public BigDecimal getMonthlyFeeAmount() { return monthlyFeeAmount; }
    public String getMonthlyFeeCurrency() { return monthlyFeeCurrency; }
    public BigDecimal getAnnualRatePercent() { return annualRatePercent; }
    public String getStatus() { return status; }
    public Instant getEffectiveFrom() { return effectiveFrom; }
    public Instant getEffectiveTo() { return effectiveTo; }
    public Instant getUpdatedAt() { return updatedAt; }
    public long getVersion() { return version; }
}
