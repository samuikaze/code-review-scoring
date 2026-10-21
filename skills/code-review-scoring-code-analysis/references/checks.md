# Checklist (A–G)

Format: id | what to look for | default severity | condition that allows a different severity.
Only the written condition may change a severity.

Dimensions: A Correctness, B Security, C Test quality, D Architecture and design, E Performance and resource use,
F Readability, G Maintainability. Their points and the deduction per severity are settings of the scoring step
(`configs.ini`); they do not change which checks apply or which severity a finding gets.

## A. Correctness

- A1 | Edge cases not handled: null, empty collections, `Optional.get()` without a check, numeric overflow | Major
- A2 | Money calculated without `BigDecimal` (e.g. `double`, `float`) | Critical
- A3 | `@Transactional` on a private method, or a method in the same class calling its own `@Transactional` method, so the proxy is bypassed | Major
- A4 | Method throws a checked exception and is `@Transactional` without `rollbackFor` | Major
- A5 | Swallowed exception: `catch` only logs or does nothing, or rethrows without keeping the original cause | Major
- A6 | Concurrency: shared mutable state in a singleton bean, an obvious race condition, or updates to shared data without optimistic locking (`@Version`) or another lock | Critical
- A7 | `Date` / `Calendar` used, or no explicit time zone | Minor | Major when the PR description or spec clearly involves cross-timezone business
- A8 | Implementation differs from the SD spec or PR description, and the spec is clear on that point | Major | Without an SD spec, compare against the PR description only

## B. Security

- B1 | Hard-coded password, token or key in code or configuration | Critical
- B2 | SQL injection risk: string-concatenated JPQL or native queries, or parameters concatenated in `@Query` | Critical
- B3 | Added or changed API endpoint without authentication or authorization, or resource access without an ownership check (IDOR) | Critical
- B4 | Controller parameter without `@Valid`, or DTO without `jakarta.validation` annotations | Major
- B5 | CSRF protection disabled without a comment or PR description explaining why | Major
- B6 | `permitAll()` on a path pattern clearly wider than needed (e.g. `/**`, `/api/**`) | Major
- B7 | Logs contain personal data, tokens or the full request body, or error responses contain stack traces | Major
- B8 | CORS `allowedOrigins("*")` together with allowed credentials | Major
- B9 | Newly added dependency has a known CVE | Major | Evaluate only when a vulnerability scan was provided

## C. Test quality

- C1 | Added or changed business logic without a matching unit test | Major | Critical when the PR changes business logic but touches no test file at all
- C2 | Tests cover only the happy path, not exceptions and edge cases | Major
- C3 | Tests without meaningful assertions, or only `assertNotNull` | Major
- C4 | Controller or Repository tests use `@SpringBootTest` instead of `@WebMvcTest` / `@DataJpaTest` | Minor
- C5 | DB tests use H2 while the tested query uses production-database-specific syntax (suggest Testcontainers) | Minor
- C6 | Tests depend on each other or on execution order, or use `Thread.sleep` | Minor
- C7 | Test method name does not show the scenario and the expected result | Minor

## D. Architecture and design

- D1 | Controller calls a Repository directly, or business logic sits in a Controller or Entity Listener | Major
- D2 | JPA entity used directly as API request or response | Major | Critical when the entity has sensitive fields (password hash, internal IDs, personal data)
- D3 | One class or method has several unrelated responsibilities (God Service), or clearly violates SOLID | Major
- D4 | Field injection (`@Autowired` on a field) instead of constructor injection | Minor
- D5 | Error handling not done through `@RestControllerAdvice` and `ProblemDetail` (RFC 9457), or response format differs from the existing convention | Minor
- D6 | `javax.*` namespace where Spring Boot 3 needs `jakarta.*` (JDK packages such as `javax.crypto` are fine) | Minor

## E. Performance and resource use

- E1 | JPA N+1: lazy loading or per-item queries inside a loop (suggest `@EntityGraph` or fetch join) | Major
- E2 | Query without paging that loads a whole table | Minor | Major when the PR description, spec or table name shows continuously growing data (transactions, orders, logs, …)
- E3 | External API called inside a `@Transactional` scope | Major
- E4 | External call without timeout, retry or circuit breaker | Major
- E5 | Stream, file, connection or other resource not closed with try-with-resources or equivalent | Major
- E6 | Association uses `FetchType.EAGER` with no visible need | Minor
- E7 | New query condition column has no index in the same PR's migration and no explanation | Minor

## F. Readability

- F1 | Method longer than 50 lines, or nesting deeper than 3 levels | Minor
- F2 | Name does not express its purpose, or breaks the naming convention used elsewhere in the same diff | Minor
- F3 | Unnamed magic number or meaningful string literal | Minor
- F4 | Complex logic without a comment explaining why it is written that way | Minor
- F5 | Commented-out code left behind, or `System.out.println` | Minor

## G. Maintainability

- G1 | The same logic appears two or more times in the diff and could be shared but is not | Major
- G2 | Value that belongs in configuration is hard-coded, or scattered new `@Value` instead of `@ConfigurationProperties` | Minor
- G3 | Wrong log level (e.g. `ERROR` for normal flow), or string concatenation instead of SLF4J placeholders | Minor
- G4 | New public API without OpenAPI annotations | Minor | Evaluate only when springdoc is visible in the diff or existing code
- G5 | TODO without an issue number | Minor
- G6 | Existing DB migration (Flyway / Liquibase) modified, or destructive schema change without explanation | Major
