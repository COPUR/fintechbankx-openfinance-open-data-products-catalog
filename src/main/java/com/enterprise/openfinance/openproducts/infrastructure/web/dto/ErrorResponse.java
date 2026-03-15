package com.enterprise.openfinance.openproducts.infrastructure.web.dto;

public record ErrorResponse(String code, String message, String interactionId, String timestamp) {
}
