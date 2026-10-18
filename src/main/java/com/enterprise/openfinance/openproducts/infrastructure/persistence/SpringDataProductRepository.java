package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.infrastructure.persistence.entity.ProductEntity;
import java.time.Instant;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface SpringDataProductRepository extends JpaRepository<ProductEntity, String> {

    /**
     * Reads ONLY product, never a table that inherits from it: a child's rows
     * would be read through product without its history triggers having fired
     * (review 5). The history guard refuses such a child while armed; this is
     * the second layer. JPQL has no ONLY, hence the native query.
     * Served by the partial indexes ix_product_active_type_segment /
     * ix_product_active_segment (V1).
     */
    @Query(nativeQuery = true, value = """
        SELECT p.product_id, p.product_type, p.segment, p.name, p.currency,
               p.monthly_fee_amount, p.monthly_fee_currency, p.annual_rate_percent,
               p.status, p.effective_from, p.effective_to, p.updated_at, p.version
          FROM ONLY {h-schema}product p
         WHERE p.status = 'ACTIVE'
           AND p.effective_from <= :asOf
           AND (p.effective_to IS NULL OR p.effective_to > :asOf)
           AND (CAST(:type AS VARCHAR) IS NULL OR p.product_type = CAST(:type AS VARCHAR))
           AND (CAST(:segment AS VARCHAR) IS NULL OR p.segment = CAST(:segment AS VARCHAR))
         ORDER BY p.product_id""")
    List<ProductEntity> findOfferable(@Param("type") String type,
                                      @Param("segment") String segment,
                                      @Param("asOf") Instant asOf);
}
