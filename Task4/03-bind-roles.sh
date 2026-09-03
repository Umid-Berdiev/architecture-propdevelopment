#!/usr/bin/env bash
# =============================================================================
# Задание 4, пункт 5. Связывание пользователей с ролями.
#
# Права выдаются ГРУППАМ, а не отдельным людям. Группа пользователя берётся из
# поля O его сертификата (см. 01-create-users.sh). Такой подход означает, что
# приём и уход сотрудника не требуют правки RBAC: меняется только сертификат.
#
# Два вида привязок:
#   ClusterRoleBinding — право действует во всём кластере;
#   RoleBinding        — то же право, но ограничено одним пространством имён.
#
# Привилегированные роли (secret-reader, pod-debugger) привязываются ТОЛЬКО
# через RoleBinding: кластерной привязки у них нет ни одной.
#
# Скрипт идемпотентен: используется kubectl apply.
# =============================================================================
set -euo pipefail

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl не найден в PATH"
kubectl cluster-info >/dev/null 2>&1 || die "кластер недоступен. Запустите: minikube start"

# --- Защита от запуска в чужом кластере -------------------------------------
# Рядом с minikube обычно настроен рабочий кластер. Скрипт создаёт учётные
# данные и права доступа, поэтому запуск не в том контексте недопустим.
# Проверка выполняется ДО чтения любых данных кластера: иначе адрес API-сервера
# был бы взят из текущего контекста, а сертификат УЦ — из каталога minikube,
# и на выходе получились бы нерабочие файлы доступа.
# Проверка снимается явно: EXPECTED_CONTEXT=<имя> ./<скрипт>
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-minikube}"
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  die "текущий контекст kubectl — '${CURRENT_CONTEXT:-не задан}', ожидался '$EXPECTED_CONTEXT'.
      Переключитесь:     kubectl config use-context $EXPECTED_CONTEXT
      Либо укажите явно: EXPECTED_CONTEXT=${CURRENT_CONTEXT:-<имя>} $0"
fi
log "Контекст kubectl: $CURRENT_CONTEXT"
kubectl get clusterrole cluster-viewer >/dev/null 2>&1 || die "роли не найдены. Сначала запустите ./02-create-roles.sh"

PRODUCT_NAMESPACES=(sales utility smart-access finance data-platform platform)

# Соответствие «домен -> группа разработчиков». Организационная структура
# компании отображается на пространства имён кластера один к одному.
declare -a DEV_MAP=(
  "sales|dev-sales"
  "utility|dev-utility"
  "smart-access|dev-smart-access"
  "finance|dev-finance"
  "data-platform|dev-data"
  "platform|dev-platform"
)

# -----------------------------------------------------------------------------
# 1. Кластерные привязки: просмотр, настройка, управление правами
# -----------------------------------------------------------------------------
log "Кластерные привязки (ClusterRoleBinding)"

kubectl apply -f - >/dev/null <<'EOF'
# Просмотр всего кластера без секретов: аналитики, менеджеры и внешние аудиторы.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: viewers-cluster-viewer
  annotations:
    description: "Группы viewers и auditors получают просмотр состояния кластера"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-viewer
subjects:
  - kind: Group
    name: viewers
    apiGroup: rbac.authorization.k8s.io
  - kind: Group
    name: auditors
    apiGroup: rbac.authorization.k8s.io
---
# Настройка кластера: инженеры эксплуатации платформы.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-ops-cluster-configurator
  annotations:
    description: "Группа platform-ops настраивает кластер, но не читает секреты и не меняет права"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-configurator
subjects:
  - kind: Group
    name: platform-ops
    apiGroup: rbac.authorization.k8s.io
---
# Управление правами доступа: информационная безопасность.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: security-cluster-security-admin
  annotations:
    description: "Группа security управляет RBAC и сетевыми политиками, содержимое секретов не читает"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-security-admin
subjects:
  - kind: Group
    name: security
    apiGroup: rbac.authorization.k8s.io
EOF
printf '    %s\n' \
  "viewers, auditors            -> cluster-viewer" \
  "platform-ops                 -> cluster-configurator" \
  "security                     -> cluster-security-admin"
echo

# -----------------------------------------------------------------------------
# 2. Привязки в пространствах имён: разработчики своего домена
# -----------------------------------------------------------------------------
log "Привязки разработчиков к своим доменам (RoleBinding)"
for entry in "${DEV_MAP[@]}"; do
  IFS='|' read -r ns group <<< "$entry"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${group}-developer
  namespace: ${ns}
  annotations:
    description: "Группа ${group} управляет сервисами только в пространстве имён ${ns}"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: namespace-developer
subjects:
  - kind: Group
    name: ${group}
    apiGroup: rbac.authorization.k8s.io
EOF
  printf '    %-28s -> namespace-developer @ %s\n' "$group" "$ns"
done
echo

# -----------------------------------------------------------------------------
# 3. Привилегированные привязки: только дежурная смена эксплуатации
# -----------------------------------------------------------------------------
log "Привилегированные привязки (RoleBinding, только группа sre-oncall)"
for ns in "${PRODUCT_NAMESPACES[@]}"; do
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sre-oncall-secret-reader
  namespace: ${ns}
  annotations:
    description: "ПРИВИЛЕГИРОВАННО. Чтение секретов в ${ns} дежурной сменой эксплуатации"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: secret-reader
