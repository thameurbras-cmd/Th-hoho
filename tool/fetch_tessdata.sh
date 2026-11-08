#!/usr/bin/env bash
# ينزّل نموذجي العربية والفرنسية إلى assets/tessdata.
# يعيد المحاولة عند انقطاع الشبكة، ويجرّب مصدراً بديلاً، ويفشل صراحةً إن لم ينجح.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/tessdata"
mkdir -p "$DIR"

get() {  # $1=lang  $2=repo
  local lang="$1" repo="$2"
  local out="$DIR/$lang.traineddata"
  local urls=(
    "https://github.com/tesseract-ocr/$repo/raw/main/$lang.traineddata"
    "https://raw.githubusercontent.com/tesseract-ocr/$repo/main/$lang.traineddata"
    "https://cdn.jsdelivr.net/gh/tesseract-ocr/$repo@main/$lang.traineddata"
  )
  for attempt in 1 2 3; do
    for url in "${urls[@]}"; do
      echo "try $attempt: $url"
      rm -f "$out"
      if curl -fL --retry 3 --retry-all-errors --retry-delay 3 \
          --connect-timeout 20 --max-time 300 -o "$out" "$url"; then
        local size; size=$(wc -c < "$out")
        if [ "$size" -ge 500000 ]; then
          echo "ok $lang ($size bytes, $repo)"
          return 0
        fi
        echo "ملف صغير ($size بايت)، أجرّب مصدراً آخر"
      fi
    done
    sleep 5
  done
  echo "خطأ: فشل تنزيل $lang.traineddata من كل المصادر" >&2
  return 1
}

get ara tessdata_best || exit 1
get fra tessdata_fast || exit 1
