#!/bin/bash
# Kompose to Ansible workflow for K3s deployments
# Converts Docker Compose to K8s manifests and generates complete Ansible integration files
# Architecture: MetalLB LoadBalancer + Traefik Ingress + Caddy TLS termination

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${1:-compose.yml}"
APP_NAME="${2:-homepage}"
DOMAIN="${3:-${APP_NAME}.levangie.org}"
ANSIBLE_ROLES_DIR="${4:-${SCRIPT_DIR}/../ansible/roles/k3s-apps}"

echo "🏗️  Kompose to Ansible K3s Generator"
echo "===================================="
echo "📁 Compose file: $COMPOSE_FILE"
echo "🏷️  Application: $APP_NAME"
echo "🌐 Domain: $DOMAIN"
echo "📂 Ansible roles dir: $ANSIBLE_ROLES_DIR"
echo ""

# Convert with Kompose for reference
TEMP_DIR="./temp-k8s-manifests"
mkdir -p "$TEMP_DIR"

echo "🚀 Converting with Kompose (for reference)..."
kompose convert \
  -f "$COMPOSE_FILE" \
  -o "$TEMP_DIR" \
  --volumes hostPath \
  --controller deployment \
  --namespace "$APP_NAME" \
  --with-kompose-annotation=false

echo "✅ Reference conversion complete!"