subjects:
  - kind: Group
    name: sre-oncall
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sre-oncall-pod-debugger
  namespace: ${ns}
  annotations:
    description: "ПРИВИЛЕГИРОВАННО. Вход в контейнер в ${ns} дежурной сменой эксплуатации"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-debugger
subjects:
  - kind: Group
    name: sre-oncall
    apiGroup: rbac.authorization.k8s.io
EOF
  printf '    sre-oncall -> secret-reader, pod-debugger @ %s\n' "$ns"
done
echo

# -----------------------------------------------------------------------------
# 4. Проверка модели доступа
# -----------------------------------------------------------------------------
log "Проверка прав через kubectl auth can-i"
echo

# ВАЖНО: подресурс проверяется флагом --subresource=<имя>. Запись 'pods/exec'
# kubectl auth can-i трактует как ТИП/ИМЯ, то есть как под с именем exec.
check() { # <ожидание yes|no> <группа> <действие> [аргументы kubectl]
  local expect="$1" group="$2" action="$3"; shift 3
  local got
  got="$(kubectl auth can-i "$action" "$@" --as=probe --as-group="$group" 2>/dev/null || true)"
  got="${got:-no}"
  if [[ "$got" == "$expect" ]]; then
    printf '    \033[0;32m OK \033[0m %-16s %-46s -> %s\n' "$group" "$action $*" "$got"
  else
    printf '    \033[0;31mОШИБКА\033[0m %-16s %-46s -> %s (ожидалось %s)\n' "$group" "$action $*" "$got" "$expect"
    FAILED=1
  fi
}

FAILED=0
echo "  Просмотр:"
check yes viewers        list   pods       --all-namespaces
check no  viewers        get    secrets    -n sales
check no  viewers        create deployments -n sales

echo "  Настройка кластера:"
check yes platform-ops   create namespaces
check yes platform-ops   create storageclasses
check no  platform-ops   get    secrets    -n platform
check no  platform-ops   create clusterrolebindings

echo "  Информационная безопасность:"
check yes security       create rolebindings -n sales
check no  security       get    secrets      -n platform

echo "  Разграничение по доменам:"
check yes dev-sales      create deployments -n sales
check no  dev-sales      create deployments -n finance
check no  dev-sales      get    secrets     -n sales
check no  dev-sales      create pods -n sales --subresource=exec
check yes dev-smart-access create deployments -n smart-access
check no  dev-smart-access create deployments -n sales

echo "  Настройка допуска (вебхуки = полный контроль над кластером):"
check no  platform-ops   create mutatingwebhookconfigurations
check no  platform-ops   create validatingwebhookconfigurations
check no  security       create mutatingwebhookconfigurations

echo "  Привилегированные действия:"
check yes sre-oncall     get    secrets    -n platform
check yes sre-oncall     create pods -n finance --subresource=exec
check no  sre-oncall     create namespaces


# Выдачу прав нельзя проверить через auth can-i: запрет на повышение привилегий
# срабатывает не на авторизации, а при записи объекта. Поэтому здесь делается
# настоящая попытка создать привязку с --dry-run=server от имени группы.
try_apply() { # <ожидание ok|forbidden> <группа> <описание> <манифест>
  local expect="$1" group="$2" what="$3" manifest="$4" got
  if printf '%s' "$manifest" | kubectl apply --dry-run=server --as=rbac-probe --as-group="$group" -f - >/dev/null 2>&1; then
    got=ok
  else
    got=forbidden
  fi
  if [[ "$got" == "$expect" ]]; then
    printf '    \033[0;32m OK \033[0m %-16s %-46s -> %s\n' "$group" "$what" "$got"
  else
    printf '    \033[0;31mОШИБКА\033[0m %-16s %-46s -> %s (ожидалось %s)\n' "$group" "$what" "$got" "$expect"
    FAILED=1
  fi
}

echo "  Выдача прав информационной безопасностью:"
try_apply ok security "выдать secret-reader дежурной смене" '''apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: rbac-probe-grant, namespace: sales }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: secret-reader }
subjects: [{ kind: Group, name: sre-oncall, apiGroup: rbac.authorization.k8s.io }]'''
try_apply forbidden security "сделать кого-либо cluster-admin" '''apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: rbac-probe-admin }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [{ kind: Group, name: security, apiGroup: rbac.authorization.k8s.io }]'''
try_apply forbidden security "создать роль с доступом к секретам" '''apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: rbac-probe-role, namespace: sales }
rules: [{ apiGroups: [""], resources: ["secrets"], verbs: ["get"] }]'''

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '\033[0;32m==> Все проверки пройдены: ролевая модель работает как описано в таблице.\033[0m\n'
else
  printf '\033[0;31m==> Есть расхождения между моделью и фактическими правами.\033[0m\n'; exit 1
fi

cat <<'EOT'

Проверка от имени реального пользователя (после ./01-create-users.sh):
  kubectl --kubeconfig=./kubeconfig/anna.ivanova.kubeconfig get pods -A
  kubectl --kubeconfig=./kubeconfig/anna.ivanova.kubeconfig get secrets -n sales      # ожидается отказ
  kubectl --kubeconfig=./kubeconfig/pavel.smirnov.kubeconfig get pods -n finance      # ожидается отказ
  kubectl --kubeconfig=./kubeconfig/denis.kuznetsov.kubeconfig get secrets -n platform
EOT
