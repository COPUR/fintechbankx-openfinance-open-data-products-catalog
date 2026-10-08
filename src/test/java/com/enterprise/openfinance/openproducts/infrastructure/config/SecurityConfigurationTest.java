package com.enterprise.openfinance.openproducts.infrastructure.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.oauth2.jwt.Jwt;

class SecurityConfigurationTest {

    private static final String ISSUER = "https://identity.example.test/realms/fintechbankx";
    private static final String AUDIENCE = "svc-of-open-products-catalog";

    private static Jwt token(String issuer, List<String> audience) {
        return Jwt.withTokenValue("t")
            .header("alg", "RS256")
            .issuer(issuer)
            .audience(audience)
            .subject("svc-of-some-caller")
            .issuedAt(Instant.now().minusSeconds(10))
            .expiresAt(Instant.now().plusSeconds(300))
            .build();
    }

    @Test
    void acceptsTokenForThisServiceFromThePlatformRealm() {
        assertThat(SecurityConfiguration.tokenValidator(ISSUER, AUDIENCE)
            .validate(token(ISSUER, List.of("account", AUDIENCE))).hasErrors()).isFalse();
    }

    @Test
    void rejectsTokenForAnotherAudience() {
        var result = SecurityConfiguration.tokenValidator(ISSUER, AUDIENCE)
            .validate(token(ISSUER, List.of("svc-of-consent-authorization")));

        assertThat(result.hasErrors()).isTrue();
        assertThat(result.getErrors()).anyMatch(e -> e.getDescription().contains(AUDIENCE));
    }

    @Test
    void rejectsTokenWithoutAudience() {
        assertThat(SecurityConfiguration.audienceValidator(AUDIENCE)
            .validate(Jwt.withTokenValue("t").header("alg", "RS256").subject("x").build()).hasErrors()).isTrue();
    }

    @Test
    void rejectsTokenFromAnotherIssuer() {
        assertThat(SecurityConfiguration.tokenValidator(ISSUER, AUDIENCE)
            .validate(token("https://evil.example.test/realms/fintechbankx", List.of(AUDIENCE))).hasErrors()).isTrue();
    }

    @Test
    void bearerTokensAreIgnoredOnlyOnThePublicCatalogue() {
        var resolver = SecurityConfiguration.publicCatalogueIgnoresTokens();

        MockHttpServletRequest catalogue = new MockHttpServletRequest("GET", "/open-finance/v1/products");
        catalogue.setServletPath("/open-finance/v1/products");
        catalogue.addHeader("Authorization", "Bearer abc");
        MockHttpServletRequest other = new MockHttpServletRequest("GET", "/open-finance/v1/other");
        other.setServletPath("/open-finance/v1/other");
        other.addHeader("Authorization", "Bearer abc");

        assertThat(resolver.resolve(catalogue)).isNull();
        assertThat(resolver.resolve(other)).isEqualTo("abc");
    }
}