# Extract image and port from original compose file or Kompose output
IMAGE=$(grep -E "^\s*image:" "$COMPOSE_FILE" | head -1 | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'")
PORT=$(grep -E "containerPort.*" "$TEMP_DIR"/*deployment*.yaml | head -1 | sed 's/.*containerPort:\s*//' | tr -d ' ')

# Create Ansible task file
echo ""
echo "📝 Generating Ansible task file: ${ANSIBLE_ROLES_DIR}/tasks/${APP_NAME}.yml"
cat > "${ANSIBLE_ROLES_DIR}/tasks/${APP_NAME}.yml" << EOF
---
# ${APP_NAME} Dashboard Deployment
# Converted from Docker Compose using Kompose as base, enhanced for production K3s

- name: Display ${APP_NAME} deployment info
  debug:
    msg: |
      🏠 ${APP_NAME} Dashboard Deployment:
      Using host path volumes with NFS backing
      - Host paths: /mnt/k3s-storage/apps/${APP_NAME}
      - Service User: {{ vault_nfs_username | default('k3s-app-user') }}
      - App URL: {{ ${APP_NAME}_app_url | default('https://${DOMAIN}') }}
      {% if ${APP_NAME}_force_redeploy | default(false) | bool %}
      🔄 Force redeploy mode: ON (will clean up existing deployment first)
      {% endif %}
  when: inventory_hostname == groups['k3s_master'][0]

# Optional cleanup task
- name: Clean up existing ${APP_NAME} deployment (if requested)
  block:
    - name: Check if ${APP_NAME} namespace exists for cleanup
      shell: |
        kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get namespace ${APP_NAME}
      register: cleanup_namespace_check
      ignore_errors: yes

    - name: Remove existing ${APP_NAME} deployment
      shell: |
        echo "🧹 Cleaning up existing ${APP_NAME} deployment..."
        kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml delete namespace ${APP_NAME} --ignore-not-found=true
        echo "Waiting for namespace deletion to complete..."
        kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml wait --for=delete namespace/${APP_NAME} --timeout=300s || true
        echo "✅ Cleanup complete"
      when: cleanup_namespace_check.rc == 0
  when: 
    - inventory_hostname == groups['k3s_master'][0]
    - ${APP_NAME}_force_redeploy | default(false) | bool

- name: Check if ${APP_NAME} namespace exists
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get namespace ${APP_NAME}
  register: namespace_check
  ignore_errors: yes
  when: inventory_hostname == groups['k3s_master'][0]

- name: Create ${APP_NAME} namespace if needed
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml create namespace ${APP_NAME}
  when: 
    - inventory_hostname == groups['k3s_master'][0]
    - namespace_check.rc != 0

- name: Get k3s-app-user UID and GID from system
  shell: |
    id -u {{ vault_nfs_username }} 2>/dev/null
  register: nfs_user_uid_result
  when: inventory_hostname == groups['k3s_master'][0]

- name: Get k3s-app-user GID from system  
  shell: |
    id -g {{ vault_nfs_username }} 2>/dev/null || echo "100"
  register: nfs_user_gid_result
  when: inventory_hostname == groups['k3s_master'][0]

- name: Set NFS user UID/GID for host path permissions
  set_fact:
    dynamic_nfs_uid: "{{ nfs_user_uid_result.stdout | default('1024') }}"
    dynamic_nfs_gid: "{{ nfs_user_gid_result.stdout | default('100') }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Create ${APP_NAME} storage directories on NFS
  file:
    path: "/mnt/k3s-storage/apps/${APP_NAME}/config"
    state: directory
    owner: "{{ vault_nfs_username | default('k3s-app-user') }}"
    group: "users"
    mode: '0755'
    recurse: yes
  when: inventory_hostname == groups['k3s_master'][0]

- name: Apply ${APP_NAME} namespace
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', '${APP_NAME}/namespace.yaml.j2') }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Apply ${APP_NAME} ConfigMap
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', '${APP_NAME}/configmap.yaml.j2') }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Apply ${APP_NAME} PV/PVC
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', '${APP_NAME}/pv-pvc.yaml.j2') }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Apply ${APP_NAME} Deployment
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', '${APP_NAME}/deployment.yaml.j2') }}"
  when: inventory_hostname == groups['k3s_master'][0]
  register: ${APP_NAME}_deploy_result

- name: Apply ${APP_NAME} Service
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', '${APP_NAME}/service.yaml.j2') }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Apply ${APP_NAME} Ingress
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f -
  args:
    stdin: "{{ lookup('template', 'common/ingress.yaml.j2') }}"
  vars:
    service_name: "{{ ${APP_NAME}_service_name }}"
    app_url: "{{ ${APP_NAME}_app_url }}"
    service_port: "{{ ${APP_NAME}_service_port }}"
  when: inventory_hostname == groups['k3s_master'][0]

- name: Wait for ${APP_NAME} deployment to be ready
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml wait --for=condition=available --timeout=300s deployment/${APP_NAME} -n ${APP_NAME}
  when: inventory_hostname == groups['k3s_master'][0]
  register: ${APP_NAME}_ready_result

- name: Get ${APP_NAME} service status
  shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get svc,pods -n ${APP_NAME} -o wide
  register: ${APP_NAME}_status
  when: inventory_hostname == groups['k3s_master'][0]

- name: Display ${APP_NAME} deployment results
  debug:
    msg: |
      🏠 ${APP_NAME} Dashboard Deployment Results:
      {% if ${APP_NAME}_deploy_result.rc == 0 %}
      ✅ Deployment successful
      📝 Namespace: ${APP_NAME}
      🌐 Service URL: {{ ${APP_NAME}_app_url | default('https://${DOMAIN}') }}
      📦 Storage: /mnt/k3s-storage/apps/${APP_NAME}
      👤 Running as: {{ vault_nfs_username | default('k3s-app-user') }} ({{ dynamic_nfs_uid }}:{{ dynamic_nfs_gid }})
      
      📊 Service Status:
      {{ ${APP_NAME}_status.stdout }}
      {% else %}
      ❌ Deployment failed
      Error: {{ ${APP_NAME}_deploy_result.stderr }}
      {% endif %}
  when: inventory_hostname == groups['k3s_master'][0]
EOF

echo "✅ Task file created: ${ANSIBLE_ROLES_DIR}/tasks/${APP_NAME}.yml"

# Create Ansible template directory and files
echo ""
echo "� Creating template directory: ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/"
mkdir -p "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}"

echo "�📝 Generating modular Ansible templates..."

# Create namespace template
cat > "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/namespace.yaml.j2" << EOF
---
# ${APP_NAME} Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NAME}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: ansible
EOF

# Create configmap template
cat > "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/configmap.yaml.j2" << EOF
---
# ${APP_NAME} ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
  namespace: ${APP_NAME}
data:
  TZ: "{{ ${APP_NAME}_timezone | default('America/New_York') }}"
  PUID: "{{ dynamic_nfs_uid | default('1024') }}"
  PGID: "{{ dynamic_nfs_gid | default('100') }}"
EOF

# Create PV/PVC template
cat > "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/pv-pvc.yaml.j2" << EOF
---
# ${APP_NAME} PersistentVolume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${APP_NAME}-config-pv
  namespace: ${APP_NAME}
spec:
  capacity:
    storage: 1Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  hostPath:
    path: /mnt/k3s-storage/apps/${APP_NAME}/config
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/os
          operator: In
          values:
          - linux
---
# ${APP_NAME} PersistentVolumeClaim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP_NAME}-config-pvc
  namespace: ${APP_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
EOF

# Create deployment template
cat > "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/deployment.yaml.j2" << EOF
---
# ${APP_NAME} Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${APP_NAME}
  labels:
    app: ${APP_NAME}
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/component: dashboard
spec:
  replicas: 1
  strategy:
    type: Recreate  # Important for persistent storage
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        app.kubernetes.io/name: ${APP_NAME}
        app.kubernetes.io/component: dashboard
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      securityContext:
        runAsUser: {{ dynamic_nfs_uid | default('1024') }}
        runAsGroup: {{ dynamic_nfs_gid | default('100') }}
        fsGroup: {{ dynamic_nfs_gid | default('100') }}
      containers:
      - name: ${APP_NAME}
        image: ${IMAGE}
        imagePullPolicy: Always
        envFrom:
        - configMapRef:
            name: ${APP_NAME}-config
        ports:
        - containerPort: ${PORT}
          protocol: TCP
          name: http
        volumeMounts:
        - name: ${APP_NAME}-config
          mountPath: /app/config
        # Resource limits (production ready)
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 128Mi
        # Health checks
        livenessProbe:
          httpGet:
            path: /
            port: ${PORT}
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: ${PORT}
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        securityContext:
          runAsNonRoot: true
          runAsUser: {{ dynamic_nfs_uid | default('1024') }}
          runAsGroup: {{ dynamic_nfs_gid | default('100') }}
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false
      restartPolicy: Always
      volumes:
      - name: ${APP_NAME}-config
        persistentVolumeClaim:
          claimName: ${APP_NAME}-config-pvc
EOF

# Create service template
cat > "${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/service.yaml.j2" << EOF
---
# ${APP_NAME} Service
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${APP_NAME}
  labels:
    app: ${APP_NAME}
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/component: dashboard
spec:
  type: LoadBalancer  # Use MetalLB LoadBalancer
  ports:
  - name: http
    port: ${PORT}
    targetPort: ${PORT}
    protocol: TCP
  selector:
    app: ${APP_NAME}
EOF

# No longer creating individual ingress template - using common/ingress.yaml.j2
echo "ℹ️  Using common ingress template instead of app-specific template"

echo "✅ Modular templates created:"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/namespace.yaml.j2"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/configmap.yaml.j2"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/pv-pvc.yaml.j2"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/deployment.yaml.j2"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/service.yaml.j2"
echo "   - ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/ingress.yaml.j2"

# Create deployment playbook
echo ""
echo "📝 Generating deployment playbook: ${APP_NAME}.yml"
cat > "${APP_NAME}.yml" << EOF
---
# ${APP_NAME} deployment playbook
# Deploy ${APP_NAME} to K3s cluster using Ansible

- name: Deploy ${APP_NAME} to K3s
  hosts: k3s_cluster
  become: yes
  vars:
    deploy_${APP_NAME}: true
    ${APP_NAME}_app_url: "https://${DOMAIN}"
    ${APP_NAME}_service_name: "${APP_NAME}"
    ${APP_NAME}_service_port: ${PORT}
    ${APP_NAME}_timezone: "America/New_York"
    ${APP_NAME}_force_redeploy: false  # Set to true to force cleanup and redeploy
  
  roles:
    - k3s-apps

  post_tasks:
    - name: Display deployment completion
      debug:
        msg: |
          🎉 ${APP_NAME} deployment complete!
          🌐 URL: https://${DOMAIN}
          📋 Check status: kubectl get all -n ${APP_NAME}
          
          🔧 Add to your Caddyfile:
          bsk3.levangie.org, ${DOMAIN} {
              reverse_proxy 172.20.20.200:80 {
                  header_up Host {http.request.host}
              }
          }
      when: inventory_hostname == groups['k3s_master'][0]
EOF

echo "✅ Playbook created: ${APP_NAME}.yml"

# Update defaults file
echo ""
echo "📝 Updating Ansible defaults..."
if ! grep -q "deploy_${APP_NAME}:" "${ANSIBLE_ROLES_DIR}/defaults/main.yml"; then
    cat >> "${ANSIBLE_ROLES_DIR}/defaults/main.yml" << EOF

# ${APP_NAME} configuration
deploy_${APP_NAME}: false  # Set to true to deploy ${APP_NAME}
${APP_NAME}_app_url: "https://${DOMAIN}"
${APP_NAME}_service_name: "${APP_NAME}"
${APP_NAME}_service_port: ${PORT}
${APP_NAME}_timezone: "America/New_York"
${APP_NAME}_force_redeploy: false  # Set to true to force cleanup and redeploy
EOF
    echo "✅ Added ${APP_NAME} defaults to ${ANSIBLE_ROLES_DIR}/defaults/main.yml"
else
    echo "ℹ️  ${APP_NAME} defaults already exist in ${ANSIBLE_ROLES_DIR}/defaults/main.yml"
fi

# Update main tasks file
echo ""
echo "📝 Updating main tasks file..."
if ! grep -q "include_tasks: ${APP_NAME}.yml" "${ANSIBLE_ROLES_DIR}/tasks/main.yml"; then
    # Add before the placeholder comment
    sed -i "/# Include other applications/i\\
- name: Include ${APP_NAME} deployment\\
  include_tasks: ${APP_NAME}.yml\\
  when: deploy_${APP_NAME} | default(false)\\
" "${ANSIBLE_ROLES_DIR}/tasks/main.yml"
    echo "✅ Added ${APP_NAME} task to ${ANSIBLE_ROLES_DIR}/tasks/main.yml"
else
    echo "ℹ️  ${APP_NAME} task already exists in ${ANSIBLE_ROLES_DIR}/tasks/main.yml"
fi

# Cleanup temp directory
rm -rf "$TEMP_DIR"

echo ""
echo "🎉 Complete modular Ansible integration generated!"
echo "=========================================="
echo ""
echo "📁 Template files created in ${ANSIBLE_ROLES_DIR}/templates/${APP_NAME}/:"
echo "   - namespace.yaml.j2"
echo "   - configmap.yaml.j2"
echo "   - pv-pvc.yaml.j2"
echo "   - deployment.yaml.j2"
echo "   - service.yaml.j2"
echo "   - ingress.yaml.j2"
echo ""
echo "📁 Other files created:"
echo "   - ${ANSIBLE_ROLES_DIR}/tasks/${APP_NAME}.yml"
echo "   - ${APP_NAME}.yml (deployment playbook)"
echo ""
echo "📝 Files updated:"
echo "   - ${ANSIBLE_ROLES_DIR}/defaults/main.yml"
echo "   - ${ANSIBLE_ROLES_DIR}/tasks/main.yml"
echo ""
echo "🚀 Ready to deploy:"
echo "   ansible-playbook -i inventory ${APP_NAME}.yml"
echo ""
echo "🌐 Add to Caddyfile:"
echo "   bsk3.levangie.org, ${DOMAIN} {"
echo "       reverse_proxy 172.20.20.200:80 {"
echo "           header_up Host {http.request.host}"
echo "       }"
echo "   }"
