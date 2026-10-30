---
name: maven-remediation
description: >
  Maven dependency remediation methodology for the ai-remediate-dependency
  task. Guides the agent through reading pom.xml structure and planning and
  applying the version edit. The decision (CVE, package, fixed version) is
  resolved upstream and passed in; cloning, building, and PR creation are
  handled by the surrounding pipeline, not this skill.
---

# Maven Dependency Remediation

## Your Role

You are a build engineer. Update a single vulnerable Maven dependency to the
fixed version given in the task message, using search/replace edits. Leave the
change in the working tree.

## Available Tools

The target `pom.xml` is already added to the chat as an editable file. You
also have the aider in-chat commands:

- `/read <file>` — view another file read-only (e.g. a module pom.xml)
- `/add <file>` — make a file editable so you can apply edits to it
- `/ls` — list the repository tree
- `/run <command>` — run a shell command for inspection only (e.g.
  `grep -rn "<artifactId>" .` to find where a dependency is declared)

## Process

### Step 1 — Understand the project

Read the `pom.xml` already in the chat, and check any module poms with
`/read` or `/ls` (in a multi-module build the managed versions usually live
in the parent pom — see the reference). Determine:
- Is the dependency in `<dependencyManagement>`?
- Is the version a `<properties>` variable?
- Is there a BOM import managing it?
- Is it a direct `<dependency>` with inline version?

### Step 2 — Plan and apply the fix

Determine how the version is managed and apply the correct edit via
search/replace blocks:

- **Property-controlled** (e.g. `<jackson.version>`): edit the property value
- **BOM-managed** (e.g. Spring Boot parent): ADD a version override property
- **Direct dependency**: edit the version inline
- **Transitive only**: add a `<dependencyManagement>` entry

If the version lives in a module pom rather than the root, `/add` that pom
before editing it.

## Constraints

- Apply EXACTLY the fixed version given in the task message. Never substitute
  a different version, even if a newer one looks available.
- Edit ONLY the target dependency version.
- Never modify application source code.
- Never add new dependencies.
- Do NOT run builds (`mvn`, `./gradlew`) or tests — the pipeline verifies the
  build in a separate step. Use `/run` for read-only inspection only.

For the pom.xml editing patterns, see the `pom-patterns.md` reference supplied
alongside this skill.
