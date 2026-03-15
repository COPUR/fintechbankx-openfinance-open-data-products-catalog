package com.enterprise.openfinance.openproducts.application.port.in;

import com.enterprise.openfinance.openproducts.domain.Product;

import java.util.List;

public interface ListProductsUseCase {
    List<Product> list(String type, String segment);
}
