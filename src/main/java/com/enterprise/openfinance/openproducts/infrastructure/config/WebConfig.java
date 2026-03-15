package com.enterprise.openfinance.openproducts.infrastructure.config;

import com.enterprise.openfinance.openproducts.infrastructure.security.InteractionIdInterceptor;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class WebConfig implements WebMvcConfigurer {

    private final InteractionIdInterceptor interactionIdInterceptor;

    public WebConfig(InteractionIdInterceptor interactionIdInterceptor) {
        this.interactionIdInterceptor = interactionIdInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(interactionIdInterceptor)
                .addPathPatterns("/open-finance/v1/**");
    }
}
