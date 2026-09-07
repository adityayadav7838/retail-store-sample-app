# Requirements Document

## Introduction

This document defines the requirements for migrating the Retail Store Sample Application from AWS EKS to an on-premises Kubernetes cluster. The application is a microservices-based retail platform consisting of five services: UI, Catalog, Cart, Orders, and Checkout. The migration replaces all AWS-managed infrastructure (EKS, ECR, ALB, DynamoDB) with self-hosted equivalents running on local machines, and introduces Ansible playbooks to automate the provisioning and configuration of the on-premises environment.

## Glossary

- **On-Prem Cluster**: A Kubernetes cluster running locally on bare-metal or VM infrastructure (e.g., using kubeadm or k3s), not managed by a cloud provider.
- **Local Registry**: A self-hosted container image registry (e.g., Harbor or Docker Registry) that replaces AWS ECR.
- **Retail Store App**: The five-service application composed of UI, Catalog, Cart, Orders, and Checkout microservices.
- **Ansible Playbook**: An automation script written in YAML using Ansible that provisions, configures, and deploys infrastructure and applications.
- **Helm Chart**: A Kubernetes package manager template used to deploy each microservice.
- **ArgoCD**: A declarative GitOps continuous delivery tool for Kubernetes.
- **NGINX Ingress Controller**: A Kubernetes ingress controller using NGINX as the reverse proxy, replacing AWS ALB/NLB.
- **NodePort / MetalLB**: On-premises alternatives to cloud LoadBalancer services.
- **MetalLB**: A bare-metal load balancer implementation for Kubernetes.
- **kubeconfig**: A file used by kubectl to authenticate and connect to a Kubernetes cluster.
- **values.yaml**: Helm chart configuration file that overrides default chart values per environment.
- **ECR**: Amazon Elastic Container Registry — the AWS-specific container image registry used in the current deployment.
- **regcred**: Kubernetes image pull secret currently configured for ECR authentication.

---

## Requirements

### Requirement 1 — On-Premises Kubernetes Cluster Provisioning

**User Story:** As a platform engineer, I want to provision a Kubernetes cluster on local machines using Ansible, so that I can run the Retail Store App without relying on AWS EKS.

#### Acceptance Criteria

1. WHEN the Ansible playbook for cluster setup is executed, THE Cluster Provisioner SHALL install and configure a Kubernetes cluster (kubeadm or k3s) on the target hosts defined in the Ansible inventory.
2. WHEN the cluster is provisioned, THE Cluster Provisioner SHALL install kubectl, kubelet, and kubeadm (or k3s binary) at pinned versions on all target nodes.
3. IF a node fails to join the cluster during provisioning, THEN THE Cluster Provisioner SHALL output a descriptive error message identifying the failed node and the reason for failure.
4. WHEN cluster provisioning completes, THE Cluster Provisioner SHALL verify that all nodes report a Ready status within 5 minutes.
5. WHILE the cluster is being initialized, THE Cluster Provisioner SHALL configure a pod network add-on (Flannel or Calico) to enable inter-pod communication.

---

### Requirement 2 — Local Container Image Registry

**User Story:** As a platform engineer, I want to replace AWS ECR with a self-hosted container registry, so that all services pull images from a local source without AWS credentials.

#### Acceptance Criteria

1. WHEN the Ansible playbook for registry setup is executed, THE Local Registry SHALL be deployed as a Docker container or Kubernetes workload on the on-premises environment.
2. WHEN container images are built locally, THE Local Registry SHALL accept image pushes from the build host using standard Docker CLI commands.
3. WHEN a Helm chart references an image, THE Retail Store App SHALL pull images from the Local Registry address (e.g., `<registry-ip>:5000/<image>:<tag>`) instead of the AWS ECR URL.
4. IF the Local Registry is unreachable during a pod start, THEN THE Kubernetes Cluster SHALL report an `ImagePullBackOff` error with the registry address in the event log.
5. WHERE TLS is not configured for the Local Registry, THE Docker Daemon on each node SHALL be configured to treat the registry address as an insecure registry.

---

### Requirement 3 — Helm Chart Values Update for On-Premises

**User Story:** As a platform engineer, I want to update all Helm chart values files to remove AWS-specific configuration, so that the application deploys cleanly on the on-premises cluster.

#### Acceptance Criteria

1. WHEN a Helm chart is deployed on the On-Prem Cluster, THE Helm Chart SHALL reference only Local Registry image URIs (no `*.dkr.ecr.*.amazonaws.com` references).
2. WHEN deploying services, THE Helm Chart SHALL not reference AWS-specific imagePullSecrets (e.g., `regcred` backed by ECR tokens).
3. WHEN the cart service is deployed, THE Helm Chart SHALL configure the persistence provider as `in-memory` by default for on-premises use, unless an alternative is explicitly set.
4. WHEN the orders service is deployed, THE Helm Chart SHALL configure both the messaging provider and persistence provider as `in-memory` by default for on-premises use.
5. IF a Helm chart contains AWS security group annotations or IRSA service account annotations, THEN THE Helm Chart SHALL have those annotations removed or set to empty values for the on-premises deployment.

---

### Requirement 4 — NGINX Ingress and MetalLB Load Balancer

**User Story:** As a platform engineer, I want to replace AWS NLB/ALB with NGINX Ingress Controller and MetalLB, so that external traffic reaches the application on the on-premises cluster.

#### Acceptance Criteria

