FROM alpine:3.20

# Rebuild 2026-04-19 — previous :latest index referenced missing blobs (404 on 98f718c8 / 27d5ab83)

# Pin versions to match CI requirements
ARG TERRAFORM_VERSION=1.5.7
ARG TERRAGRUNT_VERSION=0.99.4
ARG SOPS_VERSION=3.9.4
ARG KUBECTL_VERSION=1.34.0

# Install system packages (single layer)
RUN apk add --no-cache \
    bash curl git git-crypt jq openssh-client openssl unzip \
    && rm -rf /var/cache/apk/*

# Terraform
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && terraform version

# Terragrunt
RUN curl -fsSL "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64" \
    -o /usr/local/bin/terragrunt \
    && chmod +x /usr/local/bin/terragrunt \
    && terragrunt --version

# SOPS (for state encryption)
RUN curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Provider cache directory (shared across stacks)
ENV TF_PLUGIN_CACHE_DIR=/tmp/terraform-plugin-cache
ENV TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1
RUN mkdir -p /tmp/terraform-plugin-cache

WORKDIR /workspace
