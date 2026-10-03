#!/usr/bin/env bash
# ============================================================
# compile-bench.sh — medición comparable de VELOCIDAD DE COMPILACIÓN
#
# Por qué existe: todo el trabajo de PGO, LTO, -O3, HZ y scheduler del proyecto
# se hizo sin una sola cifra que demostrara que ayudaba. `sched-bench.sh` mide
# schedulers y su propio encabezado dice que un arranque no dice nada; el tiempo
# de arranque no sirve para comparar kernels. Lo que falta es la métrica real:
#
#     ¿cuánto tarda este kernel en COMPILAR el siguiente kernel?
#
# que es exactamente para lo que se compila uno. Sin ella, "PGO cerrado de punta
# a punta" (§50) y "BORE elegido" son afirmaciones, no resultados.
#
# La métrica es UNIDADES DE TRADUCCIÓN POR SEGUNDO (TU/s). Más es mejor, y es
# directamente la inversa del tiempo de build: comparar dos kernels es dividir
# sus tiempos de build, sin más historia.
#
# Qué mide, y por qué dos brazos:
#   1 trabajo    velocidad de UNA traducción. Aquí es donde se ven -O2 vs -O3 y
#                -march=x86-64 vs x86-64-v3: más ILP y más registros vectoriales.
#                No hay contención, así que el scheduler casi no cuenta.
#   N trabajos  escalado en paralelo. Aquí aparece lo que de verdad diferencia
#                kernels en un build real: fork/exec del compilador, page faults
#                para el heap del compilador, futex en el reparto de trabajo, y el
#                scheduler decidiendo cuál de los 4 núcleos va primero. Es el
#                brazo que separa a BORE de vanilla cuando hay 4 jobs corriendo.
#
# La carga NO es un build del kernel y el script no lo disimula: no hay fuentes
# del kernel en esta máquina (ni headers instalados), así que genera un banco
# sintético. Lo que se reproduce no es el contenido del código —eso da igual—,
# sino la FIRMA DE KERNEL de compilar: N procesos compiladores arrancados por
# fork/exec, objetos grandes que se escriben y se releen, presión de memoria
# (el compilador reserva GB), page faults de primera vez y contención de futex
# con -j. Eso es lo que optimiza el kernel, y lo que mide este banco.
#
# Determinismo: las fuentes se generan con un LCG de semilla FIJA, así que son
# byte a byte las mismas en cada ejecución y en cada máquina. Sin eso el banco
# mediría el ruido de generar archivos en medio de la propia medición.
#
# warming: hay un build de calentamiento que NO se cronometra. La primera vez,
# las fuentes no están en caché de página y se mide el disco; con eso dentro,
# cada tirada mediría en parte la cacheabilidad y no el kernel. Las repeticiones
# yaODO partiendo de caché.
#
# NO sustituye a un build real (dura media hora, hay que compilarlo de verdad).
# Es una brújula, como sched-bench. Pero es la brújula que apunta a lo que importa.
#
# Uso:
#   compile-bench.sh                  mide y añade el resultado al histórico
#   compile-bench.sh --resumen        tabla de todo lo medido, por variante
#
# Variables de entorno:
#   CIZEN_VERIFY_STATE_DIR  dónde se guardan los resultados
#   COMPILE_BENCH_TU        ficheros .c a generar (default 120)
#   COMPILE_BENCH_HEADERS   cabeceros compartidos que cada .c incluye (default 6)
#   COMPILE_BENCH_REPS      repeticiones cronometradas por brazo (default 3)
#   COMPILE_BENCH_JOBS      parallelism del brazo paralelo (default = nproc)
#   COMPILE_BENCH_CC        compilador (default: el del kernel, clang si existe)
#   COMPILE_BENCH_CFLAGS    flags (default "-O2 -c")
#
# Para que el par sea válido: ccache DESACTIVADO, misma carga de escritorio,
# sin compilando nada, y el bank sin tocar entre las dos mediciones. El banco
# anota el load average por si hay que descartar una tirada, y anota la versión
# del compilador: comparar el clang 23 con el gcc 16 no es un A/B del kernel.
# ============================================================

set -uo pipefail
export LC_ALL=C

STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
TU="${COMPILE_BENCH_TU:-120}"
HEADERS="${COMPILE_BENCH_HEADERS:-6}"
REPS="${COMPILE_BENCH_REPS:-3}"
JOBS="${COMPILE_BENCH_JOBS:-$(nproc)}"
CC="${COMPILE_BENCH_CC:-clang}"
CFLAGS="${COMPILE_BENCH_CFLAGS:--O2 -c}"
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

# ccache MASCARA lo que se quiere medir. Con ccache activo, la segunda vez el
# banco no compila: sale de la caché y mide el I/O de leer un objeto, no el
# kernel. El protocolo A/B de la suite (§51) ya fija CCACHE_DISABLE=1 por esto
# mismo, y aquí se fuerza en vez de confiar: el banco no puede dejar que se te
# cuelque una caché y saques una mejora fantasma.
export CCACHE_DISABLE=1

# ---------- puerta de carga: no se mide con la máquina ocupada ----------
#
# Esto se añadió después de medir, no antes, y el motivo es el hallazgo más útil
# de todo el banco. Cuatro ejecuciones con flags IDÉNTICOS dieron, en el brazo de
# 4 trabajos, 67,6 / 67,2 / 56,1 / 39,9 TU/s: un 42 % de caída DENTRO de la misma
# sesión, con el mismo kernel y el mismo clang. No era ruido, era deriva, y la
# deriva tenía nombre: load average 6,1 en cuatro núcleos y PSI de CPU al 22 %,
# sostenidos. El culpable era el propio escritorio y el propio runtime que
# estaban launching el banco.
#
# La moraleja no es "el banco es malo": es que un banco que se mide desde una
# sesión viva no puede distinguir el kernel de lo que está pasando alrededor. Un
# -O3 que mejore un 3 % y un escritorio que te quite un 40 % son el mismo número.
# Por eso el banco MIDE la presión antes de empezar y RECHAZA anotarlo, en vez de
# escribir una cifra con tres decimales que no significa nada.
#
# El umbral son 15 de PSI (porcentaje de tiempo en que algún proceso está
# parado esperando CPU). Es deliberadamente exigente: en una máquina de cuatro
# núcleos que compila sola, la PSI baja de 5 casi siempre. Si salta, el número
# que saldría es peor que no tener ninguno.
#
# Para una medición de verdad hay que lanzar esto DESACOPLADO y no hacer nada
# mientras corre (ver "--detached" al final). Para probarlo sin más, COMPILE_BENCH_FORCE=1
# salta la puerta y las cifras que dé van marcadas como no fiables.

PSI_MAX="${COMPILE_BENCH_PSI_MAX:-15}"
FORCE="${COMPILE_BENCH_FORCE:-0}"
PSI=""; LOAD1=""

psi_some() {
  awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i; exit } }' /proc/pressure/cpu 2>/dev/null
}
leer_carga() { PSI="$(psi_some)"; LOAD1="$(cut -d' ' -f1 /proc/loadavg)"; }
carga_ok() {
  awk -v psi="$1" -v max="$PSI_MAX" -v f="$FORCE" 'BEGIN { exit !(f == 1 || psi + 0 <= max + 0) }'
}

# AVISO: esta puerta se llama SIN sustitución de comandos, a propósito.
# Se escribió primero como psi_antes="$(puerta_carga)" y su exit 1 no paraba
# nada: la sustitución corre en un subshell, el subshell moría con código 1 y el
# script seguía como si nada, hasta imprimir a la vez "máquina ocupada" y "la
# carga subió durante la medición". Un exit dentro de $( ) no sale del script.
puerta_carga() {
  carga_ok "$PSI" || {
    echo "" >&2
    echo "Máquina ocupada: PSI de CPU al ${PSI}% (tope: ${PSI_MAX}%), carga ${LOAD1} sobre $(nproc) núcleos." >&2
    echo "NO se anota nada. Con la carga que hay ahora, cualquier cifra sería" >&2
    echo "indistinguible del ruido del escritorio. Para medir de verdad:" >&2
    echo "  1. Cierra lo que puedas (navegador, compilaciones)." >&2
    echo "  2. Lánzalo desacoplado:  $SELF --detached" >&2
    echo "  3. No hagas nada hasta que termine (ni navegar, ni compilar)." >&2
    echo "Si de verdad quieres una cifra contaminada, COMPILE_BENCH_FORCE=1." >&2
    exit 1
  }
}

