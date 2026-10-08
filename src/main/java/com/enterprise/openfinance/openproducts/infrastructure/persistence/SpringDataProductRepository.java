package com.enterprise.openfinance.openproducts.infrastructure.persistence;

import com.enterprise.openfinance.openproducts.infrastructure.persistence.entity.ProductEntity;
import java.time.Instant;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface SpringDataProductRepository extends JpaRepository<ProductEntity, String> {

    /** Served by the partial indexes ix_product_active_type_segment / ix_product_active_segment (V1). */
    @Query("""
        select p from ProductEntity p
         where p.status = 'ACTIVE'
           and p.effectiveFrom <= :asOf
           and (p.effectiveTo is null or p.effectiveTo > :asOf)
           and (:type is null or p.productType = :type)
           and (:segment is null or p.segment = :segment)
         order by p.productId""")
    List<ProductEntity> findOfferable(@Param("type") String type,
                                      @Param("segment") String segment,
                                      @Param("asOf") Instant asOf);
}
