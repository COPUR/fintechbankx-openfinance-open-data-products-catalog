package com.enterprise.openfinance.openproducts.domain.model;

import java.util.List;

public record ProductListResult(List<ProductOffer> products) {
    public ProductListResult {
        products = List.copyOf(products);
    }
}
