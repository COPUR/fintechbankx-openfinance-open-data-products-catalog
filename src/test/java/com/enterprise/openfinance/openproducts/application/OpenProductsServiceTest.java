package com.enterprise.openfinance.openproducts.application;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.when;

import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class OpenProductsServiceTest {

    @Mock
    private ProductCatalogPort productCatalogPort;

    private OpenProductsService service;

    @BeforeEach
    void setUp() {
        service = new OpenProductsService(productCatalogPort);
    }

    @Test
    void shouldFilterProductsByTypeAndSegment() {
        when(productCatalogPort.findAll()).thenReturn(List.of(
            new ProductOffer("1", "Retail PCA", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z")),
            new ProductOffer("2", "SME PCA", "PCA", "SME", "AED", "10.00", "0.00", Instant.parse("2026-03-01T00:00:00Z")),
            new ProductOffer("3", "SME Loan", "LOAN", "SME", "AED", "0.00", "5.50", Instant.parse("2026-03-01T00:00:00Z"))
        ));

        var result = service.listProducts(new ListProductsQuery("PCA", "SME"));

        assertEquals(1, result.products().size());
        assertEquals("2", result.products().getFirst().productId());
    }

    @Test
    void shouldReturnAllWhenNoFilterProvided() {
        when(productCatalogPort.findAll()).thenReturn(List.of(
            new ProductOffer("1", "Retail PCA", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z")),
            new ProductOffer("2", "SME Loan", "LOAN", "SME", "AED", "0.00", "5.50", Instant.parse("2026-03-01T00:00:00Z"))
        ));

        var result = service.listProducts(new ListProductsQuery(null, null));

        assertEquals(2, result.products().size());
    }
}
