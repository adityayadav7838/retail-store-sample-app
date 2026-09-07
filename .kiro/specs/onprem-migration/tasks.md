# Implementation Plan — Retail Store On-Premises Migration

- [x] 1. Scaffold the Ansible project structure
  - Create the `onprem/` directory at the repo root with subdirectories: `roles/`, `inventory/`, `inventory/group_vars/`
  - Create `onprem/site.yml` as the master playbook that imports all roles in order: preflight → k8s-cluster → local-registry → metallb → nginx-ingress → argocd → build-push-images → helm-values → wazuh → verify
  - Create `onprem/inventory/hosts.ini` with placeholder groups: `[master]`, `[workers]`, `[registry]`
  - Create `onprem/inventory/group_vars/all.yml` with all configurable variables: `cluster_type`, `registry_ip`, `registry_port`, `metallb_ip_range`, `git_repo_url`, `git_revision`, hostnames, and Wazuh settings
  - _Requirements: 6.4_

- [x] 2. Implement the preflight role
  - Create `onprem/roles/preflight/tasks/main.yml`
  - Assert that `ansible`, `kubectl`, `helm`, and `docker` are present on the control node using `ansible.builtin.assert` with `which` lookups
  - Assert that all target hosts in the inventory are reachable via SSH using `ansible.builtin.ping`
  - Assert minimum OS (Ubuntu 20.04+ or RHEL 8+) and disk space (>= 20 GB free on `/`)
  - _Requirements: 6.3_

- [x] 3. Implement the k8s-cluster role
  - Create `onprem/roles/k8s-cluster/tasks/main.yml` with two include paths controlled by `cluster_type` variable: `tasks/k3s.yml` and `tasks/kubeadm.yml`
  - Create `tasks/k3s.yml`: install k3s on master using the official install script, install k3s-agent on worker nodes pointing to master URL and token, copy `/etc/rancher/k3s/k3s.yaml` to the Ansible control node as `~/.kube/config`
  - Create `tasks/kubeadm.yml`: install containerd, kubelet, kubeadm at pinned version, run `kubeadm init` on master with `--pod-network-cidr`, generate join command, run join on each worker node, install Flannel CNI via `kubectl apply`
  - Add a post-task that waits for all nodes to reach `Ready` status using `kubectl wait --for=condition=Ready node --all --timeout=300s`
  - _Requirements: 1.1, 1.2, 1.4, 1.5_

- [x] 4. Implement the local-registry role
  - Create `onprem/roles/local-registry/tasks/main.yml`
  - Deploy Docker Registry v2 as a Docker container on the registry host: `docker run -d -p 5000:5000 --restart=always --name registry registry:2`
  - Template `onprem/roles/local-registry/templates/containerd-config.toml.j2` that adds the registry host as insecure in containerd's `config.toml` under `[plugins."io.containerd.grpc.v1.cri".registry.mirrors]`
  - Apply the containerd config template to every Kubernetes node and restart containerd
  - Verify registry is reachable with `curl http://{{ registry_ip }}:{{ registry_port }}/v2/`
  - _Requirements: 2.1, 2.2, 2.5_

- [x] 5. Implement the metallb role
  - Create `onprem/roles/metallb/tasks/main.yml`
  - Add the MetalLB Helm repo and install MetalLB in `metallb-system` namespace using `kubernetes.core.helm`
  - Wait for MetalLB controller and speaker pods to be Running
  - Template and apply `IPAddressPool` and `L2Advertisement` CRDs using values from `metallb_ip_range` in `group_vars/all.yml`
  - _Requirements: 4.2_

- [x] 6. Implement the nginx-ingress role
  - Create `onprem/roles/nginx-ingress/tasks/main.yml`
  - Add the `ingress-nginx` Helm repo and install the chart in `ingress-nginx` namespace with `service.type=LoadBalancer` and all AWS-specific service annotations removed
  - Wait for the ingress controller pod to be Running and for the LoadBalancer service to receive an EXTERNAL-IP from MetalLB (poll with timeout of 120s)
  - _Requirements: 4.1, 4.3_

- [x] 7. Implement the build-push-images role
  - Create `onprem/roles/build-push-images/tasks/main.yml`
  - Register `git_sha` using `git rev-parse --short HEAD` via `ansible.builtin.command` and store as a fact
  - Loop over all five services (`ui`, `catalog`, `cart`, `orders`, `checkout`) and for each: run `docker build -t {{ registry_ip }}:{{ registry_port }}/retail-store-{{ item }}:{{ git_sha }} src/{{ item }}`, then run `docker push`
  - Store the resolved `git_sha` as a fact for use by the helm-values role
  - _Requirements: 2.2, 2.3, 3.1_

