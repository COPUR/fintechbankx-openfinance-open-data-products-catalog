package com.enterprise.openfinance.openproducts.infrastructure.functional;

import static org.assertj.core.api.Assertions.assertThat;

import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ProductListResponse;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.ResponseEntity;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class OpenProductsUatTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void shouldSupportEtagBasedNotModifiedFlow() {
        HttpHeaders headers = new HttpHeaders();
        headers.add("X-FAPI-Interaction-ID", "uat-001");

        ResponseEntity<ProductListResponse> first = restTemplate.exchange(
            "http://localhost:" + port + "/open-finance/v1/products?type=PCA",
            HttpMethod.GET,
            new HttpEntity<>(headers),
            ProductListResponse.class
        );

        assertThat(first.getStatusCode().value()).isEqualTo(200);
        String etag = first.getHeaders().getETag();
        assertThat(etag).isNotBlank();

        HttpHeaders secondHeaders = new HttpHeaders();
        secondHeaders.add("X-FAPI-Interaction-ID", "uat-001");
        secondHeaders.add("If-None-Match", etag);

        ResponseEntity<String> second = restTemplate.exchange(
            "http://localhost:" + port + "/open-finance/v1/products?type=PCA",
            HttpMethod.GET,
            new HttpEntity<>(secondHeaders),
            String.class
        );

        assertThat(second.getStatusCode().value()).isEqualTo(304);
        assertThat(second.getHeaders().getFirst("X-OF-Cache")).isEqualTo("HIT");
    }
}
