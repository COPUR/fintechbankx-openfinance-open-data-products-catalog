package com.enterprise.openfinance.openproducts.application.port.out;

import com.enterprise.openfinance.openproducts.domain.Product;

import java.util.List;

public interface ProductCatalogReadPort {
    List<Product> findAll();
}
