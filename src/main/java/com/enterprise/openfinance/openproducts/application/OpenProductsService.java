package com.enterprise.openfinance.openproducts.application;

import com.enterprise.openfinance.openproducts.domain.model.ProductListResult;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.in.OpenProductsUseCase;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class OpenProductsService implements OpenProductsUseCase {
    private final ProductCatalogPort productCatalogPort;

    public OpenProductsService(ProductCatalogPort productCatalogPort) {
        this.productCatalogPort = productCatalogPort;
    }

    @Override
    public ProductListResult listProducts(ListProductsQuery query) {
        List<ProductOffer> filtered = productCatalogPort.findAll()
            .stream()
            .filter(p -> query.type() == null || p.type().equalsIgnoreCase(query.type()))
            .filter(p -> query.segment() == null || p.segment().equalsIgnoreCase(query.segment()))
            .toList();
        return new ProductListResult(filtered);
    }
}
