package com.enterprise.openfinance.openproducts.domain.exception;

/** A catalogue filter (type or segment) is not a valid product code. */
public class InvalidProductFilterException extends IllegalArgumentException {

    public InvalidProductFilterException(String message) {
        super(message);
    }
}
