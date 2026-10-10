package com.enterprise.openfinance.openproducts.architecture;

import static com.tngtech.archunit.core.domain.JavaClass.Predicates.resideInAPackage;
import static com.tngtech.archunit.core.domain.properties.CanBeAnnotated.Predicates.annotatedWith;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.RestController;

/**
 * The four hexagonal guardrail rules (ADR-028, FINTECHBANKX_SERVICE_GUARDRAILS.md)
 * for root com.enterprise.openfinance.openproducts. Runs under ./gradlew check.
 */
class HexagonalArchitectureTest {

    private static final String ROOT = "com.enterprise.openfinance.openproducts";
    private static final String KAFKA_LISTENER = "org.springframework.kafka.annotation.KafkaListener";

    private static final JavaClasses CLASSES = new ClassFileImporter()
        .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
        .importPackages(ROOT);

    @Test
    void rule1DomainDependsOnNoOuterLayerOrFramework() {
        noClasses().that().resideInAPackage(ROOT + ".domain..")
            .should().dependOnClassesThat().resideInAnyPackage(
                ROOT + ".application..",
                ROOT + ".infrastructure..",
                "org.springframework..",
                "org.springframework.data..",
                "org.springframework.kafka..",
                "org.apache.kafka..",
                "jakarta.persistence..",
                "com.mongodb..",
                "org.hibernate..",
                "com.fasterxml..",
                "org.flywaydb..")
            .check(CLASSES);
    }

    @Test
    void rule2ApplicationDependsOnNoInfrastructure() {
        noClasses().that().resideInAPackage(ROOT + ".application..")
            .should().dependOnClassesThat().resideInAPackage(ROOT + ".infrastructure..")
            .check(CLASSES);
    }

    @Test
    void rule3ControllersAndListenersUseInboundPortsNotApplicationClasses() {
        noClasses().that().areAnnotatedWith(RestController.class)
            .or().containAnyMethodsThat(annotatedWith(KAFKA_LISTENER))
            .should().dependOnClassesThat().resideInAPackage(ROOT + ".application..")
            .check(CLASSES);

        classes().that().areAnnotatedWith(RestController.class)
            .should().dependOnClassesThat().resideInAPackage(ROOT + ".domain.port.in..")
            .check(CLASSES);
    }

    @Test
    void rule4OutboundPortImplementationsResideInInfrastructure() {
        classes().that().implement(resideInAPackage(ROOT + ".domain.port.out.."))
            .and().areNotInterfaces()
            .should().resideInAPackage(ROOT + ".infrastructure..")
            .check(CLASSES);
    }
}