- [x] 8. Implement the helm-values role
  - Create `onprem/roles/helm-values/tasks/main.yml`
  - Create `onprem/roles/helm-values/templates/values-onprem.yaml.j2` — a Jinja2 template that generates per-service on-prem Helm override values with:
    - `image.repository` pointing to `{{ registry_ip }}:{{ registry_port }}/retail-store-{{ service_name }}`
    - `image.tag` set to `{{ git_sha }}`
    - `imagePullSecrets: []`
    - Service-specific overrides: cart `persistence.provider: in-memory`, orders `persistence.provider: in-memory` and `messaging.provider: in-memory`, UI ingress enabled with local hostname and no TLS/cert-manager
  - Write the rendered template to `src/{{ item }}/chart/values-onprem.yaml` for each service
  - Remove AWS security group annotations from catalog and orders chart values by setting `securityGroups.create: false`
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 9. Implement the argocd role
  - Create `onprem/roles/argocd/tasks/main.yml`
  - Add the ArgoCD Helm repo and install ArgoCD in `argocd` namespace with `server.extraArgs: ["--insecure"]` and `server.service.type: ClusterIP`
  - Wait for all ArgoCD pods to be Running
  - Apply `argocd/projects/retail-store-project.yaml` using `kubernetes.core.k8s`
  - Apply all five `argocd/applications/retail-store-*.yaml` manifests; update each to add `values-onprem.yaml` to `helm.valueFiles` list alongside `values.yaml`
  - Template and apply an Ingress resource for ArgoCD in `argocd` namespace using `argocd_hostname` from `group_vars/all.yml`
  - _Requirements: 5.1, 5.2, 5.3, 5.5_

- [x] 10. Implement the wazuh role
  - [x] 10.1 Deploy Wazuh stack to Kubernetes
    - Create `onprem/roles/wazuh/tasks/main.yml` that creates the `wazuh` namespace and applies Wazuh Kubernetes manifests (Manager StatefulSet, Indexer StatefulSet, Dashboard Deployment, and their Services and PVCs)
    - Use the official Wazuh Kubernetes YAML manifests from `https://github.com/wazuh/wazuh-kubernetes` adapted for on-prem (remove cloud storage class references, use `local-path` or `hostPath` as storage class)
    - Wait for Wazuh Manager, Indexer, and Dashboard pods to be Running
    - _Requirements: 8.1, 8.2_

  - [x] 10.2 Configure Wazuh Manager settings
    - Template `onprem/roles/wazuh/templates/ossec-manager.conf.j2` with: `<global>` log settings, `<auth>` enabled with enrollment password, `<ruleset>` including Docker and Kubernetes rules, and `<cluster>` disabled (single-node)
    - Apply the config to the Wazuh Manager pod via `kubectl exec` and reload the manager
    - Enable Kubernetes audit log decoder by copying the `0470-kubernetes_rules.xml` rule file into the manager
    - _Requirements: 8.6, 8.7_

  - [x] 10.3 Install and configure Wazuh agents on all nodes
    - Create `onprem/roles/wazuh/tasks/agents.yml` that installs the Wazuh agent package on every host in `[master]` and `[workers]` groups using the Wazuh apt/yum repo at the pinned version matching the manager
    - Template `onprem/roles/wazuh/templates/ossec-agent.conf.j2` with: `<server>` block (Wazuh Manager IP), `<localfile>` blocks for syslog, auth.log, container logs (`/var/log/containers/*.log`), and kube-apiserver audit log, `<directories>` FIM blocks for `/etc`, `/usr/bin`, `/usr/sbin`
    - Start and enable the `wazuh-agent` systemd service on each node
    - _Requirements: 8.3, 8.4, 8.7_

  - [x] 10.4 Configure Kubernetes audit logging
    - Template `onprem/roles/wazuh/templates/audit-policy.yaml.j2` — Kubernetes audit policy capturing Metadata level for all resources, Request level for Secrets/ConfigMaps, RequestResponse level for exec/port-forward
    - Copy audit policy to `/etc/kubernetes/audit-policy.yaml` on the master node
    - Patch `/etc/kubernetes/manifests/kube-apiserver.yaml` to add `--audit-log-path=/var/log/kube-apiserver-audit.log`, `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`, and mount the log path as a hostPath volume (k3s: patch via k3s config)
    - _Requirements: 8.6_

  - [x] 10.5 Create Wazuh RBAC users
    - After Wazuh Dashboard is Running, use the Wazuh API (via `ansible.builtin.uri`) to create `admin` user with full access role and `readonly` user with the built-in `readonly` role
    - Store credentials securely using Ansible Vault references from `group_vars/all.yml`
    - _Requirements: 8.8_

  - [x] 10.6 Create Wazuh Dashboard Ingress
    - Apply a Kubernetes Ingress resource routing `wazuh_hostname` to the Wazuh Dashboard service on port 443 via NGINX Ingress Controller
    - _Requirements: 8.2_

- [x] 11. Implement the verify role
  - Create `onprem/roles/verify/tasks/main.yml` with post-deployment smoke tests:
    - Assert all pods in `retail-store` namespace are in Running state using `kubectl get pods -n retail-store`
    - Assert `curl http://{{ retail_store_hostname }}` returns HTTP 200
    - Assert `curl http://{{ argocd_hostname }}` returns HTTP 200 or 302
    - Assert NGINX Ingress LoadBalancer service has a non-pending EXTERNAL-IP
    - Assert Wazuh Manager pod is Running in `wazuh` namespace
  - Print a summary of all hostnames and their assigned IPs at the end of the play
  - _Requirements: 6.2_

- [x] 12. Update ArgoCD application manifests to include on-prem value files
  - Modify each `argocd/applications/retail-store-*.yaml` to add `values-onprem.yaml` to the `helm.valueFiles` list so ArgoCD uses the on-prem overrides alongside the base `values.yaml`
  - This change is applied conditionally by the argocd Ansible role (task 9), but commit the updated manifests so they are version-controlled
  - _Requirements: 3.1, 3.2, 5.2_
