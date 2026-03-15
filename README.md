# Open Products Catalog Service

Public Open Finance catalog service for product discovery.

- Runtime: Java 23 + Gradle
- Architecture: Hexagonal (Ports & Adapters)
- Domain: Open Data / Product Catalog

## Implemented Slice (Wave 1)

Endpoint:

- `GET /open-finance/v1/products`

Capabilities:

- Filter by `type` and `segment`
- Public endpoint (`security: []`) with mandatory `X-FAPI-Interaction-ID`
- ETag support with `If-None-Match` -> `304 Not Modified`
- Standardized error response for invalid requests

## Package Layout

- `domain`: entities/value objects, query model, ports
- `application`: use-case implementation
- `infrastructure/persistence`: adapter with seeded catalog data
- `infrastructure/web`: REST controller + DTO + exception handling

## Test Coverage

Includes:

- Domain and application unit tests
- Controller tests
- Integration tests
- Contract test for OpenAPI alignment
- UAT-style ETag flow test

Coverage gate target: `>=85%` line coverage (JaCoCo)
