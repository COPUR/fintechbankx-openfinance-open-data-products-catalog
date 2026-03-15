package com.enterprise.openfinance.openproducts.infrastructure.web;

import com.enterprise.openfinance.openproducts.application.port.in.ListProductsUseCase;
import com.enterprise.openfinance.openproducts.domain.Product;
import com.enterprise.openfinance.openproducts.infrastructure.etag.ProductEtagService;
import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ProductListResponse;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/open-finance/v1")
public class OpenProductsController {

    private final ListProductsUseCase listProductsUseCase;
    private final ProductEtagService productEtagService;

    public OpenProductsController(ListProductsUseCase listProductsUseCase, ProductEtagService productEtagService) {
        this.listProductsUseCase = listProductsUseCase;
        this.productEtagService = productEtagService;
    }

    @GetMapping("/products")
    ResponseEntity<ProductListResponse> listProducts(
            @RequestHeader("X-FAPI-Interaction-ID") String interactionId,
            @RequestParam(required = false) String type,
            @RequestParam(required = false) String segment,
            @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch) {
        List<Product> products = listProductsUseCase.list(type, segment);
        String etag = productEtagService.compute(products, type, segment);
        if (etag.equals(ifNoneMatch)) {
            return ResponseEntity.status(304)
                    .eTag(etag)
                    .header("X-FAPI-Interaction-ID", interactionId)
                    .header("X-OF-Cache", "HIT")
                    .build();
        }

        List<ProductListResponse.ProductItem> items = products.stream()
                .map(product -> new ProductListResponse.ProductItem(
                        product.productId(),
                        product.name(),
                        product.type(),
                        product.segment(),
                        product.currency(),
                        product.monthlyFee(),
                        product.annualRate(),
                        product.updatedAt() == null ? null : product.updatedAt().toString()))
                .toList();

        ProductListResponse body = new ProductListResponse(
                new ProductListResponse.Data(items),
                new ProductListResponse.Links("/open-finance/v1/products"),
                new ProductListResponse.Meta(items.size())
        );

        return ResponseEntity.ok()
                .eTag(etag)
                .header("X-FAPI-Interaction-ID", interactionId)
                .header("X-OF-Cache", "MISS")
                .body(body);
    }
}
