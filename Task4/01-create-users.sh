#!/usr/bin/env bash
# =============================================================================
# Задание 4, пункт 3. Создание пользователей кластера Kubernetes.
#
# Пользователь в Kubernetes не является объектом API: кластер узнаёт его из
# клиентского сертификата X.509. Поэтому «создать пользователя» означает
# выпустить сертификат, подписанный центром сертификации кластера, где
#   CN (Common Name)   -> имя пользователя,
#   O  (Organization)  -> группа, на которую навешиваются права (RoleBinding).
#
# Группы соответствуют организационной структуре PropDevelopment: продуктовые
# команды доменов, эксплуатация, информационная безопасность и наблюдатели.
#
# Скрипт идемпотентен: повторный запуск не перевыпускает уже выданные сертификаты.
# =============================================================================
set -euo pipefail

CERT_DIR="${CERT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.pki}"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubeconfig}"
MINIKUBE_HOME_DIR="${MINIKUBE_HOME:-$HOME/.minikube}"
CA_CRT="$MINIKUBE_HOME_DIR/ca.crt"
CA_KEY="$MINIKUBE_HOME_DIR/ca.key"
CLUSTER_NAME="${CLUSTER_NAME:-minikube}"
CERT_DAYS="${CERT_DAYS:-90}"   # ограниченный срок: сертификаты подлежат перевыпуску

# -----------------------------------------------------------------------------
# Пользователи: <логин>|<группа (O в сертификате)>|<комментарий>
# -----------------------------------------------------------------------------
USERS=(
  "anna.ivanova|viewers|Бизнес-аналитик, только просмотр"
  "igor.orlov|auditors|Внешний аудитор на время комплексного аудита, только просмотр"
  "pavel.smirnov|dev-sales|Разработчик домена «Продажи»"
  "olga.petrova|dev-smart-access|Разработчик домена «Умный доступ»"
  "sergey.volkov|platform-ops|Инженер эксплуатации, настройка кластера"
  "marina.orlova|security|Специалист по информационной безопасности"
  "denis.kuznetsov|sre-oncall|Дежурный SRE, привилегированный доступ к секретам"
)

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Проверки окружения
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl не найден в PATH"
command -v openssl >/dev/null 2>&1 || die "openssl не найден в PATH"
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

[[ -f "$CA_CRT" ]] || die "не найден сертификат CA кластера: $CA_CRT"
[[ -f "$CA_KEY" ]] || die "не найден ключ CA кластера: $CA_KEY"

# --- Сверка удостоверяющего центра с целевым кластером -----------------------
# Ключ EXPECTED_CONTEXT позволяет указать другой контекст, но адрес API-сервера
# берётся из него, а подпись всегда делается ключом из каталога minikube. Если
# у выбранного кластера другой УЦ, скрипт молча выпустит kubeconfig, которые
# этот кластер отвергнет при первом же обращении. Поэтому отпечаток УЦ, которым
# подписываем, сверяется с УЦ текущего контекста.
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

CTX_CA_FILE="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
CTX_CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
TMP_CA=""
if [[ -n "$CTX_CA_FILE" ]]; then
  CTX_CA_PATH="$CTX_CA_FILE"
elif [[ -n "$CTX_CA_DATA" ]]; then
  TMP_CA="$(mktemp)"; trap 'rm -f "$TMP_CA"' EXIT
  printf '%s' "$CTX_CA_DATA" | openssl base64 -d -A > "$TMP_CA"
  CTX_CA_PATH="$TMP_CA"
else
  die "в контексте '$CURRENT_CONTEXT' не указан удостоверяющий центр кластера — сверить подпись не с чем"
fi

if [[ "$(ca_fingerprint "$CA_CRT")" != "$(ca_fingerprint "$CTX_CA_PATH")" ]]; then
  die "удостоверяющий центр контекста '$CURRENT_CONTEXT' не совпадает с $CA_CRT.
      Сертификаты подписываются ключом minikube и этим кластером приняты не будут.
      Подписываем УЦ: $(ca_fingerprint "$CA_CRT")
      УЦ кластера:    $(ca_fingerprint "$CTX_CA_PATH")
      Укажите каталог нужного кластера через MINIKUBE_HOME либо запускайте на minikube."
