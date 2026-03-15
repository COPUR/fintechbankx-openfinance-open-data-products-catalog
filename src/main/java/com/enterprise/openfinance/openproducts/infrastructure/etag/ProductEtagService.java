package com.enterprise.openfinance.openproducts.infrastructure.etag;

import com.enterprise.openfinance.openproducts.domain.Product;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;

@Component
public class ProductEtagService {

    public String compute(List<Product> products, String type, String segment) {
        String payload = (type == null ? "" : type) + "|" + (segment == null ? "" : segment) + "|" +
                products.stream()
                        .sorted(Comparator.comparing(Product::productId))
                        .map(product -> String.join("|",
                                safe(product.productId()),
                                safe(product.name()),
                                safe(product.type()),
                                safe(product.segment()),
                                safe(product.currency()),
                                safe(product.monthlyFee()),
                                safe(product.annualRate()),
                                product.updatedAt() == null ? "" : product.updatedAt().toString()))
                        .reduce((a, b) -> a + "#" + b)
                        .orElse("");

        return "\"" + sha256(payload) + "\"";
    }

    private String safe(String value) {
        return value == null ? "" : value;
    }

    private String sha256(String payload) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hashed = digest.digest(payload.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hashed);
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException("SHA-256 is required", ex);
        }
    }
}
