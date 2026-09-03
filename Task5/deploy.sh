#!/usr/bin/env bash
# =============================================================================
# Задание 5, пункты 1-3. Развёртывание четырёх сервисов и применение политик.
#
# Все четыре сервиса живут в одном пространстве имён traffic-demo и различаются
# только меткой role — именно она играет роль идентификатора сервиса в сетевых
# политиках. Разграничение строится на метках, а не на именах и не на адресах.
#
# Скрипт идемпотентен.
# =============================================================================
set -euo pipefail

# Пространство имён зафиксировано, а не вынесено в переменную окружения:
# manifests пиннят namespace в metadata, чтобы файл политики можно было
# применить и напрямую (kubectl apply -f non-admin-api-allow.yaml), как это
# описано в задании. Переопределяемая переменная и жёсткий namespace в
# манифесте рассинхронизировались бы, поэтому источник истины один — манифест.
NS="traffic-demo"
IMAGE="${IMAGE:-nginx:alpine}"   # вариант nginx на alpine: содержит wget для проверок

log() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl не найден в PATH"
kubectl cluster-info >/dev/null 2>&1 || die "кластер недоступен. Запустите: minikube start --cni=calico"

EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-minikube}"
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
[[ "$CURRENT_CONTEXT" == "$EXPECTED_CONTEXT" ]] || die "контекст kubectl — '$CURRENT_CONTEXT', ожидался '$EXPECTED_CONTEXT'.
      Переключитесь:     kubectl config use-context $EXPECTED_CONTEXT
      Либо укажите явно: EXPECTED_CONTEXT=$CURRENT_CONTEXT $0"

# Сетевые политики применяет CNI, а не сам Kubernetes. Стандартный bridge CNI в
# minikube их не выполняет: объекты создадутся, а трафик останется открытым.
if ! kubectl get daemonset -n kube-system calico-node >/dev/null 2>&1; then
  printf '\033[0;33m[!]\033[0m В кластере не найден Calico. Стандартный CNI minikube НЕ применяет\n'
  printf '    сетевые политики — объекты создадутся, но трафик разграничен не будет.\n'
  printf '    Пересоздайте кластер: minikube delete && minikube start --cni=calico\n\n'
fi

# --- 1. Пространство имён ----------------------------------------------------
log "Пространство имён: $NS"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- 2. Четыре сервиса с метками ---------------------------------------------
# Метка role задаётся ключом --labels, сервис создаётся ключом --expose.
SERVICES=(
  "front-end-app|front-end"
  "back-end-api-app|back-end-api"
  "admin-front-end-app|admin-front-end"
  "admin-back-end-api-app|admin-back-end-api"
)

log "Разворачиваю сервисы (образ $IMAGE)"
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name role <<< "$entry"
  if kubectl get pod "$name" -n "$NS" >/dev/null 2>&1; then
    printf '    %-26s метка role=%-20s уже развёрнут\n' "$name" "$role"
  else
    # --restart=Never задан явно: kubectl создаёт именно под, а не Deployment,
    # и имя пода совпадает с $name — на это опираются kubectl wait и verify.sh.
    kubectl run "$name" --image="$IMAGE" --labels "role=$role" \
      --restart=Never --expose --port 80 -n "$NS" >/dev/null
    printf '    %-26s метка role=%-20s создан\n' "$name" "$role"
  fi
done

log "Жду готовности подов"
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name _ <<< "$entry"
  kubectl wait --for=condition=Ready pod/"$name" -n "$NS" --timeout=180s >/dev/null
done
echo

# --- 3. Сетевые политики -----------------------------------------------------
# Порядок важен по смыслу, а не технически: сначала полный запрет, затем
# точечные разрешения.
log "Применяю сетевые политики"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in 00-default-deny.yaml non-admin-api-allow.yaml admin-api-allow.yaml; do
  # namespace берётся из самого манифеста; ключ -n не передаётся намеренно,
  # чтобы не было двух источников истины.
  kubectl apply -f "$DIR/$f" >/dev/null
  printf '    %s\n' "$f"
done
echo

kubectl get pods,svc -n "$NS" -L role
echo
kubectl get networkpolicy -n "$NS"
echo
echo "Далее: ./verify.sh — проверить разграничение трафика"
