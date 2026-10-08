package com.enterprise.openfinance.openproducts.application;

import com.enterprise.openfinance.openproducts.domain.model.CatalogueEntry;
import com.enterprise.openfinance.openproducts.domain.model.ProductListResult;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.in.OpenProductsUseCase;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Clock;
import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class OpenProductsService implements OpenProductsUseCase {
    private final ProductCatalogPort productCatalogPort;
    private final Clock clock;

    public OpenProductsService(ProductCatalogPort productCatalogPort, Clock clock) {
        this.productCatalogPort = productCatalogPort;
        this.clock = clock;
    }

    @Override
    public ProductListResult listProducts(ListProductsQuery query) {
        Instant now = clock.instant();
        List<ProductOffer> offered = productCatalogPort.findOfferable(query, now)
            .stream()
            .filter(entry -> entry.isOfferedAt(now))
            .filter(entry -> entry.matches(query))
            .map(CatalogueEntry::offer)
            .sorted(Comparator.comparing(ProductOffer::productId))
            .toList();
        return new ProductListResult(offered);
    }
}