fi

API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ -n "$API_SERVER" ]] || die "не удалось определить адрес API-сервера"

mkdir -p "$CERT_DIR" "$KUBECONFIG_DIR"
chmod 700 "$CERT_DIR" "$KUBECONFIG_DIR"

log "Кластер:      $CLUSTER_NAME ($API_SERVER)"
log "Сертификаты:  $CERT_DIR"
log "Kubeconfig:   $KUBECONFIG_DIR"
log "Срок действия сертификатов: $CERT_DAYS дней"
echo

# -----------------------------------------------------------------------------
# Выпуск сертификата и сборка kubeconfig для одного пользователя
# -----------------------------------------------------------------------------
create_user() {
  local user="$1" group="$2" comment="$3"
  local key="$CERT_DIR/$user.key"
  local csr="$CERT_DIR/$user.csr"
  local crt="$CERT_DIR/$user.crt"
  local kcfg="$KUBECONFIG_DIR/$user.kubeconfig"

  if [[ -f "$crt" ]]; then
    log "$user — сертификат уже выпущен, пропускаю"
  else
    log "$user — группа '$group' ($comment)"
    openssl genrsa -out "$key" 2048 2>/dev/null
    chmod 600 "$key"
    # CN -> имя пользователя, O -> группа. Именно их читает apiserver.
    openssl req -new -key "$key" -out "$csr" -subj "/CN=$user/O=$group" 2>/dev/null
    openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
      -CAserial "$CERT_DIR/ca.srl" -out "$crt" -days "$CERT_DAYS" -sha256 2>/dev/null
    rm -f "$csr"
  fi

  # Отдельный kubeconfig на пользователя: сертификаты встроены в файл,
  # чтобы его можно было передать владельцу как единственный артефакт доступа.
  kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$API_SERVER" \
    --certificate-authority="$CA_CRT" \
    --embed-certs=true \
    --kubeconfig="$kcfg" >/dev/null

  kubectl config set-credentials "$user" \
    --client-certificate="$crt" \
    --client-key="$CERT_DIR/$user.key" \
    --embed-certs=true \
    --kubeconfig="$kcfg" >/dev/null

  kubectl config set-context "$user@$CLUSTER_NAME" \
    --cluster="$CLUSTER_NAME" \
    --user="$user" \
    --kubeconfig="$kcfg" >/dev/null

  kubectl config use-context "$user@$CLUSTER_NAME" --kubeconfig="$kcfg" >/dev/null
  chmod 600 "$kcfg"
}

for entry in "${USERS[@]}"; do
  IFS='|' read -r user group comment <<< "$entry"
  create_user "$user" "$group" "$comment"
done

echo
log "Создано пользователей: ${#USERS[@]}"
echo
{
  echo "USER|GROUP (O)|VALID UNTIL"
  for entry in "${USERS[@]}"; do
    IFS='|' read -r user group _ <<< "$entry"
    not_after="$(openssl x509 -in "$CERT_DIR/$user.crt" -noout -enddate | cut -d= -f2)"
    echo "$user|$group|$not_after"
  done
} | column -t -s '|' | sed 's/^/  /'

cat <<'EOT'

Дальше:
  ./02-create-roles.sh   — создать пространства имён и роли
  ./03-bind-roles.sh     — связать группы пользователей с ролями

Проверка доступа от имени пользователя:
  kubectl --kubeconfig=./kubeconfig/anna.ivanova.kubeconfig get pods -A

ВНИМАНИЕ: каталог .pki содержит закрытые ключи пользователей и в репозиторий
не коммитится (см. .gitignore). В продуктивной среде ключ генерируется на
стороне владельца, наружу отдаётся только запрос на подпись (CSR).
EOT
