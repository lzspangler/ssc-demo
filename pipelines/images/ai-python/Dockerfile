# Anthropic Python SDK runtime for the maven-build-ci CVE selector.
# Used by: ai-select-cve.
# Contains: Python 3.11 + the `anthropic` SDK (with Bedrock/Vertex extras so the
# same image serves every AI_PROVIDER) + the `openai` SDK + jq.
#
# Base is ubi9/ubi-minimal (matching the agent images) rather than the heavier
# ubi9/python-311 builder image -- we install just python3.11 + pip.
#
# Build & push:
#   podman build -t quay.io/<org>/ai-python:v1.0.0 images/ai-python
#   podman push  quay.io/<org>/ai-python:v1.0.0
# Then set the pipeline param ai-python-image (or the default) to that reference.

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

USER 0

# ubi-minimal ships no Python; install 3.11 + pip + jq. ca-certificates is present.
RUN microdnf install -y python3.11 python3.11-pip jq && microdnf clean all

# Make `python3`/`python`/`pip` resolve to 3.11. /usr/local/bin precedes /usr/bin
# on PATH, so `#!/usr/bin/env python3` (used by the ai-select-cve step) picks up
# 3.11 -- the same interpreter the SDKs below are installed into.
RUN ln -sf /usr/bin/python3.11 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/local/bin/python \
    && ln -sf /usr/bin/pip3.11    /usr/local/bin/pip

# `bedrock` pulls boto3, `vertex` pulls google-auth; installing both keeps the
# image provider-agnostic so AI_PROVIDER can be swapped via ConfigMap alone.
# `openai` covers AI_PROVIDER=openai (gpt-oss, Granite, and any OpenAI-compatible
# vLLM/RHOAI/Ollama/watsonx endpoint).
ARG ANTHROPIC_VERSION=">=0.40,<1"
ARG OPENAI_VERSION=">=1.40"
RUN python3.11 -m pip install --no-cache-dir \
      "anthropic[bedrock,vertex]${ANTHROPIC_VERSION}" \
      "openai${OPENAI_VERSION}" \
    && python3 -c "import anthropic, openai; print('anthropic', anthropic.__version__, '| openai', openai.__version__)"

ENV HOME=/tekton/home
RUN mkdir -p /tekton/home \
    && chgrp -R 0 /tekton/home \
    && chmod -R g=u /tekton/home

USER 1001
