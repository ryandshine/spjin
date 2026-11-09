# PDFin — Runbook (Stirling-PDF via Dokploy)

| Item | Nilai |
|---|---|
| URL | https://pdfin.ditpps.com |
| Image | `docker.stirlingpdf.com/stirlingtools/stirling-pdf:${STIRLING_VERSION}` (dipin, awal: `3.3.0`) |
| Port internal | 8080 (tidak dipublish ke host; diakses Traefik lewat `dokploy-network`) |
| Resource | `mem_limit 4g`, `mem_reservation 1g`, `cpus 4`, `pids_limit 2048` |
| Volume | `pdfin-configs` (/configs: settings.yml + DB H2 + backup/db + key), `pdfin-storage`, `pdfin-logs`, `pdfin-customfiles`, `pdfin-pipeline`, `pdfin-tessdata` |
| Secret | Dokploy → Environment: `PDFIN_ADMIN_USERNAME`, `PDFIN_ADMIN_PASSWORD`, `STIRLING_VERSION`. Salinan lokal: `~/pdfin/.env` (chmod 600, jangan di-commit) |

## 1. Deploy di Dokploy (UI)
1. Project baru **PDFin** → Create Service → **Compose** → nama `pdfin`, type *Docker Compose*.
2. Provider **GitHub** → repo `ryandshine/spjin`, branch `main`, compose path `./docker-compose.yml`.
3. Tab **Environment** → tempel isi `~/pdfin/.env`.
4. Tab **Domains** → Add: host `pdfin.ditpps.com`, service `stirling-pdf`, port `8080`, path `/`, HTTPS **off**.
   DNS `pdfin` = CNAME ke Cloudflare Tunnel `etaseneu` (→ Traefik `http://127.0.0.1:80`); TLS ditangani Cloudflare.
   HTTPS-redirect di Traefik akan menyebabkan redirect loop lewat tunnel.
5. **Deploy**. Uji: `tests/functional-test.sh https://pdfin.ditpps.com`.

Catatan `SECURITY_INITIALLOGIN_*` hanya dipakai saat DB masih kosong. Mengganti password admin setelahnya dilakukan lewat UI (Settings → Account) dan `.env` perlu diperbarui manual.

## 2. Backup
- `scripts/backup.sh` → stop container ±1 menit, lalu arsipkan semua volume ke `/data/backups/pdfin/` (retensi 14).
- `scripts/backup.sh --hot` → tanpa downtime (DB H2 juga punya auto-backup sendiri di `/configs/backup/db`).
- Sekali saja, buat folder: `sudo mkdir -p /data/backups/pdfin && sudo chown ryandshinevps: /data/backups/pdfin`.
- Cron harian yang disarankan (user ryandshinevps): `30 2 * * * /home/ryandshinevps/pdfin/scripts/backup.sh --hot >> /data/backups/pdfin/backup.log 2>&1`
- Simpan juga salinan `.env` di tempat yang aman (password manager), karena tidak ikut di arsip.
- Komponen kritis: `/configs/credential-encryption.key` dan DB `stirling-pdf-DB-*.mv.db` (keduanya ada di arsip).

## 3. Restore
`scripts/restore.sh /data/backups/pdfin/pdfin-<versi>-<ts>.tar.gz`
Skrip ini membuat backup pengaman dulu, meminta konfirmasi `RESTORE`, lalu mengganti **isi** volume (volumenya sendiri tidak dihapus). Restore memakai versi image yang sama dengan versi di nama arsip.

## 4. Update image
1. Cek rilis: https://github.com/Stirling-Tools/Stirling-PDF/releases (baca breaking changes).
2. `scripts/backup.sh` (wajib sebelum update).
3. Dokploy → Environment → `STIRLING_VERSION=<versi baru>` → **Deploy** (volume tetap; **jangan** pakai opsi hapus volume).
4. `tests/functional-test.sh https://pdfin.ditpps.com`.

## 5. Rollback
1. Dokploy → Environment → kembalikan `STIRLING_VERSION=<versi lama>` → Deploy.
2. Bila DB sudah dimigrasi oleh versi baru dan versi lama gagal start, restore arsip dari langkah 4.2 (`scripts/restore.sh`).

## 5b. Bahasa OCR
Bawaan image: eng, deu, fra, por, chi_sim. Ditambahkan 2026-11-09: **ind** (`ind.traineddata` dari github.com/tesseract-ocr/tessdata),
disimpan di volume `pdfin-tessdata` (`/usr/share/tessdata`) dan otomatis disalin ke folder Tesseract setiap container start.
Menambah bahasa lain: `docker cp <lang>.traineddata <container>:/usr/share/tessdata/`, lalu restart container.

## 6. Pemeliharaan rutin
- Bulanan: cek rilis & update; uji restore ke project uji terpisah tiap kuartal.
- Pantau `docker stats`, log gagal login `/logs/invalid-auths.log` (bisa dipakai Fail2Ban).
- Analytics, URL-to-PDF: **OFF**.
- AI Engine: **ON** sejak 2026-11-09, disetujui pemilik. Container `stirling-pdf-engine` (port 5001 internal, butuh secret `PDFIN_ENGINE_SECRET`).
  Model chat `gpt-oss:20b-cloud` (env `PDFIN_AI_MODEL`; gemma4 gagal format JSON) lewat Ollama host berjalan di **Ollama Cloud**, jadi isi dokumen yang ditanyakan ke AI keluar dari server.
  Embedding `bge-m3` (multibahasa, mendukung Bahasa Indonesia) berjalan lokal. Untuk mematikan AI: set `AIENGINE_ENABLED: "false"` lalu Deploy.
  Ganti model: Dokploy env `PDFIN_AI_MODEL=<model ollama>`.
