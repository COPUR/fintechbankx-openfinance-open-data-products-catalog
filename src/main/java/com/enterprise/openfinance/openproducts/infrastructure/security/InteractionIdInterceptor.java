package com.enterprise.openfinance.openproducts.infrastructure.security;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

@Component
public class InteractionIdInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        String interactionId = request.getHeader("X-FAPI-Interaction-ID");
        if (interactionId == null || interactionId.isBlank()) {
            throw new MissingInteractionIdException("Missing required header: X-FAPI-Interaction-ID");
        }
        return true;
    }
}
