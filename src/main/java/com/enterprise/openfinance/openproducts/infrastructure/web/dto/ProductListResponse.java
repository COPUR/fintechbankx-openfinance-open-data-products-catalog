package com.enterprise.openfinance.openproducts.infrastructure.web.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

public record ProductListResponse(
    @JsonProperty("Data") DataBlock data,
    @JsonProperty("Links") LinksBlock links,
    @JsonProperty("Meta") MetaBlock meta
) {

    public record DataBlock(@JsonProperty("Product") List<ProductItem> products) {}

    public record ProductItem(
        @JsonProperty("ProductId") String productId,
        @JsonProperty("Name") String name,
        @JsonProperty("Type") String type,
        @JsonProperty("Segment") String segment,
        @JsonProperty("Currency") String currency,
        @JsonProperty("MonthlyFee") String monthlyFee,
        @JsonProperty("AnnualRate") String annualRate,
        @JsonProperty("UpdatedAt") String updatedAt
    ) {}

    public record LinksBlock(@JsonProperty("Self") String self) {}

    public record MetaBlock(@JsonProperty("TotalRecords") int totalRecords) {}
}
