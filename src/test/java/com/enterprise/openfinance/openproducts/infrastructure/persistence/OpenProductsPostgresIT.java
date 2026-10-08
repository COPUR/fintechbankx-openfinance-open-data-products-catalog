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
// snapshot-refresh=0s: rows inserted by a test must be visible to the next request.
@SpringBootTest(properties = {"openproducts.catalog.seed-enabled=true", "openproducts.catalog.snapshot-refresh=0s"})
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

    /**
     * The adapter's own storage predicate, without the application's re-check:
     * ACTIVE only, effective_from <= asOf < effective_to, and the type and
     * segment filters, all applied by PostgreSQL.
     */
    @Test
    void adapterNarrowsByStatusEffectiveWindowTypeAndSegmentInStorage() {
        String asOf = "2026-06-01T00:00:00Z";
        insert("IT-ACTIVE", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", null);
        insert("IT-STARTS-NOW", "PCA", "ACTIVE", asOf, null);
        insert("IT-ENDS-LATER", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", "2026-06-01T00:00:01Z");
        insert("IT-ENDS-NOW", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", asOf);
        insert("IT-STARTS-LATER", "PCA", "ACTIVE", "2026-06-01T00:00:01Z", null);
        insert("IT-DRAFT", "PCA", "DRAFT", "2026-01-01T00:00:00Z", null);
        insert("IT-WITHDRAWN", "PCA", "WITHDRAWN", "2026-01-01T00:00:00Z", null);
        insert("IT-LOAN", "LOAN", "ACTIVE", "2026-01-01T00:00:00Z", null);
        insert("IT-ACTIVE-RETAIL", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", null);
        jdbc.update("UPDATE " + SCHEMA + ".product SET segment = 'RETAIL' WHERE product_id = 'IT-ACTIVE-RETAIL'");

        ProductCatalogPort storage = ((SnapshotProductCatalog) catalogPort).delegate();
        java.time.Instant at = java.time.Instant.parse(asOf);

        assertThat(storage.findOfferable(new com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery("pca", "sme"), at))
            .extracting(e -> e.offer().productId())
            .containsExactly("IT-ACTIVE", "IT-ENDS-LATER", "IT-STARTS-NOW", "SAMPLE-SME-PCA-01");
        assertThat(storage.findOfferable(new com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery(null, "RETAIL"), at))
            .extracting(e -> e.offer().productId())
            .containsExactly("IT-ACTIVE-RETAIL", "SAMPLE-PCA-001", "SAMPLE-SAV-001");
        assertThat(storage.findOfferable(new com.enterprise.openfinance.openproducts.domain.query.ListProductsQuery("LOAN", null), at))
            .extracting(e -> e.offer().productId())
            .containsExactly("IT-LOAN", "SAMPLE-SME-LOAN-01");
    }

    @Test
    void everyInsertAndUpdateIsRecordedInTheAppendOnlyHistory() {
        String user = jdbc.queryForObject("SELECT current_user", String.class);
        long before = jdbc.queryForObject("SELECT coalesce(max(history_id), 0) FROM " + SCHEMA + ".product_history", Long.class);
        jdbc.execute("SET application_name = 'import-products/it-operator'");
        try {
            insert("IT-HIST", "PCA", "ACTIVE", "2026-01-01T00:00:00Z", null);
            jdbc.update("UPDATE " + SCHEMA + ".product SET monthly_fee_amount = 15.00, version = version + 1"
                + " WHERE product_id = 'IT-HIST'");
        } finally {
            jdbc.execute("RESET application_name");
        }

        List<java.util.Map<String, Object>> history = jdbc.queryForList(
            "SELECT operation, old_row->>'monthly_fee_amount' AS old_fee, new_row->>'monthly_fee_amount' AS new_fee,"
                + " changed_by, application_name, changed_at IS NOT NULL AS stamped"
                + " FROM " + SCHEMA + ".product_history WHERE product_id = 'IT-HIST' AND history_id > ? ORDER BY history_id", before);

        assertThat(history).hasSize(2);
        assertThat(history.get(0)).containsEntry("operation", "INSERT").containsEntry("old_fee", null)
            .containsEntry("new_fee", "12.50").containsEntry("changed_by", user)
            .containsEntry("application_name", "import-products/it-operator").containsEntry("stamped", true);
        assertThat(history.get(1)).containsEntry("operation", "UPDATE").containsEntry("old_fee", "12.50")
            .containsEntry("new_fee", "15.00");

        assertThatThrownBy(() -> jdbc.update("UPDATE " + SCHEMA + ".product_history SET changed_by = 'someone-else'"
                + " WHERE product_id = 'IT-HIST'"))
            .hasMessageContaining("product_history is append-only");
        assertThatThrownBy(() -> jdbc.update("DELETE FROM " + SCHEMA + ".product_history WHERE product_id = 'IT-HIST'"))
            .hasMessageContaining("product_history is append-only");
    }

    /** import-products.sh sets fbx.operator_arn from aws sts get-caller-identity; the history keeps it. */
    @Test
    void historyRecordsTheOperatorsAwsCallerIdentity() {
        String arn = "arn:aws:sts::111122223333:assumed-role/CatalogueOperator/it-operator";
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SELECT set_config('fbx.operator_arn', '" + arn + "', false)");
                try {
                    statement.execute("INSERT INTO " + SCHEMA + ".product (product_id, product_type, segment, name, currency,"
                        + " monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from, updated_at)"
                        + " VALUES ('IT-ARN', 'PCA', 'SME', 'Product IT-ARN', 'AED', 1.00, 'AED', 0.00, 'ACTIVE',"
                        + " '2026-01-01T00:00:00Z', '2026-03-10T00:00:00Z')");
                } finally {
                    statement.execute("RESET fbx.operator_arn");
                }
            }
            return null;
        });

        assertThat(jdbc.queryForObject("SELECT operator_arn FROM " + SCHEMA + ".product_history"
            + " WHERE product_id = 'IT-ARN' ORDER BY history_id DESC LIMIT 1", String.class)).isEqualTo(arn);
    }

    private void insert(String id, String type, String status, String from, String to) {
        jdbc.update("INSERT INTO " + SCHEMA + ".product (product_id, product_type, segment, name, currency,"
                + " monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from, effective_to, updated_at)"
                + " VALUES (?, ?, 'SME', ?, 'AED', 12.50, 'AED', 3.10, ?, ?::timestamptz, ?::timestamptz, '2026-03-10T00:00:00Z')",
            id, type, "Product " + id, status, from, to);
    }

    @Test
    void postgresAdapterIsTheCatalogueAuthority() {
        assertThat(catalogPort).isInstanceOf(SnapshotProductCatalog.class);
        assertThat(((SnapshotProductCatalog) catalogPort).delegate()).isInstanceOf(JpaProductCatalogAdapter.class);
    }

    @Test
    void flywayAppliedSchemaMigrationAndSeedInTheServiceSchema() {
        List<String> applied = jdbc.queryForList(
            "SELECT version || ':' || description FROM " + SCHEMA
                + ".flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank", String.class);

        assertThat(applied).containsExactly("1:create product catalogue", "2:product history and roles");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM " + SCHEMA
            + ".product WHERE product_id IN ('SAMPLE-PCA-001', 'SAMPLE-SAV-001', 'SAMPLE-SME-LOAN-01', 'SAMPLE-SME-PCA-01')", Integer.class))
            .isEqualTo(4);
    }

    @Test
    void servesTheSeededCatalogueFromPostgresOrderedByProductId() throws Exception {
        mvc.perform(get("/open-finance/v1/products").header("X-FAPI-Interaction-ID", "pg-001"))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-cache"))
            .andExpect(jsonPath("$.Meta.TotalRecords").value(4))
            .andExpect(jsonPath("$.Data.Product[*].ProductId").value(
                org.hamcrest.Matchers.contains("SAMPLE-PCA-001", "SAMPLE-SAV-001", "SAMPLE-SME-LOAN-01", "SAMPLE-SME-PCA-01")))
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
            .andExpect(jsonPath("$.Data.Product[0].ProductId").value("SAMPLE-SME-PCA-01"));

        mvc.perform(get("/open-finance/v1/products?segment=SME").header("X-FAPI-Interaction-ID", "pg-003"))
            .andExpect(jsonPath("$.Data.Product[*].ProductId").value(
                org.hamcrest.Matchers.contains("SAMPLE-SME-LOAN-01", "SAMPLE-SME-PCA-01")));
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
                org.hamcrest.Matchers.contains("IT-ACTIVE", "SAMPLE-SME-PCA-01")))
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
