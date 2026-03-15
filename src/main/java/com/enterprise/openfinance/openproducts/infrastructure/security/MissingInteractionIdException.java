package com.enterprise.openfinance.openproducts.infrastructure.security;

public class MissingInteractionIdException extends RuntimeException {
    public MissingInteractionIdException(String message) {
        super(message);
    }
}
