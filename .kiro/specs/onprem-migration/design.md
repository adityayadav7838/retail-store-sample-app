# Design Document — Retail Store On-Premises Migration with Ansible & Wazuh SIEM

## Overview

This document describes the architecture and implementation design for migrating the Retail Store Sample Application from AWS EKS to a self-hosted on-premises Kubernetes cluster. It replaces every AWS-managed component with an open-source on-premises equivalent, introduces Ansible automation for full-stack provisioning, and integrates Wazuh SIEM for security monitoring and threat detection.

The existing `terraform/` directory is left untouched. All on-premises automation lives under a new `onprem/` directory at the repository root.

---

## Architecture

### High-Level Topology

```
┌────────────────────────────────────────────────────────────────────┐
│                        On-Premises Environment                     │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │               Kubernetes Cluster (kubeadm / k3s)             │  │
│  │                                                              │  │
│  │  Namespace: retail-store                                     │  │
│  │  ┌────────┐ ┌─────────┐ ┌──────┐ ┌────────┐ ┌──────────┐     │  │
│  │  │  UI    │ │ Catalog │ │ Cart │ │ Orders │ │ Checkout │     │  │
│  │  └────────┘ └─────────┘ └──────┘ └────────┘ └──────────┘     │  │
│  │                                                              │  │
│  │  Namespace: ingress-nginx                                    │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │         NGINX Ingress Controller  ◄── MetalLB IP     │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  │                                                              │  │
│  │  Namespace: argocd                                           │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │         ArgoCD (Server + Repo Server + Redis)        │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  │                                                              │  │
│  │  Namespace: wazuh                                            │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │  Wazuh Manager │ Wazuh Indexer │ Wazuh Dashboard     │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌────────────────────────────────┐                               │
│  │  Local Registry Node           │                               │
│  │  Docker Registry v2 (:5000)    │                               │
│  └────────────────────────────────┘                               │
│                                                                   │
│  ┌────────────────────────────────┐                               │
│  │  Wazuh Agents (on every node)  │                               │
│  │  → report to Wazuh Manager     │                               │
│  └────────────────────────────────┘                               │
└────────────────────────────────────────────────────────────────────┘
                              ▲
                  Ansible Control Node (laptop/jump host)
```

### AWS → On-Prem Component Mapping

| AWS Component           | On-Prem Replacement              |
|-------------------------|----------------------------------|
| Amazon EKS              | kubeadm (multi-node) or k3s (single-node/dev) |
| Amazon ECR              | Docker Registry v2 (self-hosted) |
| AWS ALB / NLB           | MetalLB + NGINX Ingress Controller |
| AWS IAM / IRSA          | Kubernetes RBAC (no cloud IAM)   |
| AWS DynamoDB (optional) | In-memory cart (default on-prem) |
| Terraform               | Ansible Playbooks                |
| AWS CloudWatch / logs   | Wazuh SIEM (Manager + Indexer)   |
| Let's Encrypt (via ALB) | Self-signed cert or local CA     |

---

## Components and Interfaces

### 1. Ansible Project Structure

```
onprem/
├── site.yml                    # Master playbook — runs all roles in order
├── inventory/
│   ├── hosts.ini               # Node inventory (master, workers, registry)
│   └── group_vars/
│       └── all.yml             # All configurable variables in one place
├── roles/
│   ├── preflight/              # Pre-flight checks (tools, OS, connectivity)
│   ├── k8s-cluster/            # kubeadm/k3s install + cluster init
│   ├── local-registry/         # Docker Registry v2 deployment
│   ├── metallb/                # MetalLB installation + IP pool config
│   ├── nginx-ingress/          # NGINX Ingress Controller via Helm
│   ├── argocd/                 # ArgoCD install + application manifests
│   ├── build-push-images/      # Build Docker images + push to local registry
│   ├── helm-values/            # Generate on-prem values.yaml overrides
│   └── wazuh/                  # Wazuh Manager, Indexer, Dashboard, Agents
```

### 2. Kubernetes Cluster Role (`k8s-cluster`)

- Supports two modes controlled by `group_vars/all.yml`:
  - `cluster_type: kubeadm` — full multi-node HA setup
  - `cluster_type: k3s` — lightweight single-node dev setup
- Tasks: install container runtime (containerd), initialize control plane, join workers, install pod network (Flannel or Calico), copy kubeconfig to control node.

### 3. Local Registry Role (`local-registry`)

