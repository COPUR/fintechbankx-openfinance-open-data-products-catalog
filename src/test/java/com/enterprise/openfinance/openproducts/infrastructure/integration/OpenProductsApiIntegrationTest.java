package com.enterprise.openfinance.openproducts.infrastructure.integration;

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
class OpenProductsApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void shouldFilterProductsForSmeSegment() {
        HttpHeaders headers = new HttpHeaders();
        headers.add("X-FAPI-Interaction-ID", "it-int-001");

        ResponseEntity<ProductListResponse> response = restTemplate.exchange(
            "http://localhost:" + port + "/open-finance/v1/products?segment=SME",
            HttpMethod.GET,
            new HttpEntity<>(headers),
            ProductListResponse.class
        );

        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getBody()).isNotNull();
        assertThat(response.getBody().meta().totalRecords()).isGreaterThan(0);
        assertThat(response.getBody().data().products())
            .allMatch(p -> "SME".equals(p.segment()));
    }
}
