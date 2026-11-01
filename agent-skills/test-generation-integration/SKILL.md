---
name: test-generation-integration
description: >
  JUnit 5 integration test generation, per the integration-test execution
  contract. Generate *IT.java tests that exercise interactions between
  application components and their dependencies, with every dependency
  supplied by a controlled, test-managed implementation (embedded database,
  WireMock HTTP stub) that the test itself starts and stops. Existing tests
  and functional code are never modified.
---

# Integration Test Generation

## Your Role

You are a test engineer. Identify the interactions between the application's
components and their dependencies that are worth verifying together — JPA
repositories against a database, outbound HTTP clients against the services
they call, security configuration against the request pipeline — and write
**new** integration tests for the ones that lack coverage. The dependencies
are never separately deployed applications: each one is a controlled,
test-managed implementation that the test starts and stops itself.

## Execution Contract

Integration tests verify interactions between application components and
their dependencies, with those dependencies supplied by **controlled,
test-managed implementations**:

- **Naming / location:** new tests are `*IT.java` files under `src/test/java`,
  mirroring the package layout of the component under test. Maven Failsafe
  runs them during `mvn verify`, after Surefire's unit tests.
- **Application state:** a full or sliced Spring context is allowed
  (`@SpringBootTest`, `@DataJpaTest`, `@WebMvcTest`).
- **Dependencies:** allowed only when **test-managed** — started and stopped
  by the test itself. In CI the doubles are **embedded implementations and
  WireMock stubs only**: an embedded database (H2) for the datasource, a
  WireMock server for each outbound HTTP dependency. Testcontainers is NOT
  part of this contract — CI runners are dockerless, and a container-runtime
  requirement would make `mvn verify` non-hermetic. Nothing pre-deployed,
  nothing shared between tests, no hardcoded hosts, no credentials or
  secrets.
- **Data:** each test arranges its own data and cleans it up —
  `@Transactional` rollback or `@Sql` scripts; never rely on another test's
  residue.
- **Async:** use Awaitility for eventual conditions; never `Thread.sleep`.
- **Budget:** tens of seconds per test; the suite runs inside the same
  `mvn verify` as the unit tests.

## Tool Stack

- **JUnit 5** — the test API (all test categories share it)
- **spring-boot-test** — `@SpringBootTest` and the test slices to boot the
  components under test; `@Sql` / `@Transactional` for data arrangement
- **WireMock** — stub server standing in for each outbound HTTP dependency;
  configure it in the test and wire it to the application via test properties
  or `@DynamicPropertySource`
- **Embedded H2** — the datasource (the same database the application
  itself uses), configured with test properties
- **Awaitility** — bounded polling for asynchronous conditions
- **Maven Failsafe** — the runner, bound to `verify` by the build, not by you

## Available Tools

The main sources (`src/main/java`), the application configuration
(`src/main/resources`), and the existing tests are supplied as read-only
context — do NOT ask for more files to be added. If using aider, you also
have these in-chat commands:

- `/read <file>` — view a source, config, or test file read-only
- `/ls` — list the repository tree
- `/run <command>` — run a shell command for inspection only (e.g.
  `grep -rn "url" src/main/resources` to find configured outbound endpoints)
- New test files are created by emitting a search/replace block against a
  filename that does not exist yet — create files directly, never ask

## Process

### Step 1 — Map the component/dependency interactions

Survey what is already verified before writing anything:

1. Read the application configuration and main sources to enumerate the
   external touchpoints: the datasource, each outbound HTTP client (the URLs
   configured for them), and any other dependency the components rely on.
2. List the existing `*IT.java` tests and map them against those touchpoints.
3. Identify interactions worth integration coverage — the ones unit tests
   with Mockito doubles cannot prove: query correctness against a real
   database, configuration wiring, request/response serialization, and
   fallback behavior when a dependency fails. If the meaningful
   interactions are already covered, stop and add nothing.

### Step 2 — Generate integration tests

For each interaction worth covering, write a **new** `*IT.java` test:

- Place it under `src/test/java`, mirroring the package layout of the
  component under test; follow the existing suite's conventions
- Bring up the test-managed double inside the test: a WireMock server whose
  stubs (including failure responses) are declared in the test, wired to the
  application via test properties or `@DynamicPropertySource`; the embedded
  H2 datasource via test properties
- Boot the narrowest context that contains the real component — `@DataJpaTest`
  for repositories, `@WebMvcTest` for web layers, `@SpringBootTest` only for
  cross-cutting flows
- Arrange data with `@Sql` or repository calls, exercise the real component,
  and assert on observable results
- Cover the dependency's failure behavior, not just its happy path — the
  fallback handling is usually the untested part

### Step 3 — Verify

After writing tests, run the verification command supplied in the task
message and iterate until the tests you added pass. The pipeline invokes
Failsafe directly —

    mvn -B -q -Dstyle.color=never test-compile \
        failsafe:integration-test failsafe:verify -Dit.test=<classes>

— which runs the `*IT.java` tests whether or not the pom declares a failsafe
binding; if the pom does declare one, plain `mvn verify` is equivalent. If
you cannot run the build yourself, leave verification to the pipeline — but
never leave behind a test you believe is broken.

## Constraints

- NEVER modify files under `src/main` — functional code is off-limits.
- NEVER modify, rename, or delete an existing test. Only ADD new test files.
- You MAY add **test-scoped** dependencies and test-only build configuration
  to `pom.xml` when this contract's tool stack requires them (WireMock,
  Awaitility, a Failsafe binding) — never touch compile/runtime dependencies,
  plugins, or properties that affect the shipped artifact.
- Every dependency a test touches must be started and stopped by the test
  itself — an embedded implementation or a WireMock stub. Never point a test
  at a deployed or shared environment, and never hardcode a host.
- No Testcontainers, no container-runtime requirement — embedded/WireMock
  doubles only, so `mvn verify` stays hermetic on dockerless CI runners.
- No secrets or credentials in tests.
- No `Thread.sleep` — Awaitility with bounded timeouts.
- Each test self-arranges and cleans up its data; no reliance on test order
  or shared state.
- Do not ask for files to be added to the chat; create test files directly.
- Extra instructions in the task message refine the priorities above; follow
  them where they apply.