- Deploys Docker Distribution (Registry v2) as a systemd Docker container on the registry node.
- Configures each Kubernetes node's containerd `config.toml` to trust the registry as insecure (no TLS required in dev).
- Exposes registry on `<registry-node-ip>:5000`.

### 4. MetalLB Role (`metallb`)

- Installs MetalLB via Helm in `metallb-system` namespace.
- Creates `IPAddressPool` and `L2Advertisement` resources from the IP range defined in `group_vars/all.yml`.

### 5. NGINX Ingress Role (`nginx-ingress`)

- Installs `ingress-nginx` via Helm with `service.type: LoadBalancer` (MetalLB assigns the IP).
- Disables all AWS-specific service annotations from the current `addons.tf`.

### 6. ArgoCD Role (`argocd`)

- Installs ArgoCD via Helm in `--insecure` mode (no TLS at the ArgoCD level; TLS handled at ingress).
- Applies updated `argocd/projects/retail-store-project.yaml` and all five `argocd/applications/*.yaml` manifests.
- No changes to the ArgoCD manifest structure — destination server stays `https://kubernetes.default.svc`.

### 7. Build & Push Images Role (`build-push-images`)

- Builds each service Docker image from the existing `Dockerfile` in `src/<service>/`.
- Tags and pushes to `<registry-ip>:5000/retail-store-<service>:<git-sha>`.
- Generates the image tag from `git rev-parse --short HEAD`.

### 8. Helm Values Role (`helm-values`)

- Generates on-prem `values-onprem.yaml` override files for each service chart.
- The override files are NOT committed to replace the existing `values.yaml` — they are separate override files passed to ArgoCD via `helm.valueFiles`.
- Key overrides per service:

  **All services:**
  ```yaml
  image:
    repository: <registry-ip>:5000/retail-store-<service>
    pullPolicy: IfNotPresent
    tag: "<git-sha>"
  imagePullSecrets: []   # removes regcred / ECR auth
  ```

  **Cart:**
  ```yaml
  app:
    persistence:
      provider: in-memory
  ```

  **Orders:**
  ```yaml
  app:
    persistence:
      provider: in-memory
    messaging:
      provider: in-memory
  ```

  **UI:**
  ```yaml
  ingress:
    enabled: true
    className: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
    hosts:
      - host: retail-store.local
        paths:
          - path: /
            pathType: Prefix
  certManager:
    createClusterIssuer: false
  ```

### 9. Wazuh Role (`wazuh`)

#### 9.1 Wazuh Stack Deployment

Wazuh 4.x is deployed as Kubernetes workloads in the `wazuh` namespace using the official Wazuh Kubernetes manifests adapted for on-prem:

| Component        | Deployment Type  | Storage           |
|------------------|------------------|-------------------|
| Wazuh Manager    | StatefulSet      | PersistentVolume (local-path or hostPath) |
| Wazuh Indexer    | StatefulSet      | PersistentVolume  |
| Wazuh Dashboard  | Deployment       | No persistent storage needed |

#### 9.2 Wazuh Agent Deployment (per node)

- Ansible installs the Wazuh Agent package on every Kubernetes node (master + workers) using the official Wazuh apt/yum repository.
- The agent `ossec.conf` is templated by Ansible with:
  - `<server>` block pointing to Wazuh Manager's ClusterIP or NodeIP.
  - `<localfile>` blocks for:
    - `/var/log/syslog` and `/var/log/auth.log`
    - `/var/log/containers/*.log` (container stdout/stderr)
    - `/var/log/kube-apiserver-audit.log` (Kubernetes audit log)
  - `<directories>` for FIM: `/etc`, `/usr/bin`, `/usr/sbin`
- Agent auto-enrollment using the Wazuh Manager's `authd` service with a shared enrollment password.

#### 9.3 Kubernetes Audit Log Integration

- Ansible configures the kube-apiserver (in `/etc/kubernetes/manifests/kube-apiserver.yaml`) to write audit logs to `/var/log/kube-apiserver-audit.log` using an audit policy that captures:
  - All requests at `Metadata` level
  - Secrets and ConfigMaps at `Request` level
  - Pod exec and port-forward at `RequestResponse` level

#### 9.4 Wazuh RBAC

Two users created via Wazuh API post-deploy:
- `admin` — full access
- `readonly` — dashboard read-only role

#### 9.5 Wazuh Ingress

Wazuh Dashboard exposed via NGINX Ingress on `wazuh.local:80` (or HTTPS with self-signed cert).

