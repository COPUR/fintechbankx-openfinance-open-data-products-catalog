package com.enterprise.openfinance.openproducts.infrastructure.web;

import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.in.OpenProductsUseCase;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ProductListResponse;
import jakarta.servlet.http.HttpServletRequest;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OpenProductsController {

    private final OpenProductsUseCase openProductsUseCase;

    public OpenProductsController(OpenProductsUseCase openProductsUseCase) {
        this.openProductsUseCase = openProductsUseCase;
    }

    @GetMapping("/open-finance/v1/products")
    public ResponseEntity<ProductListResponse> listProducts(
        @RequestHeader("X-FAPI-Interaction-ID") String interactionId,
        @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch,
        @RequestParam(value = "type", required = false) String type,
        @RequestParam(value = "segment", required = false) String segment,
        HttpServletRequest request
    ) {
        List<ProductOffer> products = openProductsUseCase.listProducts(new ListProductsQuery(type, segment)).products();
        String eTag = toEtag(products);

        if (ifNoneMatch != null && ifNoneMatch.equals(eTag)) {
            return ResponseEntity.status(HttpStatus.NOT_MODIFIED)
                .header("X-FAPI-Interaction-ID", interactionId)
                .header("X-OF-Cache", "HIT")
                .header(HttpHeaders.ETAG, eTag)
                .build();
        }

        ProductListResponse response = new ProductListResponse(
            new ProductListResponse.DataBlock(products.stream().map(this::toItem).toList()),
            new ProductListResponse.LinksBlock(buildSelfLink(request)),
            new ProductListResponse.MetaBlock(products.size())
        );

        return ResponseEntity.ok()
            .header("X-FAPI-Interaction-ID", interactionId)
            .header("X-OF-Cache", "MISS")
            .header(HttpHeaders.ETAG, eTag)
            .body(response);
    }

    private ProductListResponse.ProductItem toItem(ProductOffer p) {
        return new ProductListResponse.ProductItem(
            p.productId(),
            p.name(),
            p.type(),
            p.segment(),
            p.currency(),
            p.monthlyFee(),
            p.annualRate(),
            p.updatedAt().toString()
        );
    }

    private String buildSelfLink(HttpServletRequest request) {
        String base = request.getRequestURL().toString();
        String query = request.getQueryString();
        return query == null ? base : base + "?" + query;
    }

    static String toEtag(List<ProductOffer> products) {
        String canonical = products.stream()
            .map(p -> String.join("|",
                p.productId(),
                p.name(),
                p.type(),
                p.segment(),
                p.currency(),
                p.monthlyFee(),
                p.annualRate(),
                p.updatedAt().toString()))
            .sorted()
            .reduce("", (a, b) -> a + ";" + b);

        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(canonical.getBytes(StandardCharsets.UTF_8));
            return "\"" + HexFormat.of().formatHex(hash) + "\"";
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException("SHA-256 not available", ex);
        }
    }
}
