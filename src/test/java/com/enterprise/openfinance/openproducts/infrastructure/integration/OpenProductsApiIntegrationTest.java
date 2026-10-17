package com.enterprise.openfinance.openproducts.infrastructure.integration;

import static org.assertj.core.api.Assertions.assertThat;

import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ProductListResponse;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.ResponseEntity;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("in-memory")
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

    /**
     * Defence in depth against cache poisoning: the platform ingress overwrites
     * X-Forwarded-*, but if a forged value ever reached the service it must not
     * appear in the body or in any header, and the response must not be stored
     * by shared caches.
     */
    @Test
    void forgedForwardedHeadersNeverReachTheResponse() {
        HttpHeaders headers = new HttpHeaders();
        headers.add("X-FAPI-Interaction-ID", "it-int-002");
        headers.add("X-Forwarded-Host", "evil.example");
        headers.add("X-Forwarded-Proto", "https");
        headers.add("X-Forwarded-Port", "443");
        headers.add("X-Forwarded-Prefix", "/evil.example");
        headers.add("Forwarded", "host=evil.example;proto=https");

        ResponseEntity<String> response = restTemplate.exchange(
            "http://localhost:" + port + "/open-finance/v1/products?type=PCA&segment=SME",
            HttpMethod.GET,
            new HttpEntity<>(headers),
            String.class
        );

        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getBody()).doesNotContain("evil.example");
        response.getHeaders().forEach((name, values) ->
            assertThat(values).as("header %s", name).noneMatch(v -> v.contains("evil.example")));
        assertThat(response.getBody()).contains("\"Self\":\"/open-finance/v1/products?type=PCA&segment=SME\"");
        assertThat(response.getHeaders().getCacheControl()).isEqualTo("no-cache");
        assertThat(response.getHeaders().getFirst("X-FAPI-Interaction-ID")).isEqualTo("it-int-002");
    }
}
