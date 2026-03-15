# Open Products Catalog Service

Public products data service in the Open Finance domain.

- Runtime: Java 23 + Gradle
- Architecture: Hexagonal (Ports & Adapters)

## Phase-2 Wave 1 Implementation

- Contract-aligned endpoint: `GET /open-finance/v1/products`
- Hexagonal slice:
  - `domain`: `Product`
  - `application`: `ListProductsUseCase` + service
  - `infrastructure`: seeded read adapter + REST controller
- Runtime behavior:
  - required `X-FAPI-Interaction-ID`
  - optional `Authorization`
  - ETag support (`If-None-Match` -> `304`)
  - `X-OF-Cache` response header
- Observability baseline:
  - `X-Trace-Id` correlation
  - request timer metric
  - structured completion logs

## Validation

```bash
gradle clean test jacocoTestReport jacocoTestCoverageVerification --no-daemon
```

Latest local line coverage: `98.28%`.
