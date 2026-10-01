#!/usr/bin/env bash
# iotest-scheduler.sh — ¿aporta algo mq-deadline frente a none en este SATA?
#
# Por qué este test y no otro:
#   - `none` y `mq-deadline` se diferencian en ORDEN y en LÍMITE DE LATENCIA, no
#     en el merging (el bloque moderno fusiona bios igual con los dos). Con una
#     única corriente secuencial dan lo mismo, así que el test A es el CONTROL y
#     tiene que salir parejo. Si A difiere mucho, el problema no es el scheduler.
#   - La diferencia aparece bajo CARGA MIXTA, que es lo que pasa en un escritorio:
#     algo lee en orden (abrir un juego, cargar un proyecto) mientras algo escribe
#     al azar (una instalación, un balance de btrfs). `none` no acota la espera;
#     `mq-deadline` sí (~500 ms). El test C mide exactamente eso.
#   - direct=1 en todo: sin esto se mide la page cache, no el disco.
#   - XFS (/home) como medida principal porque la raíz es btrfs con compress=zstd
#     y space_cache, que reordena por su cuenta y tapa la señal del bloque. La
#     segunda pasada sobre btrfs confirma que la dirección se mantiene.
set -uo pipefail

DEV=sda
SCHED=/sys/block/$DEV/queue/scheduler
ORIG="$(sed -n 's/.*\[\([a-z0-9_-]*\)\].*/\1/p' "$SCHED")"
OUT=/tmp/iotest
DUR_A=20; DUR_B=20; DUR_C=40
SIZE=2G
JOBS="$OUT/jobs"

cleanup() {
  [ -n "${ORIG:-}" ] && printf '%s\n' "$ORIG" > "$SCHED" 2>/dev/null
  # si algo falla a medias no dejamos ficheros de root en tu /home
  rm -f /home/cizen/.iotest/*.dat /var/tmp/iotest/*.dat 2>/dev/null
  rmdir /home/cizen/.iotest /var/tmp/iotest 2>/dev/null
  echo "Scheduler restaurado a: $(sed -n 's/.*\[\([a-z0-9_-]*\)\].*/\1/p' "$SCHED" 2>/dev/null)"
  return 0
}
trap cleanup EXIT INT TERM

current() { sed -n 's/.*\[\([a-z0-9_-]*\)\].*/\1/p' "$SCHED"; }

# average queue depth del dispositivo = Δweighted_time_ms / Δelapsed_ms.
# (los dos en ms: si el divisor va en segundos, el resultado sale 1000x alto)
# En /sys/block/sda/stat los campos son: 9 ios_in_progress, 10 io_ticks,
# 11 weighted_time (ms), 12 descartes. Leer el 12 da descartes y avgq=0.00.
avgq() {
  awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN{
    n=split(a,A," "); split(b,B," "); d=B[11]-A[11];
    if (s>0) printf "%.2f", d/(s*1000) }'
}
drop_caches() { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }

# ---- ficheros de job de fio ---------------------------------------------
# ioengine=libaio es OBLIGATORIO en los tests con iodepth>1. El motor por
# defecto de fio es psync (sincrono) y en ese caso avisa por stderr
#   "note: both iodepth >= 1 and synchronous I/O engine are selected,
#    queue depth will be capped at 1"
# y ejecuta a QD1. Medido en esta maquina: 3272 iops con psync frente a 54409
# con libaio a iodepth=16, 16,6x. Un test "saturado" a QD1 real no mide nada.
mk_jobs() { # $1=etiqueta
  cat > "$JOBS/$1.A.fio" <<EOF
[sec]
rw=read
bs=64k
iodepth=1
direct=1
ioengine=libaio
directory=$2
filename=a.dat
size=$SIZE
time_based
runtime=$DUR_A
EOF
  cat > "$JOBS/$1.B.fio" <<EOF
[randread]
rw=randread
bs=4k
iodepth=16
direct=1
ioengine=libaio
directory=$2
filename=a.dat
size=$SIZE
time_based
runtime=$DUR_B
EOF
  cat > "$JOBS/$1.C.fio" <<EOF
[lector]
rw=read
bs=64k
iodepth=1
direct=1
ioengine=libaio
directory=$2
filename=c_lector.dat
size=$SIZE
time_based
runtime=$DUR_C

[escritor]
rw=randwrite
bs=4k
iodepth=16
direct=1
ioengine=libaio
directory=$2
filename=c_escritor.dat
size=$SIZE
time_based
runtime=$DUR_C
EOF
  cat > "$JOBS/$1.D.fio" <<EOF
[randwrite]
rw=randwrite
bs=4k
iodepth=16
direct=1
ioengine=libaio
directory=$2
filename=d.dat
size=$SIZE
time_based
runtime=$DUR_B
EOF
}