# ---------- --resumen: tabla de todo lo histórico ----------
#
#Igual que sched-bench.sh, el resumen parsea el histórico y solo cuenta bloques
# completos: un `fecha` abre bloque y una línea de ARM wastewater = fila inválida.
resumen_datos() {
  awk '
    BEGIN { un = -1; par = -1 }
    # Se saca el valor de "-> N.NN TU/s", NO el primer número de la línea. La
    # línea es "1 trabajo    : 4908 ms -> 24.45 TU/s": el primer número es el 1
    # de la etiqueta, y quedarse con él devolvía 1 TU/s para todas las variantes,
    # con la tabla llena de medias idénticas idénticas. Se coge lo que va delante de
    # "TU/s" porque es el único número de la línea que significa la medida.
    function tus(   s) {
      if (match($0, /[0-9]+(\.[0-9]+)? TU\/s/)) {
        s = substr($0, RSTART, RLENGTH); sub(/ TU\/s$/, "", s); return s + 0
      }
      return -1
    }
    function med(a, n,   i, j, v) {
      if (n < 1) return 0
      for (i = 2; i <= n; i++) { v = a[i]; j = i - 1; while (j > 0 && a[j] > v) { a[j+1] = a[j]; j-- }; a[j+1] = v }
      return (n % 2) ? a[(n+1)/2] : int((a[n/2] + a[n/2 + 1]) / 2)
    }
    function flush() {
      if (un >= 0 && par >= 0) { n++; U[n] = un; P[n] = par }
      else if (un >= 0 || par >= 0) d++
      un = -1; par = -1
    }
    /^fecha/ { flush(); next }
    /^1 trabajo/ { un = tus(); next }
    /^[0-9]+ trabajos/ { par = tus(); next }
    END { flush(); printf "%d %d %s %s\n", n + 0, d + 0, (n ? med(U, n) : "?"), (n ? med(P, n) : "?") }
  ' "$1"
}

resumen() {
  local f base var kver fecha n desc un par
  printf '%-24s %-26s %-20s %3s %5s %10s %10s\n' \
    kernel variante "primera medición" n desc "1 trabajo" "N trabajos"
  shopt -s nullglob
  for f in "$STATE_DIR"/compile-bench-*.txt; do
    base="$(basename "$f" .txt)"; base="${base#compile-bench-}"
    # <kernel>__<variante>: el kernel puede llevar guiones, la variante no.
    var="${base##*__}"; kver="${base%__$var}"
    read -r n desc un par <<<"$(resumen_datos "$f")"
    fecha="$(grep -m1 '^fecha' "$f" | sed -E 's/^fecha *: *//; s/T[0-9:.-]+//')"
    printf '%-24s %-26s %-20s %3s %5s %8s TU/s %8s TU/s\n' \
      "$kver" "$var" "$fecha" "$n" "$desc" "$un" "$par"
  done
  shopt -u nullglob
  echo
  echo "n = mediciones contadas · desc. = filas fuera de las medianas."
  echo "Más TU/s es mejor, y la cifra de cada bloque es su MÍNIMO de repeticiones"
  echo "intercaladas (por eso el mínimo y no la mediana: el ruido de fuera solo"
  echo "alarga la medición, nunca la acorta)."
  echo "Compara SOLO filas con la misma variante, y solo las que digan"
  echo "\"limpio\" en fiabilidad: una fila saltándose la puerta de carga está"
  echo "marcada como no fiable y no sirve para comparar con nadie."
  echo "Dos o tres bloques por variante, y compara las medianas."
}

case "${1:-}" in
  --resumen|-s) resumen; exit 0 ;;
  -h|--help) sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  # Desacoplado: se suelta con setsid y nohup para que la medicion siga aunque se
  # cierre la terminal que la lanzo. NO vuelve la maquina mas silenciosa — el
  # escritorio sigue igual — pero si evita que el shell que la lanzo se quede
  # esperando y se note como carga, y sobre todo deja un log con el resultado.
  --desacoplado|--detached)
    log="$STATE_DIR/compile-bench-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$STATE_DIR"
    setsid nohup "$SELF" --interno >"$log" 2>&1 </dev/null &
    echo "Banco lanzado desacoplado, pid $!."
    echo "Log:      $log"
    echo "Siguiente: tail -f $log"
    echo "Mientras corre, no compiles, no navegues y no abras el navegador: la"
    echo "puerta de carga lo dira y no anotara nada."
    exit 0 ;;
  --interno) : ;;   # reentrada de --desacoplado; no usar a mano
  "") ;;
  *) echo "Uso: $SELF [--resumen|--detached]" >&2; exit 2 ;;
