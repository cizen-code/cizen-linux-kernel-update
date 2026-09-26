#!/usr/bin/env bash
# ============================================================
# sched-bench.sh — medición comparable entre schedulers del kernel
#
# Los schedulers alternativos del proyecto (BORE, BMQ/PDS, LF-BMQ) no compiten
# en throughput: ceden rendimiento en paralelo a cambio de latencia interactiva
# con la máquina saturada. Por eso miden tres cosas, no una:
#
#   1 hilo      velocidad por núcleo (throughput puro)
#   N hilos     escalado en paralelo (donde suelen perder)
#   latencia fg cuanto tarda una tarea de primer plano con la máquina saturada
#               (donde suelen ganar; es lo que se nota al usar el equipo)
#
# NO sustituye a una batería: es una brújula. Un arranque no dice nada (va de
# firmware, I/O y servicios), y por eso aquí no se miden arranques.
#
# Uso:
#   sched-bench.sh            mide y añade el resultado al histórico
#   sched-bench.sh --resumen  tabla de todo lo medido, por scheduler
#
# El resultado se guarda en $STATE_DIR/sched-bench-<kernel>-<scheduler>.txt, un
# bloque por ejecución. El scheduler va en el nombre a propósito: dos builds del
# MISMO kernel (7.2.7-cizen-v3 con bore y con bmq) se llaman igual, y sin eso el
# segundo machaca al primero.
#
# Variables de entorno:
#   CIZEN_VERIFY_STATE_DIR  dónde se guardan los resultados
#   SCHED_BENCH_ITERS       iteraciones por medición (default 10)
#   SCHED_BENCH_REPS        repeticiones de la latencia (default 3)
#   SCHED_BENCH_LOAD_N      tareas de carga en paralelo (default 4 = núcleos)
#   SCHED_BENCH_SIZE_MB     tamaño del fichero de trabajo (default 300)
#
# Para que el par sea válido: mide en el mismo estado (mismo kernel, misma
# carga de escritorio, sin compilando nada) y con el script sin tocar. El banco
# anota el load average de la medición por si hay que descartar una tirada.
# ============================================================

set -uo pipefail
export LC_ALL=C

STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
ITERS="${SCHED_BENCH_ITERS:-10}"
REPS="${SCHED_BENCH_REPS:-3}"
LOAD_N="${SCHED_BENCH_LOAD_N:-4}"
SIZE_MB="${SCHED_BENCH_SIZE_MB:-300}"
# En el host vive en /usr/local/bin/kernel-update/, que no está en el PATH: solo
# /usr/local/bin/kernel-update.sh lo está. Los mensajes usan la ruta real para
# que el usuario pueda copiar y pegar lo que lee.
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

# ---------- --resumen: tabla de todo lo histórico ----------
resumen() {
  local f kernel sched fecha n un par lat
  printf '%-26s %-8s %-20s %4s %9s %9s %9s\n' kernel scheduler "primera medición" n "1 hilo" "N hilos" "lat.fg"
  shopt -s nullglob
  for f in "$STATE_DIR"/sched-bench-*.txt; do
    kernel="$(basename "$f" .txt)"; kernel="${kernel#sched-bench-}"
    sched="${kernel##*-}"; kernel="${kernel%-*}"
    n="$(grep -c '^1 hilo' "$f")"
    fecha="$(grep -m1 '^fecha' "$f" | sed -E 's/^fecha *: *//; s/T[0-9:.-]+//')"
    un="$(grep '^1 hilo' "$f" | sed -E 's/.*: *([0-9]+) ms/\1/' | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')"
    par="$(grep "^[0-9]* hilos" "$f" | sed -E 's/.*: *([0-9]+) ms/\1/' | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')"
    lat="$(grep '^latencia fg' "$f" | sed -E 's/.*: *([0-9]+) ms.*/\1/' | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')"
    printf '%-26s %-8s %-20s %4s %8s ms %8s ms %8s ms\n' "$kernel" "$sched" "$fecha" "$n" "${un:-?}" "${par:-?}" "${lat:-?}"
  done
  shopt -u nullglob
  echo
  echo "Nótese: la carga de escritorio y el estado del sistema mandan más que el"
  echo "scheduler en estas cifras. Tira dos o tres veces cada kernel y quédate con"
  echo "la mediana, no con un número suelto."
}

case "${1:-}" in
  --resumen|-s) resumen; exit 0 ;;
  -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Uso: $SELF [--resumen]" >&2; exit 2 ;;
