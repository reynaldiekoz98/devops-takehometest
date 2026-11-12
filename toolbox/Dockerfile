# syntax=docker/dockerfile:1
# Toolbox: everything the scripts need, so the reviewer's host only needs Docker.
FROM debian:12-slim
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.35.10
ARG HELM_VERSION=v4.3.1
ARG K3D_VERSION=v5.9.0
ARG TERRAFORM_VERSION=1.17.2
ARG K6_VERSION=v2.3.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq unzip gettext-base \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSLo /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${TARGETARCH}"; \
    chmod +x /usr/local/bin/kubectl /usr/local/bin/k3d; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar xz -C /tmp; \
    mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm; \
    curl -fsSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    unzip -q /tmp/tf.zip -d /usr/local/bin terraform; \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${TARGETARCH}.tar.gz" | tar xz -C /tmp; \
    mv /tmp/k6-${K6_VERSION}-linux-${TARGETARCH}/k6 /usr/local/bin/k6; \
    rm -rf /tmp/*

ENV KUBECONFIG=/kube/config TOOLBOX=1
WORKDIR /work
CMD ["sleep", "infinity"]