esac

for v in TU HEADERS REPS JOBS; do
  val="${!v}"
  case "$val" in ''|*[!0-9]*) echo "$v debe ser un entero >= 1 (vale '$val')" >&2; exit 2 ;; esac
  [ "$val" -ge 1 ] || { echo "$v debe ser >= 1 (vale '$val')" >&2; exit 2; }
done

command -v "$CC" >/dev/null 2>&1 || { echo "No encuentro el compilador '$CC'." >&2; exit 1; }
ccver="$("$CC" --version 2>/dev/null | head -1)"

# Generador determinista: LCG de semilla fija (semillas de Numerical Recipes).
# Se usa para el contenido de los .c, no para nada que mida el banco: lo que se
# cronometra empieza DESPUÉS de generar, y aun así las fuentes tienen que ser
# idénticas entre tiradas o la comparación entre kernels no vale.
WORK="$(mktemp -d -t compile-bench.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT TERM

lcm() { echo $(( (1664525 * $1 + 1013904223) % 4294967296 )); }

gen_src() {
  local -i seed=12345 i j s
  local h f
  for ((h = 1; h <= HEADERS; h++)); do
    seed=$(lcm "$seed")
    {
      echo "#ifndef CIZEN_BENCH_H${h}_H"
      echo "#define CIZEN_BENCH_H${h}_H"
      echo "#include <stddef.h>"
      echo "#include <math.h>"
      # Inline que el optimizador tiene opportunities REALES deplo:
      # se puede vectorizar y es lo que separa a -O2 de -O3 y a SSE de AVX2.
      echo "static inline double bench_mix(double a, double b, double c) {"
      echo "  double r = a * 0.5 + b * 1.5 - c * 0.25;"
      echo "  return r + (r > 0.0 ? r : -r) + sqrt(r * r + 1.0);"
      echo "}"
      echo "struct bstruct${h} { double v[8]; long tag; unsigned flags; };"
      for ((i = 0; i < 6; i++)); do
        seed=$(lcm "$seed")
        s=$(( seed % 1000 + 7 ))
        echo "static inline long bmix${h}_${i}(long x, long y) {"
        echo "  x ^= y << ${s}; x ^= x >> 13; x *= 0x9E3779B97F4A7C15L; x ^= x >> 17; y ^= x << 7; return x + y;"
        echo "}"
      done
      echo "#endif"
    } > "$WORK/h${h}.h"
  done

  for ((f = 1; f <= TU; f++)); do
    local -i nh=$(( (f % HEADERS) + 1 ))
    {
      for ((h = 1; h <= nh; h++)); do echo "#include \"h${h}.h\""; done
      echo "struct bstruct1 s${f};"
      # Bucles sobre arrays de double: es lo que el vectorizador (y -O3) atacan.
      # Con -march=x86-64 el compilador solo puede emitir SSE2; con x86-64-v3
      # dispone de AVX2 y FMA, y aquí se nota.
      echo "double run${f}(const double *in, double *out, int n) {"
      echo "  double acc = 0.0;"
      echo "  for (int i = 0; i < n; i++) {"
      echo "    double a = in[i];"
      echo "    double b = bench_mix(a, in[(i + 1) % n], in[(i + 2) % n]);"
      echo "    for (int k = 0; k < 8; k++) { double t = a + b; b = b * 1.000001 + t * 0.5; acc += t; }"
      echo "    out[i] = b;"
      echo "  }"
      echo "  return acc;"
      echo "}"
      echo "long mix${f}(long seed) {"
      for ((h = 1; h <= nh; h++)); do
        for ((i = 0; i < 6; i++)); do
          echo "  seed = bmix${h}_${i}(seed, (long)$(( f * 31 + h * 7 + i )));"
        done
      done
      echo "  return seed;"
      echo "}"
      # Volumen de código por TU: sin esto el .o es diminuto y se mide el arranque"
      # del compilador, no su trabajo. Esto hace que el .o sea de decenas de KB."
      for ((i = 0; i < 12; i++)); do
        echo "double extra${f}_${i}(const double *in, int n) { double s = 0; for (int j = 0; j < n; j++) { s += in[(j * ${i}+3) % n] * ${i+2}.5; s -= in[(j + ${i}) % n] / ${i+3}.25; } return s; }"
      done
    } > "$WORK/t${f}.c"
  done
}

