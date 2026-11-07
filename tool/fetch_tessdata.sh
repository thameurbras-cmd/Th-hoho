#!/usr/bin/env bash
# ينزّل نموذجي العربية والفرنسية إلى assets/tessdata. يفشل صراحةً إن لم ينجح.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/tessdata"
mkdir -p "$DIR"

# العربية: tessdata_best (أدق)،  الفرنسية: tessdata_fast (أخف)
get() {  # $1=lang  $2=repo
  local out="$DIR/$1.traineddata"
  curl -fL --retry 3 -o "$out" \
    "https://github.com/tesseract-ocr/$2/raw/main/$1.traineddata"
  local size; size=$(wc -c < "$out")
  if [ "$size" -lt 500000 ]; then
    echo "خطأ: $1.traineddata صغير جداً ($size بايت) - التنزيل فاشل" >&2
    exit 1
  fi
  echo "ok $1 ($size bytes, $2)"
}
get ara tessdata_best
get fra tessdata_fast
