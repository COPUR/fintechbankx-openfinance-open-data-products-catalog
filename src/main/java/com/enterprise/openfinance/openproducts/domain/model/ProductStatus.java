package com.enterprise.openfinance.openproducts.domain.model;

/** Lifecycle of a catalogue product. Only ACTIVE products can be offered. */
public enum ProductStatus {
    DRAFT,
    ACTIVE,
    WITHDRAWN
}