# Compila las TUs. $1 = número de trabajos en paralelo (1 = serie).
compila() {
  local -i par=$1
  ( cd "$WORK" && find . -name 't*.c' -print0 \
      | xargs -0 -P "$par" -n1 "$CC" $CFLAGS -I. -o /dev/null ) >/dev/null 2>&1
}

# Las TUs se generan ANTES del warming, no después del cronómetro: si se
# generaran dentro, se mediría también la escritura de los fuentes. Y si se
# olvidara la llamada (que fue el primer bug de este banco, y que el suelo de 300
# ms cazó al instante), find no vería nada, xargs no compilaría nada y se
# apuntarían miles de TU/s inventadas.
gen_src

# Warming: un build entero que NO se cronometra, para que la caché de página esté
# poblada. Sin esto, la primera repetición mide el disco y las siguientes no, y la
# mediana de 3 no lo arregla porque el sesgo va siempre a la primera.
compila "$JOBS"

# Si el warming no ha compilado NADA, se dice ahora con su nombre en vez de
# dejar que el suelo lo rechace más abajo como un número sin explicar.
if [ "$(find "$WORK" -name 't*.c' | wc -l)" -lt "$TU" ]; then
  echo "Generación incompleta: hay menos de $TU TUs en $WORK. No se mide nada." >&2
  exit 1
fi

ms() { date +%s%3N; }
mediana() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }

# TU por milisegundo, en coma flotante, directamente comparable entre brazos.
tus() { awk -v tu="$TU" -v ms="$1" 'BEGIN{printf "%.2f", (tu*1000)/ms}'; }

load_antes="$(cut -d' ' -f1-3 /proc/loadavg)"
# Puerta ANTES de medir. Si la máquina ya está ocupada, no se empieza: es más
# barato no producir la cifra que producir una que no significa nada.
leer_carga
puerta_carga
psi_antes="$PSI"

# --- Medición: los dos brazos INTERCALADOS, y se queda el MÍNIMO ---
#
# Por qué intercalados. Antes se medían las REPS del brazo de 1 trabajo y luego
# las del de N, y con eso el brazo de N salía bimodal entre ejecuciones: 57,5 /
# 57,6 / 77,5 / 75,8 TU/s con flags IDÉNTICOS, un 33 % de dispersión. El brazo
# de 1 trabajo en esas mismas cuatro tiradas variaba un 4 %. Ese reparto —un
# brazo estable y otro partido en dos modos— es la firma de algo que cambia DENTRO
# de la sesión (frecuencia, turbo disponible tras la carga, o el escritorio
# despertándose), no de una diferencia entre kernels. Con todos los registros de
# un brazo seguidos de todos los del otro, ese cambio cae solo en uno de ellos y
# se lee como si el banco fuera el que cambia.
#
# Por qué el mínimo y no la mediana. Una medición de este tipo se contamina hacia
# ABAJO en el tiempo: cualquier otra cosa que use la máquina solo puede
# ACELERAR. El mínimo de las repeticiones es el valor menos contaminado, no el
# más "-estable": la mediana sigue teniendo dentro todos los picos ajenos, que es
# justo lo que no se quiere. Se anota también la mediana por si hay que mirar el
# histórico, pero la cifra buena es el mínimo.
#
# Por qué 4 trabajos y no más. El equipo tiene 4 núcleos y el trabajo del
# escritorio es real. Con JOBS=nproc se mide "el build满了 la máquina", que es el
# caso interesante; con más jobs se mediría el sobrecoste de la cola, y cualquier
# diferencia de scheduler se pierde ahogada en la mediana.
t0=$(ms); compila 1; t1=$(ms); un_rep1=$(( t1 - t0 ))
t0=$(ms); compila "$JOBS"; t1=$(ms); par_rep1=$(( t1 - t0 ))
t0=$(ms); compila "$JOBS"; t1=$(ms); par_rep2=$(( t1 - t0 ))
t0=$(ms); compila 1; t1=$(ms); un_rep2=$(( t1 - t0 ))