# ---- una pasada con el scheduler activo --------------------------------
run_pass() { # $1=etiqueta $2=directorio
  local tag="$1" dir="$2" s0 s1
  mkdir -p "$dir" || return 1
  mk_jobs "$tag" "$dir"

  drop_caches; s0=$(cat /sys/block/$DEV/stat)
  fio "$JOBS/$tag.A.fio" --output-format=json --output="$OUT/$tag.A.json" --eta=never >/dev/null 2>&1
  s1=$(cat /sys/block/$DEV/stat); echo "  A  avgq=$(avgq "$s0" "$s1" "$DUR_A")"

  drop_caches; s0=$(cat /sys/block/$DEV/stat)
  fio "$JOBS/$tag.B.fio" --output-format=json --output="$OUT/$tag.B.json" --eta=never >/dev/null 2>&1
  s1=$(cat /sys/block/$DEV/stat); echo "  B  avgq=$(avgq "$s0" "$s1" "$DUR_B")"

  drop_caches; s0=$(cat /sys/block/$DEV/stat)
  fio "$JOBS/$tag.C.fio" --output-format=json --output="$OUT/$tag.C.json" --eta=never >/dev/null 2>&1
  s1=$(cat /sys/block/$DEV/stat); echo "  C  avgq=$(avgq "$s0" "$s1" "$DUR_C")"

  drop_caches
  fio "$JOBS/$tag.D.fio" --output-format=json --output="$OUT/$tag.D.json" --eta=never >/dev/null 2>&1

  rm -f "$dir"/a.dat "$dir"/c_lector.dat "$dir"/c_escritor.dat "$dir"/d.dat
}

