# lpminer Docker Image

Docker image for **lpminer v0.1.7** — LuckyPool Pearl Miner, built automatically via GitHub Actions.

## Docker Hub

```
docker pull <DOCKERHUB_USERNAME>/lpminer:latest
```

## Cara Pakai

```bash
docker run --rm --gpus all \
  <DOCKERHUB_USERNAME>/lpminer:latest \
  lpminer \
  --pool stratum+tcp://pearl.luckypool.io:PORT \
  --wallet YOUR_WALLET_ADDRESS \
  --worker YOUR_WORKER_NAME
```

## Build Manual

```bash
docker build -t lpminer:local .
```

## Setup GitHub Actions (sekali saja)

1. Buka repo GitHub → **Settings → Secrets and variables → Actions**
2. Tambahkan dua **Repository secrets**:
   - `DOCKERHUB_USERNAME` → username Docker Hub kamu
   - `DOCKERHUB_TOKEN`    → Access Token dari Docker Hub (bukan password)

> Buat token di: https://hub.docker.com/settings/security

3. Push ke branch `main` → image otomatis build & push ke Docker Hub.

## Tag yang Dihasilkan

| Event | Tag |
|-------|-----|
| Push ke `main` | `latest` |
| Push tag `v0.1.7` | `0.1.7`, `0.1`, `latest` |
| Setiap commit | `sha-xxxxxxx` |