un_ms=(); par_ms=()
for ((r = 0; r < REPS; r++)); do
  t0=$(ms); compila 1; t1=$(ms); un_ms+=( $(( t1 - t0 )) )
  t0=$(ms); compila "$JOBS"; t1=$(ms); par_ms+=( $(( t1 - t0 )) )
done

# El mínimo sale del conjunto completo (las dos tiradas de arranque + las REPS).
un_ms=( "${un_rep1[@]}" "${un_rep2[@]}" ${un_ms[@]+"${un_ms[@]}"} )
par_ms=( "${par_rep1[@]}" "${par_rep2[@]}" ${par_ms[@]+"${par_ms[@]}"} )

minimo() { printf '%s\n' "$@" | sort -n | head -1; }
un_min="$(minimo "${un_ms[@]}")"
par_min="$(minimo "${par_ms[@]}")"
un_med="$(mediana "${un_ms[@]}")"
par_med="$(mediana "${par_ms[@]}")"

un_tus="$(tus "$un_min")"
par_tus="$(tus "$par_min")"

# Puerta DESPUÉS de medir. Cubre el caso peor: que la máquina estuviera limpia
# al empezar y se ocupara durante. Una medición empezada en silencio y
# terminada con el escritorio 반환viendo tampoco vale, y es el caso que más
# cuela porque la primera media hora parece impeccable.
leer_carga
psi_despues="$PSI"
carga_ok "$psi_despues" || {
  echo "La carga subió DURANTE la medición (PSI ${psi_antes}% -> ${psi_despues}%). No se anota nada." >&2
  exit 1
}
if [ "$FORCE" = "1" ]; then
  fiabilidad="NO CONFIABLE: puerta de carga saltada con COMPILE_BENCH_FORCE=1"
else
  fiabilidad="limpio: carga estable, PSI ${psi_despues}%"
fi

# Suelo antes de escribir. 120 TUs de este tamaño NO se compilan en 100 ms ni de
# broma: si sale así, el banco no ha compilado (find vacío, xargs falló, disco
# lleno) y anotarlo envenenaría el histórico igual que envenenó el de
# sched-bench antes de tener el filtro. Se descarta y se dice por qué.
suelo=300
if [ "$un_min" -lt "$suelo" ] || [ "$par_min" -lt "$suelo" ]; then
  echo "Medición degenerada: no se anota nada." >&2
  echo "  1 trabajo=${un_min} ms  ${JOBS} trabajos=${par_min} ms  (suelo: ${suelo} ms)" >&2
  echo "Si el banco no ha hecho su trabajo suele ser disco lleno o falta de memoria." >&2
  exit 1
fi

out="$STATE_DIR/compile-bench-$(uname -r)__${CIBENCH_VARIANT:-default}.txt"
mkdir -p "$STATE_DIR"
{
  echo
  echo "fecha        : $(date -Is)"
  echo "kernel       : $(uname -r)  (build $(uname -v | awk '{print $4, $5, $6, $7, $8}'))"
  echo "variante     : ${CIBENCH_VARIANT:-default}"
  echo "compilador   : $ccver"
  echo "flags        : $CFLAGS   (ccache desactivado: CCACHE_DISABLE=1)"
  echo "núcleos      : $(nproc)   trabajos: $JOBS   TUs: $TU   cabeceros: $HEADERS   repeticiones: $REPS"
  echo "load medio   : $load_antes (antes de medir)"
  echo "psi cpu      : ${psi_antes}% -> ${psi_despues}% (tope ${PSI_MAX}%)"
  echo "fiabilidad   : $fiabilidad"
  echo "muestras     : $(( ${#un_ms[@]} )) por brazo (intercaladas), y el mínimo es la cifra"
  echo "1 trabajo    : min ${un_min} ms (mediana ${un_med} ms) -> ${un_tus} TU/s"
  echo "${JOBS} trabajos : min ${par_min} ms (mediana ${par_med} ms) -> ${par_tus} TU/s"
} | tee -a "$out"
echo "-> $out"
echo "Compara con:  $SELF --resumen"