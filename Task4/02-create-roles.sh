#!/usr/bin/env bash
# =============================================================================
# Задание 4, пункт 4. Создание ролей RBAC.
#
# Модель прав построена на двух принципах:
#
# 1. Разделение по вертикали — уровень полномочий:
#      просмотр  ->  настройка кластера  ->  привилегированные действия.
#
# 2. Разделение по горизонтали — организационная структура PropDevelopment:
#      каждый домен получает своё пространство имён, и права разработчиков
#      действуют только внутри него.
#
# В RBAC нет запрещающих правил: доступ определяется тем, что в роль НЕ включено.
# Поэтому secrets и pods/exec намеренно отсутствуют во всех ролях, кроме
# привилегированных secret-reader и pod-debugger.
#
# Скрипт идемпотентен: используется kubectl apply.
# =============================================================================
set -euo pipefail

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl не найден в PATH"
kubectl cluster-info >/dev/null 2>&1 || die "кластер недоступен. Запустите: minikube start"

# Пространства имён = домены компании. Метка data-classification берётся из
# классификации данных, выполненной в Задании 1.
NAMESPACES=(
  "sales|Группа сервисов для клиентов|confidential"
  "utility|Группа сервисов ЖКУ|confidential"
  "smart-access|Группа сервисов умного доступа|confidential"
  "finance|Домен «Финансы»|confidential"
  "data-platform|Домен «Дата»: хранилище и отчётность|internal"
  "platform|Пограничные сервисы: api-gateway, auth-service, secrets-vault|restricted"
)

# -----------------------------------------------------------------------------
# 1. Пространства имён
# -----------------------------------------------------------------------------
log "Создаю пространства имён по доменам компании"
for entry in "${NAMESPACES[@]}"; do
  IFS='|' read -r ns description classification <<< "$entry"
  kubectl create namespace "$ns" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null
  kubectl label namespace "$ns" \
    "domain=$ns" \
    "data-classification=$classification" \
    --overwrite >/dev/null
  printf '    %-15s %-14s %s\n' "$ns" "[$classification]" "$description"
done
echo

# -----------------------------------------------------------------------------
# 2. Кластерные роли
# -----------------------------------------------------------------------------
log "Создаю кластерные роли (ClusterRole)"

kubectl apply -f - >/dev/null <<'EOF'
# --- Только просмотр. Секретов в списке ресурсов нет намеренно. ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-viewer
  labels: { rbac-tier: "read-only" }
  annotations:
    description: "Просмотр состояния кластера без доступа к секретам"
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status", "services", "endpoints", "configmaps",
                "namespaces", "nodes", "persistentvolumes", "persistentvolumeclaims",
                "events", "serviceaccounts", "replicationcontrollers", "limitranges", "resourcequotas"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "ingressclasses", "networkpolicies"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
# --- Настройка кластера. Без секретов и без управления правами. ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-configurator
  labels: { rbac-tier: "operate" }
  annotations:
    description: "Настройка кластера: узлы, квоты, классы хранения, CRD. Без секретов и без RBAC"
rules:
  - apiGroups: [""]
    resources: ["namespaces", "resourcequotas", "limitranges", "nodes", "nodes/status",
                "persistentvolumes", "serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "volumeattachments", "csidrivers", "csinodes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingressclasses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["scheduling.k8s.io"]
    resources: ["priorityclasses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["node.k8s.io"]
    resources: ["runtimeclasses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Рабочие нагрузки — только чтение: настройка платформы не означает права
  # изменять приложения продуктовых команд.
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "configmaps", "events", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
---
# --- Управление правами доступа. Содержимое секретов не читает. ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-security-admin
  labels: { rbac-tier: "security" }
  annotations:
    description: "Управление RBAC, сетевыми политиками и сертификатами. Чтения секретов не имеет"
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["certificatesigningrequests", "certificatesigningrequests/approval", "certificatesigningrequests/status"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["signers"]
    verbs: ["approve"]
  - apiGroups: [""]
    resources: ["namespaces", "serviceaccounts", "events", "pods", "services", "configmaps", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
---
# --- ПРИВИЛЕГИРОВАННАЯ: чтение секретов. Выдаётся только через RoleBinding
# --- в конкретном пространстве имён, кластерной привязки не имеет. ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: secret-reader
  labels: { rbac-tier: "privileged" }
  annotations:
    description: "ПРИВИЛЕГИРОВАННАЯ РОЛЬ. Чтение секретов в пределах одного пространства имён"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
# --- ПРИВИЛЕГИРОВАННАЯ: вход в контейнер. Даёт доступ к данным в памяти
# --- и к смонтированным секретам в обход просмотра объекта Secret. ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-debugger
  labels: { rbac-tier: "privileged" }
  annotations:
    description: "ПРИВИЛЕГИРОВАННАЯ РОЛЬ. Вход в контейнер, проброс портов, чтение журналов"
rules:
  - apiGroups: [""]
    resources: ["pods/exec", "pods/attach", "pods/portforward"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
EOF
printf '    %s\n' "cluster-viewer" "cluster-configurator" "cluster-security-admin" \
                  "secret-reader (привилегированная)" "pod-debugger (привилегированная)"
echo

# -----------------------------------------------------------------------------
# 3. Роль разработчика — своя в каждом продуктовом пространстве имён
# -----------------------------------------------------------------------------
log "Создаю роль namespace-developer в каждом пространстве имён"
for entry in "${NAMESPACES[@]}"; do
  IFS='|' read -r ns _ _ <<< "$entry"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-developer
  namespace: ${ns}
  labels: { rbac-tier: "develop" }
  annotations:
    description: "Развёртывание и эксплуатация сервисов домена. Без секретов и без входа в контейнер"
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status", "services", "endpoints", "configmaps",
                "persistentvolumeclaims", "events", "serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "statefulsets", "statefulsets/scale",
                "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
  printf '    namespace-developer -> %s\n' "$ns"
done

echo
log "Итог"
kubectl get clusterrole -l 'rbac-tier' \
  -o custom-columns='ROLE:.metadata.name,TIER:.metadata.labels.rbac-tier' --no-headers |
  sed 's/^/    /'
echo
echo "    Далее: ./03-bind-roles.sh — связать группы пользователей с ролями"
