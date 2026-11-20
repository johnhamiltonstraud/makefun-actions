# make.fun builds on GitHub Actions — mesin build ke-2

Tujuan: build entry make.fun (News 20) paralel di GitHub Actions, bukan cuma
2 lane di VM ini. Satu job Actions = satu wallet, satu build, satu submit.

## Status (21 Nov 2026 ~04:40 WIB)

- Paket ini SIAP deploy, BELUM ter-deploy. Dua hal butuh Ariel (tidak bisa
  ditebak / diambil dari VM):
  1. **GitHub auth**: `gh` di VM tidak login, tidak ada PAT. Perlu
     `gh auth login --scopes repo,workflow` sebagai johnhamiltonstraud
     (interaktif, browser/kode), atau PAT scope `repo` + `workflow`.
  2. **Xingchi API key (nilai asli)**: VM TIDAK menyimpan key plaintext —
     Codex di sini jalan via surrogate runtime yang tidak berlaku di luar VM,
     dan file `~/workspace/xingchiapi/api_key` tidak ada. Ariel yang pegang
     key-nya (yang di-reconnect 21 Nov 02:24 WIB) harus memasukkannya sendiri
     saat `deploy.sh` meminta (input tersembunyi, jangan paste di chat).
- Akun uji: **W210** (baru, wallet EfRoY8nU755DppBCbCZ1V3D652vRSkUtZ4b7veqfeAuR,
  ref 83 @silver-puffin-55 / p346xfan, handle belum ada sampai `register`).
  Diklaim di `referral165-progress.tsv` (status `actions-test`) + catatan
  `hidden_files/actions-test-w210-claim.md`. Koordinator lokal JANGAN pakai
  nomor 210 / ref 83.
- Kenapa W210: 8 akun tersisa (195, 201, 203, 205, 206, 208, 209) sedang
  dibangun lokal untuk News 19 saat paket ini dibuat; akun lain sudah submit
  News 20 (submit ulang = ganti entri final, berisiko). W210 bersih.
- Target: News 20, tutup 22 Nov 07:00 WIB. News 19 tidak terkejar (tutup
  21 Nov 07:00 WIB; setup Actions 2–4 jam).

## Pilihan publik vs privat — diputuskan: PRIVAT

- Privat: jatah $12/bulan = 2.000 menit Linux 2-core. Satu build lokal
  ~4–5 menit Codex + ~3–5 menit setup (node, codex, kit) = ~10–15 menit/job.
  Jadi ~130–200 build per bulan — cukup untuk 8 akun tersisa + 83 akun
  pool yang belum terdaftar, asal tidak semua dalam satu siklus tagihan.
- Publik (gratis tanpa batas) DITOLAK: repo ini membawa arsip kredensial
  terenkripsi + log build; di repo publik ciphertext-nya terlihat semua orang
  dan risiko bocor lewat log/artifact jauh lebih besar. Keamanan > menit gratis.

## Cara kerja (satu job)

1. Decrypt `credentials.tar.gz.gpg` (gpg AES256, passphrase dari Secret
   `ARCHIVE_PASSPHRASE`) → keypair + kredensial akun itu saja.
2. Install Codex 0.170.0 via npm (sama seperti VM) + profil Xingchi
   (`~/.codex/xingchi.config.toml`, model gpt-6.1-sol, key dari Secret
   `XINGCHI_API_KEY` — key tidak pernah di-print / di-log).
3. Download kit FRESH dari `https://make.fun/c/news-image-20261120/kit`
   (kit v27 di VM sudah stale — server level 29).
4. `register` bila akun belum punya kredensial (ref code dari input),
   lalu `init` (anchor drand) di repo entri yang dibuat di runner.
5. Prompt dari `prompts/news20-template.txt` (template prompt W196,
   desain "THE QUILL"; hanya anchor/round/staging/template yang diganti).
   Codex build dengan watchdog (mati 10 menit tanpa output, max 60 menit),
   rollout dicari BERDASARKAN ANCHOR (bukan newest — job paralel berbagi HOME).
