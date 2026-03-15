package com.enterprise.openfinance.openproducts.application;

import com.enterprise.openfinance.openproducts.application.port.in.ListProductsUseCase;
import com.enterprise.openfinance.openproducts.application.port.out.ProductCatalogReadPort;
import com.enterprise.openfinance.openproducts.domain.Product;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Locale;
import java.util.Objects;

@Service
public class ListProductsService implements ListProductsUseCase {

    private final ProductCatalogReadPort readPort;

    public ListProductsService(ProductCatalogReadPort readPort) {
        this.readPort = readPort;
    }

    @Override
    public List<Product> list(String type, String segment) {
        String normalizedType = normalize(type);
        String normalizedSegment = normalize(segment);
        return readPort.findAll().stream()
                .filter(product -> normalizedType.isBlank() || normalizedType.equals(normalize(product.type())))
                .filter(product -> normalizedSegment.isBlank() || normalizedSegment.equals(normalize(product.segment())))
                .filter(Objects::nonNull)
                .toList();
    }

    private String normalize(String value) {
        if (value == null) {
            return "";
        }
        return value.trim().toUpperCase(Locale.ROOT);
    }
}
