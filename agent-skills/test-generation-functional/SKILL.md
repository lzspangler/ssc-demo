---
name: test-generation-functional
description: >
  JUnit 5 + REST Assured functional test generation, per the functional-test
  execution contract. Generate *FT.java tests that verify the behavior of the
  DEPLOYED application (the built container image) through its service
  interface, without depending on external applications and without
  inspecting the application's internals. Existing tests and functional code
  are never modified.
---

# Functional Test Generation

## Your Role

You are a test engineer. Read the application's service interface — its
OpenAPI specification — and write **new** functional tests that verify the
deployed application's behavior through that interface alone: request in,
response out. These are black-box tests of the artifact that actually ships
(the container image), so they catch what in-process tests cannot: a wrong
port, broken runtime configuration, missing health wiring, packaging errors.

## Execution Contract

Functional tests verify the behavior of a **deployed application through its
service interface**, without depending on external applications:

- **Naming / location:** new tests are `*FT.java` files under `src/test/java`
  (or a dedicated `functional-tests` module). Maven Failsafe runs them under
  the `functional` profile: `mvn -Pfunctional verify`.
- **Target:** the built container image, deployed and healthy — NOT the boot
  jar and NOT an in-process `@SpringBootTest`. The pipeline deploys the
  image, waits for `GET /actuator/health` to report UP, and hands the tests
  the base URL.
- **Dependencies:** the deployed application only. No test-managed stubs, and
  no external applications — the deployed configuration must not require
  them (an application that degrades gracefully when egress is unavailable
  satisfies this by design).
- **Black box:** arrange and assert through the service interface only. No
  database assertions, no actuator state inspection (the health check itself
  is the pipeline's job, not a test's), no white-box peeking at internals.
- **Data:** each test creates the data it needs through the API (POST then
  GET) and assumes nothing about other tests, their order, or leftover state.
- **Budget:** minutes bounded by the deploy; each test itself stays in
  seconds.

## Tool Stack

- **JUnit 5** — the test API (all test categories share it)
- **REST Assured** — URL-driven API testing; a shared `RequestSpecBuilder`
  sets the base URL and the authentication once for the whole suite
- **JSONassert / OpenAPI schema validation** — response-body conformance
  against the published contract
- **Maven Failsafe** — the runner, under the `functional` profile

## Inputs

- The **OpenAPI specification** (`openapi.yaml`) — the machine-readable
  service interface, supplied as read-only context
- **`APP_BASE_URL`** — base URL of the deployed application, from the
  environment; never hardcode a host
- **`APP_USERNAME` / `APP_PASSWORD`** (or an equivalent token variable) —
  credentials for the application's security layer, when it has one

## Available Tools

The OpenAPI spec and the main sources are supplied as read-only context — do
NOT ask for more files to be added. If using aider, you also have these
in-chat commands:

- `/read <file>` — view the spec, a source file, or an existing test
  read-only
- `/ls` — list the repository tree
- `/run <command>` — run a shell command for inspection only; if the
  application is reachable, read-only probes (e.g.
  `curl -s "$APP_BASE_URL/actuator/health"`) help confirm response shapes —
  never mutate application state from a probe
- New test files are created by emitting a search/replace block against a
  filename that does not exist yet — create files directly, never ask

## Process

### Step 1 — Read the service interface

1. Read the OpenAPI spec: paths, operations, request/response schemas,
   documented status codes, and security schemes.
2. List existing `*FT.java` tests (if any) and map them against the spec's
   operations.
3. Identify behaviors worth covering: the core business operations, the
   documented error responses (4xx), the security behavior (unauthenticated
   access rejected), and representative schema conformance. If the meaningful
   behaviors are already covered, stop and add nothing.

### Step 2 — Generate functional tests

For each behavior worth covering, write a **new** `*FT.java` test:

- Follow the existing suite's conventions (naming, base classes, spec setup)
- Build requests with REST Assured against `APP_BASE_URL`, authenticating
  with the credentials from the environment when the interface requires it
- Arrange data through the API (create the resource with POST), act, then
  assert on the response: status, headers, and body conformance to the
  documented schema
- Also assert the documented error behavior — invalid input and
  unauthenticated requests — not just happy paths

### Step 3 — Verify

After writing tests, run `mvn -B -q -Dstyle.color=never -Pfunctional verify`
with `APP_BASE_URL` pointing at the deployed application, and iterate until
the tests you added pass. If you cannot run the build yourself, leave
verification to the pipeline — but never leave behind a test you believe is
broken.

## Constraints

- NEVER modify files under `src/main` — functional code is off-limits.
- NEVER modify, rename, or delete an existing test. Only ADD new test files.
- Black box only: no database, actuator-internals, or log assertions — the
  service interface is the only observation point.
- Never depend on an external application, and never hardcode a host —
  `APP_BASE_URL` is the only address a test may target.
- Each test is self-contained: it creates its own data via the API and
  assumes nothing about prior tests or their order.
- Do not ask for files to be added to the chat; create test files directly.
- Extra instructions in the task message refine the priorities above; follow
  them where they apply.
