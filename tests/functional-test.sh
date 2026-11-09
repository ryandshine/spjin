#!/usr/bin/env bash
# PDFin functional test — usage: tests/functional-test.sh <BASE_URL> [env-file]
# Reads PDFIN_ADMIN_USERNAME / PDFIN_ADMIN_PASSWORD from env-file (default ../.env). Never prints secrets.
set -uo pipefail
BASE="${1:?base url, e.g. https://pdfin.ditpps.com}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ENVF="${2:-$DIR/../.env}"
FX="$DIR/fixtures"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
U=$(grep -E '^PDFIN_ADMIN_USERNAME=' "$ENVF" | cut -d= -f2-)
P=$(grep -E '^PDFIN_ADMIN_PASSWORD=' "$ENVF" | cut -d= -f2-)
pass=0; fail=0
ok(){ echo "PASS  $*"; pass=$((pass+1)); }
ko(){ echo "FAIL  $*"; fail=$((fail+1)); }

# 0. health (public, no secret)
s=$(curl -fsS --max-time 15 "$BASE/api/v1/info/status") && ok "health: $s" || ko "health"

# 1. anonymous access must be rejected
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -F "fileInput=@$FX/one.pdf" -F optimizeLevel=2 -F grayscale=false -F linearize=false -F normalize=false "$BASE/api/v1/misc/compress-pdf")
[[ "$c" == 401 || "$c" == 403 ]] && ok "anonymous API rejected ($c)" || ko "anonymous API returned $c"
c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/user/users")
[[ "$c" == 401 || "$c" == 403 ]] && ok "anonymous admin endpoint rejected ($c)" || ko "anonymous admin endpoint returned $c"

# 2. wrong password rejected (uses a throwaway username so the admin account is never locked)
c=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"nobody-test","password":"wrong-password"}' "$BASE/api/v1/auth/login")
[[ "$c" == 401 || "$c" == 403 ]] && ok "bad credentials rejected ($c)" || ko "bad credentials returned $c"

# 3. login
J=$(python3 -c 'import json,sys;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$U" "$P")
R=$(curl -s -H 'Content-Type: application/json' -d "$J" "$BASE/api/v1/auth/login")
T=$(printf '%s' "$R" | python3 -c 'import json,sys
d=json.load(sys.stdin)
s=d.get("session") or {}
print(d.get("access_token") or d.get("accessToken") or d.get("token") or s.get("access_token") or "")' 2>/dev/null)
if [[ -n "$T" ]]; then ok "admin login (JWT issued)"; else ko "admin login: $(printf '%s' "$R" | head -c 200)"; exit 1; fi
AUTH=(-H "Authorization: Bearer $T")
c=$(curl -s -o "$OUT/me.json" -w '%{http_code}' "${AUTH[@]}" "$BASE/api/v1/auth/me")
[[ "$c" == 200 ]] && ok "auth/me ($(python3 -c 'import json;d=json.load(open("'"$OUT/me.json"'"));u=d.get("user",d);print(u.get("username"),u.get("role") or u.get("roles") or "")' 2>/dev/null))" || ko "auth/me $c"

pages(){ pdfinfo "$1" 2>/dev/null | awk '/^Pages:/{print $2}'; }
run(){ # name endpoint outfile curl-args...
  local n="$1" ep="$2" of="$3"; shift 3
  local c; c=$(curl -s -o "$OUT/$of" -w '%{http_code}' --max-time 300 "${AUTH[@]}" "$@" "$BASE$ep")
  if [[ "$c" == 200 && -s "$OUT/$of" ]]; then echo "$c"; else echo "ERR$c"; fi
}

# 4. upload + merge (3 + 1 pages = 4) + download
c=$(run merge /api/v1/general/merge-pdfs merged.pdf -F "fileInput=@$FX/scan3.pdf" -F "fileInput=@$FX/one.pdf" -F sortType=orderProvided -F removeCertSign=false)
n=$(pages "$OUT/merged.pdf"); [[ "$c" == 200 && "$n" == 4 ]] && ok "upload+merge+download -> $n pages" || ko "merge ($c, pages=$n)"

# 5. split after page 1 -> zip with 2 PDFs
c=$(run split /api/v1/general/split-pages split.out -F "fileInput=@$FX/scan3.pdf" -F pageNumbers=1)
if [[ "$c" == 200 ]]; then
  k=$(python3 -c 'import zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);print(len([n for n in z.namelist() if n.endswith(".pdf")]))' "$OUT/split.out" 2>/dev/null || echo "?")
  [[ "$k" == 2 ]] && ok "split -> $k PDFs in zip" || ko "split output parts=$k"
else ko "split ($c)"; fi

# 6. compress
c=$(run compress /api/v1/misc/compress-pdf comp.pdf -F "fileInput=@$FX/scan3.pdf" -F optimizeLevel=5 -F grayscale=false -F linearize=false -F normalize=false)
[[ "$c" == 200 && "$(pages "$OUT/comp.pdf")" == 3 ]] && ok "compress $(stat -c%s "$FX/scan3.pdf")B -> $(stat -c%s "$OUT/comp.pdf")B" || ko "compress ($c)"

# 7. OCR (image-only PDF -> searchable text)
c=$(run ocr /api/v1/misc/ocr-pdf ocr.pdf -F "fileInput=@$FX/scan3.pdf" -F languages=eng -F ocrType=force-ocr -F ocrRenderType=hocr -F sidecar=false -F deskew=false -F clean=false -F cleanFinal=false -F rotatePages=false -F removeImagesAfter=false)
if [[ "$c" == 200 ]]; then
  txt=$(pdftotext "$OUT/ocr.pdf" - 2>/dev/null | tr -s '[:space:]' ' ')
  [[ "$txt" == *"PDFin"* && "$txt" == *"OCR"* ]] && ok "OCR text extracted: '$(echo "$txt" | head -c 60)'" || ko "OCR produced no expected text: '$(echo "$txt" | head -c 80)'"
else ko "ocr ($c)"; fi

# 8. rotate 90
c=$(run rotate /api/v1/general/rotate-pdf rot.pdf -F "fileInput=@$FX/one.pdf" -F angle=90)
rot=$(pdfinfo "$OUT/rot.pdf" 2>/dev/null | awk '/^Page rot:/{print $3}')
[[ "$c" == 200 && "$rot" == 90 ]] && ok "rotate -> Page rot $rot" || ko "rotate ($c, rot=$rot)"

# 9. rearrange (3,1,2) -> verify page order via text of OCR'd merged? use reverse on OCR'd doc
c=$(run rearrange /api/v1/general/rearrange-pages rearr.pdf -F "fileInput=@$OUT/ocr.pdf" -F customMode=CUSTOM -F pageNumbers=3,1,2)
first=$(pdftotext -f 1 -l 1 "$OUT/rearr.pdf" - 2>/dev/null | tr -s '[:space:]' ' ')
[[ "$c" == 200 && "$(pages "$OUT/rearr.pdf")" == 3 && "$first" == *"halaman 3"* ]] && ok "rearrange 3,1,2 -> first page: '$(echo "$first" | head -c 30)'" || ko "rearrange ($c, first='$first')"

echo "----"; echo "RESULT: $pass passed, $fail failed"; [[ $fail == 0 ]]
