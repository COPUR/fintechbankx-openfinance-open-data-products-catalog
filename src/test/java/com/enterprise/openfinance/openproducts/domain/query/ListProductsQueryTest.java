package com.enterprise.openfinance.openproducts.domain.query;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class ListProductsQueryTest {

    @Test
    void trimsAndUpperCasesFilters() {
        ListProductsQuery query = new ListProductsQuery(" pca ", " sme ");

        assertThat(query.type()).isEqualTo("PCA");
        assertThat(query.segment()).isEqualTo("SME");
    }

    @Test
    void blankFiltersMeanNoFilter() {
        ListProductsQuery query = new ListProductsQuery("  ", null);

        assertThat(query.type()).isNull();
        assertThat(query.segment()).isNull();
    }
}
