package com.enterprise.openfinance.openproducts.infrastructure.web;

import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.in.OpenProductsUseCase;
import com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery;
import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ProductListResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.UriUtils;

@RestController
public class OpenProductsController {

    static final String PRODUCTS_PATH = "/open-finance/v1/products";

    /**
     * Every response echoes the caller's X-FAPI-Interaction-ID, so no cache may
     * reuse it without asking: no-cache forces revalidation with If-None-Match,
     * which the ETag makes cheap (304 without a body).
     */
    static final CacheControl CACHE_CONTROL = CacheControl.noCache();

    private final OpenProductsUseCase openProductsUseCase;

    public OpenProductsController(OpenProductsUseCase openProductsUseCase) {
        this.openProductsUseCase = openProductsUseCase;
    }

    @GetMapping(PRODUCTS_PATH)
    public ResponseEntity<ProductListResponse> listProducts(
        @RequestHeader("X-FAPI-Interaction-ID") String interactionId,
        @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch,
        @RequestParam(value = "type", required = false) String type,
        @RequestParam(value = "segment", required = false) String segment
    ) {
        List<ProductOffer> products = openProductsUseCase.listProducts(new ListProductsQuery(type, segment)).products();
        String eTag = toEtag(products);

        if (ifNoneMatch != null && ifNoneMatch.equals(eTag)) {
            return ResponseEntity.status(HttpStatus.NOT_MODIFIED)
                .header("X-FAPI-Interaction-ID", interactionId)
                .header("X-OF-Cache", "HIT")
                .header(HttpHeaders.ETAG, eTag)
                .cacheControl(CACHE_CONTROL)
                .build();
        }

        ProductListResponse response = new ProductListResponse(
            new ProductListResponse.DataBlock(products.stream().map(this::toItem).toList()),
            new ProductListResponse.LinksBlock(selfLink(type, segment)),
            new ProductListResponse.MetaBlock(products.size())
        );

        return ResponseEntity.ok()
            .header("X-FAPI-Interaction-ID", interactionId)
            .header("X-OF-Cache", "MISS")
            .header(HttpHeaders.ETAG, eTag)
            .cacheControl(CACHE_CONTROL)
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

    /**
     * A relative link built from the filters only, as in the monolith. Host,
     * scheme, port and prefix are never taken from the request, so forwarded
     * headers cannot change the body.
     */
    static String selfLink(String type, String segment) {
        StringBuilder query = new StringBuilder();
        appendFilter(query, "type", type);
        appendFilter(query, "segment", segment);
        return query.isEmpty() ? PRODUCTS_PATH : PRODUCTS_PATH + "?" + query;
    }

    private static void appendFilter(StringBuilder query, String name, String value) {
        if (value == null || value.isBlank()) {
            return;
        }
        if (!query.isEmpty()) {
            query.append('&');
        }
        query.append(name).append('=').append(UriUtils.encodeQueryParam(value.trim(), StandardCharsets.UTF_8));
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