---

## Data Models

### `group_vars/all.yml` — Central Configuration

```yaml
# Cluster
cluster_type: k3s            # or kubeadm
k8s_version: "1.28"
pod_network_cidr: "10.244.0.0/16"

# Registry
registry_ip: "192.168.1.50"
registry_port: 5000
image_tag: "latest"          # overridden dynamically from git sha

# MetalLB
metallb_ip_range: "192.168.1.200-192.168.1.220"

# ArgoCD
argocd_namespace: argocd
git_repo_url: "https://github.com/adityayadav7838/retail-store-sample-app"
git_revision: main

# Wazuh
wazuh_namespace: wazuh
wazuh_manager_ip: ""         # set to ClusterIP after deploy
wazuh_enrollment_password: "changeme"
wazuh_admin_password: "SecureAdmin@123"
wazuh_readonly_password: "SecureRead@123"

# Hostnames (add to /etc/hosts or local DNS)
retail_store_hostname: "retail-store.local"
argocd_hostname: "argocd.local"
wazuh_hostname: "wazuh.local"
```

### Ansible Inventory (`inventory/hosts.ini`)

```ini
[master]
192.168.1.10 ansible_user=ubuntu

[workers]
192.168.1.11 ansible_user=ubuntu
192.168.1.12 ansible_user=ubuntu

[registry]
192.168.1.50 ansible_user=ubuntu

[all:vars]
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_python_interpreter=/usr/bin/python3
```

---

## Error Handling

| Scenario | Handling |
|---|---|
| Node not reachable during provisioning | Ansible `failed_when` + clear error message identifying the unreachable host |
| Image push to local registry fails | Task retries 3 times with 10s delay; fails with registry URL and error in output |
| Wazuh agent fails to register | `ossec-authd` error captured; task marked failed; playbook halts for that host |
| NGINX Ingress IP not assigned (MetalLB misconfigured) | Post-install verification task checks `kubectl get svc -n ingress-nginx`; fails if EXTERNAL-IP is `<pending>` after 2 minutes |
| ArgoCD app stuck OutOfSync | Not handled by Ansible; operator resolves via ArgoCD UI |
| Pre-flight check fails (missing helm/kubectl) | `preflight` role asserts tool existence; entire playbook aborts before touching cluster |

---

## Testing Strategy

### Ansible Dry-Run
- All playbooks support `--check` mode for dry-run validation before applying changes.

### Post-Install Smoke Tests
- An Ansible `verify` role runs after deployment:
  - `kubectl get pods -n retail-store` — all 5 services Running
  - `curl http://retail-store.local` — HTTP 200 response
  - `curl http://argocd.local` — ArgoCD UI reachable
  - `curl http://wazuh.local` — Wazuh Dashboard reachable
  - `kubectl get svc -n ingress-nginx` — EXTERNAL-IP assigned (not `<pending>`)

### Wazuh Verification
- After agent install: `systemctl status wazuh-agent` on each node
- After dashboard deploy: verify agent appears as Active in Wazuh Dashboard

### Idempotency
- Each role is designed to be run multiple times without side effects (using `creates:`, `when: not already_configured`, Helm `--atomic` with existence checks).

---

## Key Design Decisions

1. **k3s vs kubeadm**: `k3s` is the default for single-machine local dev (simpler, no etcd). `kubeadm` is used for multi-node setups. Controlled by one variable.

2. **Separate `values-onprem.yaml` files**: Existing `values.yaml` files are NOT modified. On-prem overrides go into `values-onprem.yaml` per service, referenced via ArgoCD `helm.valueFiles`. This keeps the original AWS setup intact on the `main` branch and avoids merge conflicts.

3. **Wazuh in Kubernetes vs bare metal**: Wazuh Manager and Indexer run inside Kubernetes (as StatefulSets) to leverage Kubernetes persistent volumes and avoid managing a separate VM. Agents run on the OS level of each node (not in a container) to have full access to host logs and file paths.

4. **No Let's Encrypt on-prem**: `cert-manager` cluster issuer pointing to Let's Encrypt is disabled in the on-prem override. HTTP is used by default. Operators can optionally configure a self-signed CA via a separate cert-manager `ClusterIssuer`.

5. **MetalLB L2 mode**: Used because it requires no BGP router setup, making it suitable for flat local networks. Operators on networks with BGP can switch to BGP mode in `group_vars/all.yml`.
