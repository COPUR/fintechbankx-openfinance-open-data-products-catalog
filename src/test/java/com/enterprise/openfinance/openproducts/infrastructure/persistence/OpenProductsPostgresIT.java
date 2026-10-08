package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.enterprise.openfinance.openproducts.domain.port.out.ProductCatalogPort;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/**
 * Boots the service against PostgreSQL: Flyway builds sc_of_open_products_catalog
 * and loads the dev seed, Hibernate validates the entity against it, and the
 * catalogue is served from the database over HTTP.
 */
@SpringBootTest(properties = "openproducts.catalog.seed-enabled=true")
@AutoConfigureMockMvc
class OpenProductsPostgresIT {

    private static final String SCHEMA = "sc_of_open_products_catalog";

    @BeforeAll
    static void requireDatabase() {
        PostgresTestDatabase.assumeAvailable();
    }

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        PostgresTestDatabase.register(registry);
    }

    @Autowired MockMvc mvc;
    @Autowired JdbcTemplate jdbc;
    @Autowired ProductCatalogPort catalogPort;

    @AfterEach
    void removeTestRows() {
        jdbc.update("DELETE FROM " + SCHEMA + ".product WHERE product_id LIKE 'IT-%'");
    }

    private void insert(String id, String type, String status, String from, String to) {
        jdbc.update("INSERT INTO " + SCHEMA + ".product (product_id, product_type, segment, name, currency,"
                + " monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from, effective_to, updated_at)"
                + " VALUES (?, ?, 'SME', ?, 'AED', 12.50, 'AED', 3.10, ?, ?::timestamptz, ?::timestamptz, '2026-03-10T00:00:00Z')",
            id, type, "Product " + id, status, from, to);
    }

    @Test
    void postgresAdapterIsTheCatalogueAuthority() {
        assertThat(catalogPort).isInstanceOf(JpaProductCatalogAdapter.class);
    }

    @Test
    void flywayAppliedSchemaMigrationAndSeedInTheServiceSchema() {
        List<String> applied = jdbc.queryForList(
            "SELECT version || ':' || description FROM " + SCHEMA
                + ".flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank", String.class);

        assertThat(applied).containsExactly("1:create product catalogue");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM " + SCHEMA
            + ".product WHERE product_id IN ('PCA-001', 'SAV-001', 'SME-LOAN-01', 'SME-PCA-01')", Integer.class))
            .isEqualTo(4);
    }

    @Test
    void servesTheSeededCatalogueFromPostgresOrderedByProductId() throws Exception {
        mvc.perform(get("/open-finance/v1/products").header("X-FAPI-Interaction-ID", "pg-001"))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "max-age=60, public"))
            .andExpect(jsonPath("$.Meta.TotalRecords").value(4))
            .andExpect(jsonPath("$.Data.Product[*].ProductId").value(
                org.hamcrest.Matchers.contains("PCA-001", "SAV-001", "SME-LOAN-01", "SME-PCA-01")))
            .andExpect(jsonPath("$.Data.Product[3].MonthlyFee").value("35.00"))
            .andExpect(jsonPath("$.Data.Product[3].Currency").value("AED"))
            .andExpect(jsonPath("$.Data.Product[2].AnnualRate").value("6.75"))
            .andExpect(jsonPath("$.Data.Product[3].UpdatedAt").value("2026-03-04T00:00:00Z"));
    }

    @Test
    void filtersInTheDatabaseIgnoringCase() throws Exception {
        mvc.perform(get("/open-finance/v1/products?type=pca&segment=sme").header("X-FAPI-Interaction-ID", "pg-002"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.Meta.TotalRecords").value(1))
            .andExpect(jsonPath("$.Data.Product[0].ProductId").value("SME-PCA-01"));

        mvc.perform(get("/open-finance/v1/products?segment=SME").header("X-FAPI-Interaction-ID", "pg-003"))
            .andExpect(jsonPath("$.Data.Product[*].ProductId").value(
                org.hamcrest.Matchers.contains("SME-LOAN-01", "SME-PCA-01")));
    }

    @Test
    void onlyActiveProductsInsideTheirEffectiveWindowAreOffered() throws Exception {
        insert("IT-ACTIVE", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", null);
        insert("IT-DRAFT", "PCA", "DRAFT", "2026-01-01T00:00:00Z", null);
        insert("IT-WITHDRAWN", "PCA", "WITHDRAWN", "2026-01-01T00:00:00Z", null);
        insert("IT-FUTURE", "PCA", "ACTIVE", "2099-01-01T00:00:00Z", null);
        insert("IT-ENDED", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z");

        mvc.perform(get("/open-finance/v1/products?segment=sme&type=PCA").header("X-FAPI-Interaction-ID", "pg-004"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.Data.Product[*].ProductId").value(
                org.hamcrest.Matchers.contains("IT-ACTIVE", "SME-PCA-01")))
            .andExpect(jsonPath("$.Data.Product[0].MonthlyFee").value("12.50"))
            .andExpect(jsonPath("$.Data.Product[0].AnnualRate").value("3.10"));
    }

    @Test
    void etagChangesWhenAProductChangesAndRevalidatesOtherwise() throws Exception {
        String first = mvc.perform(get("/open-finance/v1/products").header("X-FAPI-Interaction-ID", "pg-005"))
            .andReturn().getResponse().getHeader("ETag");

        mvc.perform(get("/open-finance/v1/products").header("X-FAPI-Interaction-ID", "pg-006")
                .header("If-None-Match", first))
            .andExpect(status().isNotModified());

        insert("IT-NEW", "LOAN", "ACTIVE", "2026-01-01T00:00:00Z", null);

        String second = mvc.perform(get("/open-finance/v1/products").header("X-FAPI-Interaction-ID", "pg-007")
                .header("If-None-Match", first))
            .andExpect(status().isOk())
            .andReturn().getResponse().getHeader("ETag");
        assertThat(second).isNotEqualTo(first);
    }

    @Test
    void schemaRejectsAFeeInAnotherCurrencyAndLowerCaseCodes() {
        assertThatThrownBy(() -> jdbc.update("INSERT INTO " + SCHEMA + ".product (product_id, product_type, segment, name,"
                + " currency, monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from)"
                + " VALUES ('IT-BAD-FEE', 'PCA', 'SME', 'Bad', 'AED', 1.00, 'USD', 0, 'ACTIVE', now())"))
            .isInstanceOf(DataIntegrityViolationException.class)
            .hasMessageContaining("ck_product_fee_currency");

        assertThatThrownBy(() -> insert("IT-lower", "pca", "ACTIVE", "2026-01-01T00:00:00Z", null))
            .isInstanceOf(DataIntegrityViolationException.class)
            .hasMessageContaining("ck_product_type");
    }
}
