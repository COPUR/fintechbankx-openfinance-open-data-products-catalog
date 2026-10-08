package com.enterprise.openfinance.openproducts.architecture;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.Test;

class HexagonalArchitectureTest {

    private static final JavaClasses CLASSES = new ClassFileImporter()
        .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
        .importPackages("com.enterprise.openfinance.openproducts");

    @Test
    void domainDependsOnNothingOutsideTheJdk() {
        noClasses().that().resideInAPackage("com.enterprise.openfinance.openproducts.domain..")
            .should().dependOnClassesThat().resideInAnyPackage(
                "com.enterprise.openfinance.openproducts.application..",
                "com.enterprise.openfinance.openproducts.infrastructure..",
                "org.springframework..",
                "org.springframework.data..",
                "jakarta.persistence..",
                "org.hibernate..",
                "com.fasterxml..",
                "org.flywaydb..")
            .check(CLASSES);
    }

    @Test
    void applicationDoesNotDependOnInfrastructure() {
        noClasses().that().resideInAPackage("com.enterprise.openfinance.openproducts.application..")
            .should().dependOnClassesThat().resideInAnyPackage(
                "com.enterprise.openfinance.openproducts.infrastructure..",
                "jakarta.persistence..",
                "org.springframework.data..")
            .check(CLASSES);
    }
}
