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

NS="${NS:-traffic-demo}"
TIMEOUT="${TIMEOUT:-3}"

log() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || die "нет пространства имён $NS. Сначала запустите ./deploy.sh"

PODS=(front-end-app back-end-api-app admin-front-end-app admin-back-end-api-app)
SHORT=(front-end back-end-api admin-front-end admin-back-end-api)

# Ожидаемая матрица доступности: строка — источник, столбец — назначение.
# Разрешено только внутри пары; обращение к самому себе тоже запрещено,
# потому что Egress открыт исключительно на партнёра по паре.
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

probe() { # <под-источник> <сервис-назначение> -> yes|no
  if kubectl exec -n "$NS" "$1" -- wget -qO- --timeout="$TIMEOUT" "http://$2" >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

FAILED=0

log "Матрица доступности (строка — источник, столбец — назначение)"
echo

# Таблица собирается без управляющих последовательностей цвета и выравнивается
# через column с явной UTF-8 локалью: printf и column в локали C считают байты,
# а не символы, и кириллица ломает разметку.
{
  printf 'ИСТОЧНИК \\ НАЗНАЧЕНИЕ'
  for s in "${SHORT[@]}"; do printf '|%s' "$s"; done
  echo
  for src in "${PODS[@]}"; do
    printf '%s' "${src%-app}"
    for dst in "${PODS[@]}"; do
      got="$(probe "$src" "$dst")"
      want="$(expect_for "$src" "$dst")"
      if [[ "$got" == "$want" ]]; then
        [[ "$got" == yes ]] && printf '|разрешено' || printf '|запрещено'
      else
        printf '|! %s (ждали %s)' "$got" "$want"
        FAILED=1
      fi
    done
    echo
  done
} | LC_ALL=en_US.UTF-8 column -t -s '|' | sed 's/^/    /'
echo

# --- Под без меток: не должен достучаться никуда -----------------------------
log "Под без меток (как в задании: kubectl run test-\$RANDOM --image=alpine)"
TESTPOD="test-$RANDOM"
kubectl run "$TESTPOD" -n "$NS" --image=alpine --restart=Never --command -- sleep 120 >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/"$TESTPOD" -n "$NS" --timeout=120s >/dev/null 2>&1
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
kubectl run "$TESTPOD2" -n "$NS" --image=alpine --labels role=front-end --restart=Never --command -- sleep 120 >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/"$TESTPOD2" -n "$NS" --timeout=120s >/dev/null 2>&1
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
