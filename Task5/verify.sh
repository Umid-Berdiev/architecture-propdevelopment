#!/usr/bin/env bash
# =============================================================================
# Задание 5. Проверка разграничения трафика.
#
# Проверяется полная матрица 4x4: каждый сервис пробует обратиться к каждому,
# включая самого себя. Ожидаемый результат задан явно — проверка падает и при
# лишнем запрете, и при лишнем разрешении.
#
# Дополнительно проверяется под без меток: он не должен достучаться никуда.
# =============================================================================
set -uo pipefail

NS="traffic-demo"   # зафиксировано так же, как в манифестах политик
TIMEOUT="${TIMEOUT:-3}"

log() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || die "нет пространства имён $NS. Сначала запустите ./deploy.sh"

PODS=(front-end-app back-end-api-app admin-front-end-app admin-back-end-api-app)
SHORT=(front-end back-end-api admin-front-end admin-back-end-api)

# Ожидаемая матрица доступности: строка — источник, столбец — назначение.
# Разрешено только внутри пары. Обращение пода к самому себе разрешено всегда
# и запрету не поддаётся — подробности в комментарии внутри expect_for.
# Реализовано через case, а не через ассоциативный массив: в bash 3.2,
# который штатно поставляется с macOS, ассоциативных массивов нет.
expect_for() { # <под-источник> <под-назначение> -> yes|no
  # Обращение пода к самому себе разрешено всегда: NetworkPolicy не применяется
  # к трафику, у которого источник и получатель — один и тот же под. Запретить
  # это сетевой политикой невозможно, поэтому диагональ матрицы ожидается «да».
  [[ "$1" == "$2" ]] && { echo yes; return; }
  case "$1/$2" in
    front-end-app/back-end-api-app|back-end-api-app/front-end-app) echo yes ;;
    admin-front-end-app/admin-back-end-api-app|admin-back-end-api-app/admin-front-end-app) echo yes ;;
    *) echo no ;;
  esac
}

# Таймаут задаётся ключом -T: это канонический ключ BusyBox wget, который
# используется в alpine-образах. Длинный вариант --timeout поддерживается не
# во всех сборках BusyBox, и его отсутствие выглядело бы как срабатывание
# сетевой политики, хотя на деле это ошибка разбора аргументов.
probe() { # <под-источник> <сервис-назначение> -> yes|no
  if kubectl exec -n "$NS" "$1" -- wget -qO- -T "$TIMEOUT" "http://$2" >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

FAILED=0

log "Проверяю готовность сервисов"
# Если под не Ready, все пробы вернут «нет связи», и это будет неотличимо от
# работы сетевой политики. Такой прогон недостоверен, поэтому проверка падает.
for p in "${PODS[@]}"; do
  ready="$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  [[ "$ready" == "true" ]] || die "под $p не готов (${ready:-под отсутствует}). Прогон был бы недостоверен: сначала ./deploy.sh"
done
echo

log "Матрица доступности (строка — источник, столбец — назначение)"
echo

# Таблица собирается в переменную, а НЕ отправляется в конвейер по мере
# построения: левая часть пайпа выполняется в подоболочке, и присваивание
# FAILED=1 внутри неё было бы потеряно — расхождения не повлияли бы на
# код возврата. Цвет не используется: column считает управляющие
# последовательности за видимые символы и ломает ширину колонок.
TABLE="ИСТОЧНИК \\ НАЗНАЧЕНИЕ"
for col in "${SHORT[@]}"; do TABLE="$TABLE|$col"; done
TABLE="$TABLE"$'\n'

for src in "${PODS[@]}"; do
  row="${src%-app}"
  for dst in "${PODS[@]}"; do
    got="$(probe "$src" "$dst")"
    want="$(expect_for "$src" "$dst")"
    if [[ "$got" == "$want" ]]; then
      [[ "$got" == yes ]] && row="$row|разрешено" || row="$row|запрещено"
    else
      row="$row|! $got (ждали $want)"
      FAILED=1
    fi
  done
  TABLE="$TABLE$row"$'\n'
done

# Локаль задана явно: в локали C column считает байты, а не символы,
# и кириллица ломает разметку.
printf '%s' "$TABLE" | LC_ALL=en_US.UTF-8 column -t -s '|' | sed 's/^/    /'
echo

# --- Под без меток: не должен достучаться никуда -----------------------------
log "Под без меток (как в задании: kubectl run test-\$RANDOM --image=alpine)"
TESTPOD="test-$RANDOM"
kubectl run "$TESTPOD" -n "$NS" --image=alpine --restart=Never --command -- sleep 120 >/dev/null 2>&1 \
  || die "не удалось создать под $TESTPOD"
kubectl wait --for=condition=Ready pod/"$TESTPOD" -n "$NS" --timeout=120s >/dev/null 2>&1 \
  || die "под $TESTPOD не перешёл в Ready: проверка изоляции была бы недостоверной"
for dst in "${PODS[@]}"; do
  got="$(probe "$TESTPOD" "$dst")"
  if [[ "$got" == no ]]; then
    printf '    \033[0;32m OK \033[0m %-24s -> %-24s запрещено\n' "$TESTPOD" "${dst%-app}"
  else
    printf '    \033[0;31mОШИБКА\033[0m %-24s -> %-24s разрешено, а не должно\n' "$TESTPOD" "${dst%-app}"
    FAILED=1
  fi
done
kubectl delete pod "$TESTPOD" -n "$NS" --wait=false >/dev/null 2>&1
echo

# --- Под с меткой role=front-end: получает права роли, а не имени ------------
log "Под с меткой role=front-end: права определяются меткой, а не именем пода"
TESTPOD2="test-$RANDOM"
kubectl run "$TESTPOD2" -n "$NS" --image=alpine --labels role=front-end --restart=Never --command -- sleep 120 >/dev/null 2>&1 \
  || die "не удалось создать под $TESTPOD2"
kubectl wait --for=condition=Ready pod/"$TESTPOD2" -n "$NS" --timeout=120s >/dev/null 2>&1 \
  || die "под $TESTPOD2 не перешёл в Ready: проверка была бы недостоверной"
for entry in "back-end-api-app|yes" "admin-back-end-api-app|no"; do
  IFS='|' read -r dst want <<< "$entry"
  got="$(probe "$TESTPOD2" "$dst")"
  if [[ "$got" == "$want" ]]; then
    printf '    \033[0;32m OK \033[0m %-24s -> %-24s %s\n' "$TESTPOD2" "${dst%-app}" \
      "$([[ $got == yes ]] && echo разрешено || echo запрещено)"
  else
    printf '    \033[0;31mОШИБКА\033[0m %-24s -> %-24s %s (ждали %s)\n' "$TESTPOD2" "${dst%-app}" "$got" "$want"
    FAILED=1
  fi
done
kubectl delete pod "$TESTPOD2" -n "$NS" --wait=false >/dev/null 2>&1
echo

if [[ "$FAILED" -eq 0 ]]; then
  printf '\033[0;32m==> Разграничение работает: трафик разрешён только внутри пар.\033[0m\n'
else
  printf '\033[0;31m==> Фактическое поведение сети расходится с политиками.\033[0m\n'
  printf '    Частая причина: CNI не применяет NetworkPolicy. Проверьте: kubectl get ds -n kube-system calico-node\n'
  exit 1
fi
