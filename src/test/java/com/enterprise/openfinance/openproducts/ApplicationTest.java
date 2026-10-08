package com.enterprise.openfinance.openproducts;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.mockito.MockedStatic;
import org.mockito.Mockito;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationContext;
import org.springframework.core.env.Environment;
import org.springframework.test.context.ActiveProfiles;

class ApplicationTest {

    private static final String RESOURCE_SERVER_PREFIX = "spring.security.oauth2.resourceserver.jwt.";

    /** No OIDC_* variable is provided: the public catalogue needs no identity provider. */
    @Nested
    @SpringBootTest
    @ActiveProfiles("in-memory")
    class WithoutAnyOidcVariable {

        @Autowired ApplicationContext context;
        @Autowired Environment environment;

        @Test
        void startsWithoutAJwtDecoderOrResourceServerSettings() {
            assertThat(System.getenv().keySet()).noneMatch(name -> name.startsWith("OIDC_"));
            assertThat(context.getBeanNamesForType(jwtDecoderType())).isEmpty();
            assertThat(environment.getProperty(RESOURCE_SERVER_PREFIX + "issuer-uri")).isNull();
            assertThat(environment.getProperty(RESOURCE_SERVER_PREFIX + "jwk-set-uri")).isNull();
        }
    }

    /** What the old ConfigMap rendered when the Helm values were left empty. */
    @Nested
    @SpringBootTest(properties = {"OIDC_ISSUER_URI=", "OIDC_JWK_SET_URI=", "OIDC_AUDIENCE="})
    @ActiveProfiles("in-memory")
    class WithEmptyOidcVariables {

        @Autowired ApplicationContext context;

        @Test
        void startsWithoutAJwtDecoder() {
            assertThat(context.getBeanNamesForType(jwtDecoderType())).isEmpty();
        }
    }

    @Test
    void mainDelegatesToSpringApplication() {
        String[] args = {"--spring.main.web-application-type=none"};
        try (MockedStatic<SpringApplication> springApplication = Mockito.mockStatic(SpringApplication.class)) {
            Application.main(args);
            springApplication.verify(() -> SpringApplication.run(Application.class, args));
        }
    }

    // Looked up by name: once the resource server is gone the class is not on the classpath.
    private static Class<?> jwtDecoderType() {
        try {
            return Class.forName("org.springframework.security.oauth2.jwt.JwtDecoder");
        } catch (ClassNotFoundException absent) {
            return Void.class;
        }
    }
}
