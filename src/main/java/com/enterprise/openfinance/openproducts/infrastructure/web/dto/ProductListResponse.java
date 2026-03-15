package com.enterprise.openfinance.openproducts.infrastructure.web.dto;

import java.util.List;

public record ProductListResponse(Data Data, Links Links, Meta Meta) {
    public record Data(List<ProductItem> Product) {
    }

    public record Links(String Self) {
    }

    public record Meta(int TotalRecords) {
    }

    public record ProductItem(
            String ProductId,
            String Name,
            String Type,
            String Segment,
            String Currency,
            String MonthlyFee,
            String AnnualRate,
            String UpdatedAt
    ) {
    }
}
