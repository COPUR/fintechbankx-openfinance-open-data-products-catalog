package com.enterprise.openfinance.openproducts.domain.port.in;

import com.enterprise.openfinance.openproducts.domain.model.ProductListResult;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;

public interface OpenProductsUseCase {
    ProductListResult listProducts(ListProductsQuery query);
}