6. `finish-news20-actions.sh`: validate 2x byte-identik → commit
   (author = alamat wallet) → bundle `--no-discover --no-family` →
   `check` → `submit`. Sukses = claim `AF-...` di `work/result.json`.
7. Sync-back: result JSON (+ kredensial baru terenkripsi, bila register di
   job ini) di-push ke branch `results` + di-upload sebagai artifact
   (retensi 7 hari). VM impor dengan `scripts/import-actions-result.sh 210`
   → update TSV + `hidden_files/w210-submissions.md`.

## Secrets (tidak ada yang di-commit)

| Secret | Isi | Diset dari |
|---|---|---|
| `XINGCHI_API_KEY` | Key Xingchi (Codex gpt-6.1-sol) | Ariel, interaktif saat `deploy.sh` meminta (prompt tersembunyi). JANGAN paste di chat. VM tidak punya key plaintext — hanya surrogate runtime. |
| `ARCHIVE_PASSPHRASE` | Passphrase arsip kredensial | `~/workspace/makefun-actions-passphrase.txt` (mode 600, DI LUAR repo) |

Arsip `credentials.tar.gz.gpg` dibuat `scripts/package-secrets.sh`
(dari keypair mode-600 di VM; verifikasi round-trip, tidak print secret).
Tambah wallet: `bash scripts/package-secrets.sh 210 211 ...` lalu push ulang.

## Deploy (setelah gh login)

```bash
bash scripts/deploy.sh        # buat repo privat, push, set 2 secret, dispatch W210
# pantau: https://github.com/johnhamiltonstraud/makefun-actions/actions
bash scripts/import-actions-result.sh 210   # setelah job sukses
```

## Skala ke 20 paralel

- Workflow pakai `workflow_dispatch` + `concurrency` per wallet (satu wallet
  tidak pernah jalan 2x bersamaan). Untuk 20 akun: dispatch 20x dengan
  wallet berbeda (atau tambah matrix + daftar wallet). Tiap job ~10–15 menit,
  20 paralel ≈ 200–300 menit dari jatah 2.000 — muat.
- SEBELUM skala: klaim dulu nomor + ref tiap akun di TSV (status
  `actions-test`), dan masukkan keypair-nya ke arsip via `package-secrets.sh`.
  Jangan pernah dispatch wallet yang sedang dibangun lokal — cek TSV dulu.
- Batas Actions: 1 job max 6 jam (build kita ~15 menit, aman); log/artifact
  jangan sampai berisi secret (workflow tidak pernah echo secret).

## Yang sudah teruji lokal (21 Nov ~04:30–04:45 WIB)

- Codex 0.170.0 + profil Xingchi dari HOME bersih (tanpa auth.json):
  smoke test tulis + jalanin `hello.py`, output `smoke-ok`, 19.820 token.
  Jadi pemanggilan `codex exec --profile xingchi` di workflow sudah benar.
- Kit FRESH dari `https://make.fun/c/news-image-20261120/kit`: CLI-nya BEDA
  dari v27 lokal (level 29) — download fresh di workflow itu keputusan benar.
  Bundle + check entri W196 dengan kit fresh: 15 passed, 0 failed.
- Validate deterministik (main.py W196 2x, sha sama, PNG 153.839 byte).
- `gen-prompt.py`, YAML workflow, semua script (`bash -n` + `py_compile`).
- Arsip kredensial: `package-secrets.sh` + round-trip gpg OK, tanpa secret
  yang ter-print / masuk repo (grep bersih).

## Yang belum teruji (butuh deploy + 2 hal dari Ariel di atas)

- End-to-end 1 run Actions nyata: `register` + `init` + build Codex
  (prompt penuh ~15 menit) + `bundle`/`check`/`submit` di runner, sampai
  claim `AF-...` SERVER-VERIFIED. Bila `check`/`submit` menolak karena kit,
  workflow sudah download kit fresh — bila masih ditolak, itu sinyal kit
  baru, bukan salah workflow.
