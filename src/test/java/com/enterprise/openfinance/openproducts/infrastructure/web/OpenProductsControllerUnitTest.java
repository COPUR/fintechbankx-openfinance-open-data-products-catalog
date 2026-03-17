package com.enterprise.openfinance.openproducts.infrastructure.web;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.enterprise.openfinance.openproducts.domain.model.ProductListResult;
import com.enterprise.openfinance.openproducts.domain.model.ProductOffer;
import com.enterprise.openfinance.openproducts.domain.port.in.OpenProductsUseCase;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(controllers = OpenProductsController.class)
class OpenProductsControllerUnitTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private OpenProductsUseCase openProductsUseCase;

    @Test
    void shouldReturnProductsAndHeaders() throws Exception {
        when(openProductsUseCase.listProducts(any())).thenReturn(new ProductListResult(List.of(
            new ProductOffer("PCA-001", "Everyday Current", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z"))
        )));

        mockMvc.perform(get("/open-finance/v1/products")
                .header("X-FAPI-Interaction-ID", "it-001"))
            .andExpect(status().isOk())
            .andExpect(header().exists("ETag"))
            .andExpect(header().string("X-FAPI-Interaction-ID", "it-001"))
            .andExpect(jsonPath("$.Data.Product[0].ProductId").value("PCA-001"))
            .andExpect(jsonPath("$.Meta.TotalRecords").value(1));
    }

    @Test
    void shouldReturnNotModifiedWhenIfNoneMatchMatches() throws Exception {
        when(openProductsUseCase.listProducts(any())).thenReturn(new ProductListResult(List.of(
            new ProductOffer("PCA-001", "Everyday Current", "PCA", "RETAIL", "AED", "0.00", "0.00", Instant.parse("2026-03-01T00:00:00Z"))
        )));

        String etag = mockMvc.perform(get("/open-finance/v1/products")
                .header("X-FAPI-Interaction-ID", "it-001"))
            .andReturn()
            .getResponse()
            .getHeader("ETag");

        mockMvc.perform(get("/open-finance/v1/products")
                .header("X-FAPI-Interaction-ID", "it-001")
                .header("If-None-Match", etag))
            .andExpect(status().isNotModified())
            .andExpect(header().string("X-OF-Cache", "HIT"));
    }

    @Test
    void shouldReturnBadRequestWhenInteractionHeaderMissing() throws Exception {
        mockMvc.perform(get("/open-finance/v1/products"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.code").value("INVALID_REQUEST"));
    }
}
