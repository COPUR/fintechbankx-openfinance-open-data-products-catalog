package com.enterprise.openfinance.openproducts.domain.query;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.enterprise.openfinance.openproducts.domain.exception.InvalidProductFilterException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

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

    @Test
    void acceptsCodesOfTwoToThirtyLettersDigitsUnderscoresOrHyphens() {
        ListProductsQuery query = new ListProductsQuery("credit_card", "a1-b2-c3-d4-e5-f6-g7-h8-i9-j0z");

        assertThat(query.type()).isEqualTo("CREDIT_CARD");
        assertThat(query.segment()).isEqualTo("A1-B2-C3-D4-E5-F6-G7-H8-I9-J0Z");
        assertThat(query.segment()).hasSize(30);
    }

    @ParameterizedTest
    @ValueSource(strings = {"P", "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234", "PCA;DROP", "P CA", "PCA%27", "pcı", "RÉTAIL"})
    void rejectsTypeOutsideTheCodePattern(String type) {
        assertThatThrownBy(() -> new ListProductsQuery(type, null))
            .isInstanceOf(InvalidProductFilterException.class)
            .hasMessage("type must match ^[A-Z0-9_-]{2,30}$");
    }

    @Test
    void rejectsSegmentOutsideTheCodePattern() {
        assertThatThrownBy(() -> new ListProductsQuery("PCA", "x".repeat(31)))
            .isInstanceOf(InvalidProductFilterException.class)
            .hasMessage("segment must match ^[A-Z0-9_-]{2,30}$");
    }
}
