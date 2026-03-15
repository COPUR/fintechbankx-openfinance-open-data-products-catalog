package com.enterprise.openfinance.openproducts.infrastructure.web.dto;

import java.time.Instant;

public record ErrorResponse(
    String code,
    String message,
    String interactionId,
    Instant timestamp
) {}
