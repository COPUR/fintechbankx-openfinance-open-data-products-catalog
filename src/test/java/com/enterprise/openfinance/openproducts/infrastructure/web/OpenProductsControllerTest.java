package com.enterprise.openfinance.openproducts.infrastructure.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
class OpenProductsControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void shouldRejectWhenInteractionHeaderMissing() throws Exception {
        mockMvc.perform(get("/open-finance/v1/products"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("HEADER_MISSING"));
    }

    @Test
    void shouldReturnProductsWithEtagAndTraceHeaders() throws Exception {
        mockMvc.perform(get("/open-finance/v1/products")
                        .header("X-FAPI-Interaction-ID", "interaction-101")
                        .param("segment", "SME"))
                .andExpect(status().isOk())
                .andExpect(header().exists("ETag"))
                .andExpect(header().exists("X-Trace-Id"))
                .andExpect(header().string("X-FAPI-Interaction-ID", "interaction-101"))
                .andExpect(jsonPath("$.Data.Product.length()").value(1))
                .andExpect(jsonPath("$.Meta.TotalRecords").value(1));
    }

    @Test
    void shouldReturnNotModifiedWhenIfNoneMatchMatches() throws Exception {
        String etag = mockMvc.perform(get("/open-finance/v1/products")
                        .header("X-FAPI-Interaction-ID", "interaction-102")
                        .param("type", "PCA"))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getHeader("ETag");

        mockMvc.perform(get("/open-finance/v1/products")
                        .header("X-FAPI-Interaction-ID", "interaction-102")
                        .header("If-None-Match", etag)
                        .param("type", "PCA"))
                .andExpect(status().isNotModified());
    }
}
