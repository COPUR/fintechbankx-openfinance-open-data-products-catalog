package com.enterprise.openfinance.openproducts.application;

import com.enterprise.openfinance.openproducts.application.port.out.ProductCatalogReadPort;
import com.enterprise.openfinance.openproducts.domain.Product;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.time.OffsetDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class ListProductsServiceTest {

    @Test
    void shouldFilterByTypeAndSegmentWhenProvided() {
        ProductCatalogReadPort port = Mockito.mock(ProductCatalogReadPort.class);
        Mockito.when(port.findAll()).thenReturn(List.of(
                new Product("P1", "Current Plus", "PCA", "RETAIL", "AED", "0.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z")),
                new Product("P2", "SME Growth", "LOAN", "SME", "AED", "20.00", "5.10", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        ));

        ListProductsService service = new ListProductsService(port);
        List<Product> products = service.list("LOAN", "SME");

        assertThat(products).hasSize(1);
        assertThat(products.getFirst().productId()).isEqualTo("P2");
    }

    @Test
    void shouldReturnAllWhenNoFiltersProvided() {
        ProductCatalogReadPort port = Mockito.mock(ProductCatalogReadPort.class);
        Mockito.when(port.findAll()).thenReturn(List.of(
                new Product("P1", "Current Plus", "PCA", "RETAIL", "AED", "0.00", "0.00", OffsetDateTime.parse("2026-03-01T00:00:00Z")),
                new Product("P2", "SME Growth", "LOAN", "SME", "AED", "20.00", "5.10", OffsetDateTime.parse("2026-03-01T00:00:00Z"))
        ));

        ListProductsService service = new ListProductsService(port);
        List<Product> products = service.list(null, null);

        assertThat(products).hasSize(2);
    }
}