mkdir -p "$OUT" "$JOBS"
# vaciar el directorio ANTES de medir: si un test no escribe salida (falla, se
# cuelga, se corta), su fichero viejo se leeria como si fuera de esta corrida y
# contaminaria el informe. Aquí se puede porque el script corre como root.
rm -f "$OUT"/*.json
echo "Dispositivo : /dev/$DEV"
echo "Scheduler   : $ORIG (se restaura al terminar, pase lo que pase)"
echo "Ficheros    : $SIZE, direct=1, drop_caches entre tests"
echo

# cada directorio se usa solo si de verdad está en /dev/sda
run_dir() { # $1=etiqueta_fs $2=dir
  local tag_fs="$1" dir="$2" src
  # el directorio tiene que existir ANTES de preguntarle a findmnt: sobre una
  # ruta inexistente findmnt no devuelve nada y todo se salta en silencio.
  # Y si la ruta ya la ocupa un fichero, mkdir -p falla y volveríamos a medir
  # cero sin enterarnos: eso se dice, no se ignora.
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo ">> ERROR: $dir existe y NO es un directorio ($(stat -c %F "$dir"), $(stat -c %s "$dir") bytes)."
    echo ">>        bórralo o cambia el nombre en el script; no se mide aquí."
    return 1
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo ">> ERROR: no se pudo crear $dir; se aborta ese fs."
    return 1
  fi
  src="$(findmnt -no SOURCE --target "$dir" 2>/dev/null)"
  if ! printf '%s' "$src" | grep -q "^/dev/$DEV"; then
    echo ">> $dir se omite: está en ${src:-(nada)}, no en /dev/$DEV"
    return
  fi
  echo ">> $tag_fs  dir=$dir  fs=$(stat -f -c %T "$dir")  origen=$src"
  for want in none mq-deadline; do
    case "$want" in
      none)         short=none ;;
      mq-deadline)  short=mq ;;
    esac
    tag="$tag_fs.$short"
    printf '%s\n' "$want" > "$SCHED" || { echo "   no se pudo cambiar el scheduler"; exit 1; }
    [ "$(current)" = "$want" ] || echo "   AVISO: el kernel no aceptó $want"
    run_pass "$tag" "$dir"
  done
}

run_dir xfs   /home/cizen/.iotest
run_dir btrfs /var/tmp/iotest

# ---- informe ------------------------------------------------------------
python3 - "$OUT" <<'PY'
#!/usr/bin/env python3
"""Reinforme de los JSON de fio.

Ojo al esquema de fio 3.42: no hay iops/bw_bytes/clat_ns en el nivel superior
del job; viven dentro de job['read'] / job['write']. Y iodepth_level no es un
número, es un histograma {profundidad de cola: % del tiempo}.
"""
import json, os, re, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/iotest"

TESTS = [
    ("A", "sec",       "read",  "A  seq-read QD1  (control)"),
    ("B", "randread",  "read",  "B  rand-read QD16"),
    ("C", "lector",    "read",  "C  LECTOR seq QD1  <-- decide"),
    ("C", "escritor",  "write", "C  escritor rand QD16"),
    ("D", "randwrite", "write", "D  rand-write QD16"),
]

def depth(k):
    return int(re.sub(r"[^0-9]", "", k))

def qstats(h):
    """(profundidad media, % del tiempo con 8+ en vuelo)."""
    tot = sum(h.values()) or 1.0
    mean = sum(depth(k) * v for k, v in h.items()) / tot
    deep = sum(v for k, v in h.items() if depth(k) >= 8) / tot * 100
    return mean, deep

def load(tag, t):
    p = os.path.join(OUT, f"{tag}.{t}.json")
    if not os.path.exists(p):
        return None
    try:
        return json.load(open(p)).get("jobs", [])
    except Exception as e:
        print(f"  !! {p}: {e}")
        return None

def get(j, direction):
    d = j.get(direction) or {}
    pct = (d.get("clat_ns") or {}).get("percentile") or {}
    ms = lambda k: pct.get(k, 0) / 1e6
    return {
        "iops": d.get("iops", 0) or 0,
        "mb":   (d.get("bw_bytes", 0) or 0) / 1e6,
        "p50":  ms("50.000000"), "p95": ms("95.000000"),
        "p99":  ms("99.000000"), "p999": ms("99.900000"),
        "ql":   qstats(j.get("iodepth_level") or {}),
        "err":  j.get("error", 0) or 0,
    }

def pct_delta(a, b):
    return (b - a) / a * 100 if a else 0.0

COLS = [("iops", 9, 0), ("mb", 8, 0), ("p50", 8, 2), ("p95", 8, 2),
        ("p99", 9, 2), ("p999", 9, 2)]

H = f"{'medida':<30}{'iops':>9}{'MB/s':>8}{'p50':>8}{'p95':>8}{'p99':>9}{'p99.9':>9}{'qlen':>7}{'%>=8':>7}"
DEL = (f"{'delta mq-deadline vs none':<30}{'iops':>8}%{'MB/s':>8}"
       f"{'p50':>8}{'p95':>8}{'p99':>9}{'p99.9':>9}{'qlen':>8}")

for fs, label in (("xfs", "XFS (/dev/sda3)"),
                  ("btrfs", "BTRFS (/dev/sda2, compress=zstd)")):
    if not any(f.startswith(fs + ".") for f in os.listdir(OUT)):
        continue
    print("\n" + "=" * len(H))
    print(f"  {label} — latencias en ms")
    print(H); print("-" * len(H))
    for t, job, direction, desc in TESTS:
        pair = {}
        for short, sched in (("none", "none"), ("mq", "mq-deadline")):
            jobs = load(f"{fs}.{short}", t)
            if not jobs:
                continue
            j = next((x for x in jobs if x.get("jobname") == job), None)
            if j:
                pair[sched] = get(j, direction)
        if not pair:
            print(f"  {desc:<28}  (sin datos)"); continue
        for sched in ("none", "mq-deadline"):
            if sched not in pair:
                continue
            v = pair[sched]
            mark = " " if sched == "none" else "↳"
            cells = "".join(f"{v[n]:>{w}.{p}f}" for n, w, p in COLS)
            print(f"{mark} {desc:<28}{cells}{v['ql'][0]:>7.2f}{v['ql'][1]:>7.0f}")
        if len(pair) == 2:
            a, b = pair["none"], pair["mq-deadline"]
            cells = (f"{pct_delta(a['iops'],b['iops']):>8.1f}%"
                     f"{pct_delta(a['mb'],b['mb']):>7.1f}%" +
                     "".join(f"{pct_delta(a[n],b[n]):>{w-1}.1f}%"
                             for n, w, p in COLS if n in ("p50","p95","p99","p999")))
            print(f"{DEL[:30]}{cells}{pct_delta(a['ql'][0],b['ql'][0]):>8.2f}")
    print("-" * len(H))

print("\nqlen = profundidad media de la cola del job; %>=8 = porcentaje del tiempo")
print("con 8+ peticiones en vuelo (saturación de la cola).")
PY

echo
echo "Ultimo scheduler usado: $(current)  (la trampa del EXIT restaura $ORIG al salir)"

# Guardia final: si no se produjo nada, el script ha fallado en silencio y hay
# que decirlo con voz alta, porque una tabla vacía parece un resultado.
n=$(ls -1 "$OUT"/*.json 2>/dev/null | wc -l)
if [ "$n" -eq 0 ]; then
  echo
  echo "############################################################"
  echo "##  NO SE MEDIO NADA. 0 ficheros JSON.                    ##"
  echo "##  Esto NO es un resultado: es un fallo de la medicion.   ##"
  echo "############################################################"
  exit 1
fi
echo "Mediciones: $n ficheros JSON en $OUT"