esac

for v in ITERS REPS LOAD_N SIZE_MB; do
  val="${!v}"
  case "$val" in ''|*[!0-9]*) echo "$v debe ser un entero >= 1 (vale '$val')" >&2; exit 2 ;; esac
  [ "$val" -ge 1 ] || { echo "$v debe ser >= 1 (vale '$val')" >&2; exit 2; }
done

# Scheduler real del kernel en marcha, no el que se pidió en el build: si el
# planificador de arranque se felló, hay que medir el que hay.
#
# OJO con el pipe: `zcat | grep -m1` se corta con SIGPIPE y, con `pipefail`, el
# 141 de zcat hace fallar la comprobación aunque grep haya encontrado el
# símbolo (medía "eevdf" en un kernel con BMQ). Process substitution, que solo
# mira el estado de grep.
sched_actual() {
  local s
  for s in SCHED_BORE SCHED_BMQ SCHED_PDS SCHED_LFBMQ SCHED_MUQSS; do
    if grep -qm1 "^CONFIG_${s}=y" < <(zcat /proc/config.gz 2>/dev/null); then
      printf '%s\n' "${s#SCHED_}"; return 0
    fi
  done
  printf 'eevdf\n'
}

WORK="$(mktemp -t sched-bench.XXXXXX)"
PIDS=()
# La carga en segundo plano se mata por PID, nunca con pkill -f: el patrón
# coincide con la propia línea de órdenes de quien lo lanza y se mata solo.
limpia() {
  rm -f "$WORK"
  if [ "${#PIDS[@]}" -gt 0 ]; then kill "${PIDS[@]}" 2>/dev/null; fi
  return 0
}
trap limpia EXIT
trap 'limpia; exit 130' INT TERM

ms() { date +%s%3N; }
bucle() { local _; for _ in $(seq "$ITERS"); do sha256sum "$WORK" >/dev/null; done; }
carga() { while :; do sha256sum "$WORK" >/dev/null; done; }
mediana() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }

if [ ! -r /proc/config.gz ]; then
  echo "Sin /proc/config.gz: no se puede saber qué scheduler está en marcha." >&2
  echo "Se mide igual, pero el resultado no se podrá atribuir a un scheduler." >&2
fi

# Load average de ANTES de medir: durante la medición lo domina el propio banco,
# así que solo sirve como contexto si se lee antes ("¿estaba el escritorio
# haciendo algo cuando empecé?").
load_antes="$(cut -d' ' -f1-3 /proc/loadavg)"

dd if=/dev/urandom of="$WORK" bs=1M count="$SIZE_MB" status=none
bucle >/dev/null   # calentar la caché del fichero: si no, se mide el disco

t0=$(ms); bucle; t1=$(ms)
un_hilo=$(( t1 - t0 ))

t0=$(ms)
for _ in $(seq "$ITERS"); do bucle & PIDS+=($!); done
wait "${PIDS[@]}"
t1=$(ms)
paralelo=$(( t1 - t0 ))
PIDS=()

lat=()
for _ in $(seq "$REPS"); do
  for _ in $(seq "$LOAD_N"); do carga & PIDS+=($!); done
  sleep 0.5
  t0=$(ms); bucle; t1=$(ms)
  lat+=($(( t1 - t0 )))
  kill "${PIDS[@]}" 2>/dev/null
  wait "${PIDS[@]}" 2>/dev/null
  PIDS=()
  sleep 0.3
done

sched="$(sched_actual)"
build="$(uname -v | awk '{print $4, $5, $6, $7, $8}')"
out="$STATE_DIR/sched-bench-$(uname -r)-$sched.txt"
mkdir -p "$STATE_DIR"
{
  echo
  echo "fecha        : $(date -Is)"
  echo "kernel       : $(uname -r)  (build $build)"
  echo "scheduler    : $sched"
  echo "núcleos      : $(nproc)   carga: $LOAD_N   iteraciones: $ITERS   fichero: ${SIZE_MB}MB"
  echo "load medio   : $load_antes (antes de medir)"
  echo "1 hilo       : ${un_hilo} ms"
  echo "$LOAD_N hilos  : ${paralelo} ms"
  printf 'latencia fg  : %s ms (mediana de %d con %d tareas en carga)\n' "$(mediana "${lat[@]}")" "$REPS" "$LOAD_N"
} | tee -a "$out"
echo "-> $out"
echo "Compara con:  $SELF --resumen"
