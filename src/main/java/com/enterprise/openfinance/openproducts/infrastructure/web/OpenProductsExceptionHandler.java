package com.enterprise.openfinance.openproducts.infrastructure.web;

import com.enterprise.openfinance.openproducts.infrastructure.web.dto.ErrorResponse;
import jakarta.servlet.http.HttpServletRequest;
import java.time.Instant;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ExceptionHandler;

@ControllerAdvice
public class OpenProductsExceptionHandler {

    @ExceptionHandler(MissingRequestHeaderException.class)
    public ResponseEntity<ErrorResponse> handleMissingHeader(MissingRequestHeaderException ex, HttpServletRequest request) {
        return ResponseEntity.badRequest().body(new ErrorResponse(
            "INVALID_REQUEST",
            ex.getMessage(),
            interactionId(request),
            Instant.now()
        ));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleGeneral(Exception ex, HttpServletRequest request) {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(new ErrorResponse(
            "INTERNAL_ERROR",
            "Internal server error",
            interactionId(request),
            Instant.now()
        ));
    }

    private String interactionId(HttpServletRequest request) {
        String interactionId = request.getHeader("X-FAPI-Interaction-ID");
        return interactionId == null || interactionId.isBlank() ? "UNKNOWN" : interactionId;
    }
}
