package com.enterprise.openfinance.openproducts.infrastructure.contract;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;

class OpenProductsOpenApiContractTest {

    @Test
    void openApiShouldDeclarePublicProductsPathAndOperation() throws IOException {
        String yaml = Files.readString(Path.of("api/openapi/open-products-service.yaml"));

        assertThat(yaml).contains("/products:");
        assertThat(yaml).contains("operationId: listProducts");
        assertThat(yaml).contains("security: []");
        assertThat(yaml).contains("X-FAPI-Interaction-ID");
    }
}
