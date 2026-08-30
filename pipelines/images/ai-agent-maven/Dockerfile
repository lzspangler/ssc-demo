# AI coding-agent runtime for the maven-build-ci remediation branch.
# Used by: ai-generate-tests, ai-remediate-dependency.
# Contains: JDK 17 + Maven (build/test), Node.js + Claude Code (the agent),
# git + glab + gh (SCM), jq (JSON wrangling).
#
# Build & push:
#   podman build -t quay.io/<org>/ai-agent-maven:latest images/ai-agent-maven
#   podman push  quay.io/<org>/ai-agent-maven:latest
# Then set the pipeline param agent-image (or the default) to that reference.

FROM registry.access.redhat.com/ubi9/openjdk-17:latest

USER 0

ARG MAVEN_VERSION=3.9.9
ARG NODE_MAJOR=20
ARG GLAB_VERSION=1.48.0
ARG GH_VERSION=2.63.2

# Base tooling: git, jq, tar/gzip for release tarballs.
RUN microdnf install -y git tar gzip which findutils ca-certificates \
    && microdnf clean all

# Maven (pin a known version rather than relying on the base image's).
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o /tmp/maven.tar.gz \
    && tar -xzf /tmp/maven.tar.gz -C /opt \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
    && rm -f /tmp/maven.tar.gz

# Node.js (Claude Code ships as an npm package and needs a Node runtime).
RUN curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && microdnf install -y nodejs \
    && microdnf clean all \
    && npm install -g @anthropic-ai/claude-code \
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
