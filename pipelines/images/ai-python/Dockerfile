# Anthropic Python SDK runtime for the maven-build-ci CVE selector.
# Used by: ai-select-cve.
# Contains: Python 3 + the `anthropic` SDK (with Bedrock/Vertex extras so the
# same image serves every AI_PROVIDER) + jq.
#
# Build & push:
#   podman build -t quay.io/<org>/ai-python:latest images/ai-python
#   podman push  quay.io/<org>/ai-python:latest
# Then set the pipeline param ai-python-image (or the default) to that reference.

FROM registry.access.redhat.com/ubi9/python-311:latest

USER 0
RUN microdnf install -y jq ca-certificates && microdnf clean all

# `bedrock` pulls boto3, `vertex` pulls google-auth; installing both keeps the
# image provider-agnostic so AI_PROVIDER can be swapped via ConfigMap alone.
# `openai` covers AI_PROVIDER=openai (gpt-oss, Granite, and any OpenAI-compatible
# vLLM/RHOAI/Ollama/watsonx endpoint).
ARG ANTHROPIC_VERSION=">=0.40,<1"
ARG OPENAI_VERSION=">=1.40"
RUN pip install --no-cache-dir \
      "anthropic[bedrock,vertex]${ANTHROPIC_VERSION}" \
      "openai${OPENAI_VERSION}" \
    && python -c "import anthropic, openai; print('anthropic', anthropic.__version__, '| openai', openai.__version__)"

ENV HOME=/tekton/home
RUN mkdir -p /tekton/home \
    && chgrp -R 0 /tekton/home \
    && chmod -R g=u /tekton/home

USER 1001