1. WHEN the Ansible playbook for networking is executed, THE On-Prem Cluster SHALL have NGINX Ingress Controller deployed via Helm in the `ingress-nginx` namespace.
2. WHEN MetalLB is configured, THE On-Prem Cluster SHALL assign a virtual IP address from a defined local IP pool to LoadBalancer-type services.
3. WHEN the UI service Ingress resource is applied, THE NGINX Ingress Controller SHALL route HTTP traffic to the UI service on port 80 using an IP address or local hostname.
4. IF SSL/TLS is not configured for on-premises ingress, THEN THE NGINX Ingress Controller SHALL serve the application over plain HTTP on port 80 without redirecting to HTTPS.
5. WHEN ArgoCD ingress is configured, THE NGINX Ingress Controller SHALL route traffic to the ArgoCD server without requiring a cloud-issued SSL certificate.

---

### Requirement 5 — ArgoCD GitOps Setup on On-Premises

**User Story:** As a platform engineer, I want ArgoCD to be installed and configured on the on-premises cluster, so that application deployments are managed through GitOps without AWS-specific dependencies.

#### Acceptance Criteria

1. WHEN the Ansible playbook for ArgoCD is executed, THE ArgoCD Installation SHALL deploy ArgoCD into the `argocd` namespace on the On-Prem Cluster using the official Helm chart.
2. WHEN ArgoCD applications are created, THE ArgoCD Application SHALL reference the Git repository URL and the correct Helm chart path for each service.
3. WHEN the ArgoCD project definition is applied, THE ArgoCD Project SHALL remove any AWS-specific destination server references and use `https://kubernetes.default.svc` as the cluster destination.
4. IF the Git repository is private, THEN THE ArgoCD Installation SHALL be configured with the repository credentials stored as a Kubernetes secret in the `argocd` namespace.
5. WHILE ArgoCD is running, THE ArgoCD Server SHALL be accessible via the NGINX Ingress Controller using a local hostname or IP address.

---

### Requirement 6 — Ansible Playbook for Full Stack Deployment

**User Story:** As a platform engineer, I want a single entry-point Ansible playbook that orchestrates the full on-premises setup, so that the entire environment can be reproduced with a single command.

#### Acceptance Criteria

1. WHEN the main Ansible playbook is executed, THE Ansible Playbook SHALL run roles in the following order: cluster provisioning, registry setup, networking (MetalLB + NGINX), ArgoCD, and application deployment.
2. WHEN the Ansible Playbook completes successfully, THE On-Prem Cluster SHALL have all five Retail Store App services running and passing their readiness probes.
3. IF a required tool (kubectl, helm, ansible) is missing on the control node, THEN THE Ansible Playbook SHALL fail with a clear pre-flight check error before making any changes.
4. WHEN the Ansible Playbook is executed, THE Ansible Playbook SHALL read cluster and registry configuration from a single `group_vars/all.yml` file, making environment-specific values configurable without editing playbook code.
5. WHERE idempotency is required, THE Ansible Playbook SHALL produce no changes on a second run if the environment is already in the desired state.

----

### Requirement 8 — Wazuh SIEM Integration for On-Premises Security

**User Story:** As a platform engineer, I want Wazuh SIEM deployed and integrated with the on-premises cluster and application nodes, so that security events, log ingestion, and threat detection are centralized without cloud dependencies.

#### Acceptance Criteria

1. WHEN the Ansible playbook for Wazuh is executed, THE Wazuh Manager SHALL be deployed on a dedicated node or as a Kubernetes workload in the `wazuh` namespace with persistent storage for event data.
2. WHEN the Wazuh Indexer and Dashboard components are deployed, THE Wazuh Stack SHALL expose the Wazuh Dashboard on port 443 via the NGINX Ingress Controller using a local hostname.
3. WHEN a Kubernetes worker node is provisioned, THE Ansible Playbook SHALL install the Wazuh Agent on each node and register the agent with the Wazuh Manager using the manager's IP address.
4. WHEN the Wazuh Agent is installed, THE Wazuh Agent SHALL monitor the following directories on each node: `/var/log`, `/etc`, `/usr/bin`, `/usr/sbin`, and the container runtime log directory.
5. IF a Wazuh Agent loses connectivity with the Wazuh Manager for more than 60 seconds, THEN THE Wazuh Manager SHALL mark the agent as disconnected and generate a disconnection alert.
6. WHEN Kubernetes audit logs are enabled, THE Wazuh Manager SHALL ingest Kubernetes API server audit logs to detect unauthorized API access and privilege escalation attempts.
7. WHERE the on-premises environment handles container workloads, THE Wazuh Agent SHALL be configured with Docker/container runtime log collection rules to detect anomalous container behavior.
8. WHEN the Wazuh Stack is deployed, THE Wazuh Configuration SHALL enforce role-based access control with a minimum of two roles: `admin` (full access) and `readonly` (read-only dashboard access).

---

### Requirement 7 — Terraform Replacement / Removal for On-Prem

**User Story:** As a platform engineer, I want to document and disable the AWS Terraform configuration, so that no accidental AWS resource provisioning occurs when operating in the on-premises environment.

#### Acceptance Criteria

1. WHEN operating in the on-premises environment, THE Platform Engineer SHALL use Ansible playbooks exclusively for infrastructure provisioning and SHALL NOT execute the existing Terraform scripts targeting AWS.
2. WHEN the on-premises environment is set up, THE On-Prem Configuration SHALL include a dedicated `onprem/` directory containing all Ansible roles, playbooks, and inventory files separate from the existing `terraform/` directory.
3. IF a developer accidentally runs `terraform apply` without AWS credentials configured, THEN THE Terraform Configuration SHALL fail at the authentication step before creating any resources.
