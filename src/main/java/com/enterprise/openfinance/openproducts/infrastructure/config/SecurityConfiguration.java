package com.enterprise.openfinance.openproducts.infrastructure.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.util.matcher.AntPathRequestMatcher;
import org.springframework.security.web.util.matcher.RequestMatcher;

/**
 * The product catalogue is public open data (OpenAPI declares security: []),
 * so GET /open-finance/v1/products is anonymous and every other path is
 * denied. No endpoint authenticates callers, so there is no OAuth2 resource
 * server, JwtDecoder or identity-provider setting: an Authorization header is
 * never read. Add the resource server together with the first authenticated
 * endpoint. Actuator endpoints are served on the management port, which is
 * not exposed outside the pod network.
 */
@Configuration
public class SecurityConfiguration {

    static final RequestMatcher PUBLIC_CATALOGUE =
        new AntPathRequestMatcher("/open-finance/v1/products", HttpMethod.GET.name());

    @Bean
    SecurityFilterChain apiSecurity(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .httpBasic(basic -> basic.disable())
            .formLogin(form -> form.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health/**", "/actuator/info", "/actuator/prometheus").permitAll()
                .requestMatchers(PUBLIC_CATALOGUE).permitAll()
                .requestMatchers("/error").permitAll()
                .anyRequest().denyAll());
        return http.build();
    }
}
