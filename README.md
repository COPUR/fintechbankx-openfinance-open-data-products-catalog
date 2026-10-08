# fintechbankx-openfinance-open-data-products-catalog

Bu repository, FinTechBankX DDD/EDA dönüşümünde **svc-of-open-products-catalog** servis yetkinliğinin kaynak kodunu, kontratlarını ve operasyonel guardrail'lerini içerir.

## Sorumluluk ve Sahiplik
| Alan | Değer |
|---|---|
| Organizasyon Modeli | Spotify Model (Tribe/Squad) |
| Tribe | Open Finance Tribe |
| Squad | Open Data Squad |
| Repo Kümesi (Capability) | open_finance |
| Service ID | svc-of-open-products-catalog |
| Bounded Context | open_products_catalog |
| Wave | 1 |
| Mimari Yaklaşım | DDD + Hexagonal + Event-Driven |

## Sorumluluk Sınırları
- Bu repo kendi bounded context domain modelinin tek yetkili sahibidir.
- Domain kuralları altyapıdan bağımsız tutulur; entegrasyonlar port/adapter katmanında yönetilir.
- API/Event kontratları geriye dönük uyumluluk kontrolleri ile korunur.
- Güvenlik guardrail'leri (mTLS, token doğrulama, idempotency, log hijyeni) CI/CD ile zorlanır.

## Kapsam
### In Scope
- open_products_catalog bağlamına ait uygulama kodu, testler ve otomasyon.
- Bu servise ait OpenAPI/AsyncAPI veya şema artefaktları.
- Bu servisin çalışma zamanı operasyonları (gözlemlenebilirlik, release, rollback).

### Out of Scope
- Diğer bounded context'lerin iş kuralları ve veri sahipliği.
- Paylaşımlı DB anti-pattern'i; cross-context doğrudan tablo erişimi.
- Platform dışı gizli bilgi/anahtar yönetimi (merkezi policy dışında local hardcode).

## Mühendislik Standartları
- **TDD öncelikli** geliştirme, birim test + entegrasyon testi.
- **Clean Architecture**: Domain katmanı framework bağımsız.
- **12-Factor** ve environment-driven configuration.
- **FAPI odaklı güvenlik** (OIDC/OAuth2, mTLS, DPoP gereksinimleri ilgili servislerde).
- **PII güvenliği**: loglarda maskeleme, secret'ların source/env içine yazılmaması.

## Branching ve Release Akışı
- Uzun ömürlü branch'ler: `main`, `dev`, `staging`, `local`.
- Feature branch kuralı: `codex/<kisa-aciklama>`.
- Release yaklaşımı: PR + required status checks + tag tabanlı sürümleme.

## Dokümantasyon ve Referanslar
- [Enterprise Architecture Hub](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture)
- [Secure Microservices Architecture](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture/blob/main/docs/architecture/overview/SECURE_MICROSERVICES_ARCHITECTURE.md)
- [Service Data Ownership Matrix](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture/blob/main/docs/enterprisearchitecture/implementation-development/SERVICE_DATA_OWNERSHIP_MATRIX.md)
- [Service API Contracts Index](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture/blob/main/docs/enterprisearchitecture/implementation-development/SERVICE_API_CONTRACTS_INDEX.md)
- [Transformation Plan](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture/blob/main/docs/enterprisearchitecture/implementation-development/MICROSERVICES_TRANSFORMATION_PLAN.md)
- [Capability Map (PUML)](https://github.com/COPUR/fintechbankx-governance-architecture-enablement-enterprise-architecture/blob/main/docs/puml/service-mesh/enterprise-capability-map.puml)
- [Bu Repo Dokümantasyonu](./docs)

## Güvenlik ve Uyumluluk Notları
- Gerçek secret değerleri repo veya `.env` içinde tutulmaz.
- Secret üretim/rotasyon olayları merkezi log/SIEM'e taşınır.
- CI pipeline, anonimlik ve local-path sızıntısı kontrollerini bloklayıcı olarak çalıştırır.

## Katkı
- Katkı süreci için `CONTRIBUTING.md` ve squad runbook'ları izlenmelidir.
- PR'larda mimari kararlar ADR veya backlog referansı ile ilişkilendirilmelidir.

## Run and deploy

Service `svc-of-open-products-catalog` (artifact `open-products-catalog-service`) serves the public
product catalogue from its own PostgreSQL database
([ADR-0001](docs/architecture/decisions/ADR-0001-open-products-postgres-authority.md)).

| Task | Command |
|---|---|
| Unit and web tests (no database) | `./gradlew test` |
| Full gate incl. PostgreSQL tests and coverage | `TEST_DB_URL=jdbc:postgresql://localhost:5432/<db> TEST_DB_USERNAME=... TEST_DB_PASSWORD=... ./gradlew check` |
| Run locally with sample data | `DB_URL=jdbc:postgresql://localhost:5432/<db> DB_USERNAME=... SPRING_DATASOURCE_PASSWORD=... OPEN_PRODUCTS_SEED_ENABLED=true ./gradlew bootRun` |
| Load or update the catalogue | `db/import/import-products.sh "<conninfo>" products.csv` (format: `db/import/products.example.csv`) |
| Rehearse migration, seed and import | `PGHOST=... PGUSER=... PGPASSWORD=... scripts/migration/verify-migration.sh` |
| Container image | `docker build -t open-products-catalog-service:dev .` |
| Kubernetes | `helm upgrade --install open-products-catalog-service deploy/helm/open-products-catalog-service -n open-finance -f deploy/helm/open-products-catalog-service/values-<env>.yaml --set image.repository=... --set image.tag=<sha> --set externalSecret.remoteSecretName=<env>/open-products-catalog-service/db-app` |
| AWS resources | `deploy/terraform` (`terraform init -backend-config=environments/<env>.backend.hcl`, then plan with `environments/<env>.tfvars`) |

API port 8080, management port 8081 (`/actuator/health/{liveness,readiness}`, `/actuator/prometheus`).
Runtime settings come from the environment (`DB_URL`, `DB_USERNAME`, `SPRING_DATASOURCE_PASSWORD`,
`OIDC_ISSUER_URI`, `OIDC_JWK_SET_URI`, `OIDC_AUDIENCE`, `OPEN_PRODUCTS_SEED_ENABLED`, `TRACING_ENABLED`).
See [Deployment and Well-Architected notes](docs/architecture/DEPLOYMENT_AND_WELL_ARCHITECTED.md) and the
[extraction runbook](docs/migration/RUNBOOK-EXTRACT-of-open-products-catalog.md).

## Cell-Based Architecture

This repository participates in the FinTechBankX cell-based resilience program.

- Plan: \
- Backlog: \

<!-- cell-architecture-start -->
## Cell-Based Architecture

This repository participates in the FinTechBankX cell-based resilience program.

- Plan: docs/architecture/CELL_BASED_ARCHITECTURE_IMPLEMENTATION_PLAN.md
- Backlog: docs/project-management/CELL_ARCHITECTURE_BACKLOG_BOARD.md
<!-- cell-architecture-end -->
