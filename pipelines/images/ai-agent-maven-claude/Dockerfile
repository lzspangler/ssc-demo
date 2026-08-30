# AI coding-agent runtime -- CLAUDE CODE flavor.
# Used by: ai-generate-tests, ai-remediate-dependency when AI_AGENT=claude-code
# (the default backend). Pair with AI_PROVIDER=anthropic|gateway|bedrock|vertex.
#
# Contains: JDK 17 (javac, for Maven builds) + Maven, Node.js + Claude Code (the
# agent), git + glab + gh (SCM), jq. Base is ubi9/ubi-minimal (lean) rather than
# ubi9/openjdk-17 -- we install only the JDK + tools we actually use, dropping the
# S2I scripts and the base image's bundled Maven.
#
# The aider/Python backend lives in ../ai-agent-maven-aider -- build whichever
# matches your configured AI_AGENT and point the pipeline `agent-image` param at it.
#
# Build & push:
#   podman build -t quay.io/<org>/ai-agent-maven-claude:v1.0.0 images/ai-agent-maven-claude
#   podman push  quay.io/<org>/ai-agent-maven-claude:v1.0.0

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

USER 0

# Distinct arg name (NOT MAVEN_VERSION): podman/buildah lets a same-named host env
# var or parent-image ENV shadow a plain ARG default, which silently rewrote the
# download URL to a non-existent version (apache-maven-3.9-bin.tar.gz -> 404).
ARG MAVEN_DIST_VERSION=3.9.9
ARG GLAB_VERSION=1.48.0
ARG GH_VERSION=2.63.2

# JDK 17 WITH the compiler (javac) -- Maven needs it to build/test; ubi-minimal
# ships no JDK and the -runtime/JRE variant has no javac. Plus base tooling.
RUN microdnf install -y \
      java-17-openjdk-devel \
      git tar gzip which findutils ca-certificates jq \
    && microdnf clean all
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk
RUN test -x "${JAVA_HOME}/bin/javac" && "${JAVA_HOME}/bin/javac" -version

# Maven (pinned; ubi-minimal has none). Maven Central first (reliable/proxy-friendly),
# archive.apache.org as fallback, retries either way.
RUN set -eux; \
    for url in \
      "https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_DIST_VERSION}/apache-maven-${MAVEN_DIST_VERSION}-bin.tar.gz" \
      "https://archive.apache.org/dist/maven/maven-3/${MAVEN_DIST_VERSION}/binaries/apache-maven-${MAVEN_DIST_VERSION}-bin.tar.gz" ; do \
      if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "${url}" -o /tmp/maven.tar.gz; then break; fi; \
    done; \
    test -s /tmp/maven.tar.gz; \
    tar -xzf /tmp/maven.tar.gz -C /opt; \
    ln -s "/opt/apache-maven-${MAVEN_DIST_VERSION}/bin/mvn" /usr/local/bin/mvn; \
    rm -f /tmp/maven.tar.gz; \
    mvn -version

# --- Agent runtime: Node.js + Claude Code ---
# Node comes from the UBI AppStream (no external setup script piped to bash);
# Claude Code ships as an npm package and needs Node 18+.
RUN microdnf install -y nodejs npm \
    && microdnf clean all \
    && npm install -g @anthropic-ai/claude-code \
    && node --version \
    && claude --version

# glab (GitLab CLI) for opening MRs.
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz" \
      -o /tmp/glab.tar.gz \
    && tar -xzf /tmp/glab.tar.gz -C /usr/local bin/glab \
    && rm -f /tmp/glab.tar.gz \
    && glab --version

# gh (GitHub CLI) for opening PRs.
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
      -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && cp "/tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${ARCH}" \
    && gh --version

# Tekton runs steps as an arbitrary non-root UID in the root group; make HOME
# and the Maven repo writable by the group.
ENV HOME=/tekton/home
RUN mkdir -p /tekton/home /.m2 \
    && chgrp -R 0 /tekton/home /.m2 \
    && chmod -R g=u /tekton/home /.m2

USER 1001
