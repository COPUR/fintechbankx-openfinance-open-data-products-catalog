package com.enterprise.openfinance.openproducts.domain.port.out;

import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import java.util.List;

public interface ProductCatalogPort {
    List<ProductOffer> findAll();
}
