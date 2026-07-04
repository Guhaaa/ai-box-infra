---
title: GPU-сервисы — ollama-router и pdn-cleaner
type: integration
tags: [gpu, ollama, pdn, split]
sources: [README.md, docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md]
updated: 2026-07-04
---

# GPU-сервисы

Два сервиса с NVIDIA-зависимостью; в текущем проде (сплит) **не тронуты**
и работают по-старому на LAN-хосте `192.168.101.114`:

- **ollama-router** (репо ai-box-ollama-router) — Go-прокси + пул Ollama
  по одному на GPU, сейчас systemd. Авторизации нет → доступ только по
  закрытому каналу. Докеризация готова в репо (Dockerfile + docker/compose
  с GPU-пиннингом по UUID + ecosystem-override) — этап «всё внутри».
- **pdn-cleaner** (репо ai-box-bert-ner-train, GitHub ai-box-pdn-cleaner) —
  FastAPI-маскирование ПДн, standalone со своим pii-redis. Bearer-токен
  есть, но трафик с ПДн → тоже закрытый канал; `API_BIND` для публикации
  только на VPN-интерфейс. Ecosystem-override (общий Redis, docker-имя
  `ai-box-pdn-cleaner`) готов — этап «всё внутри».

Потребители конфигурируют `OLLAMA_BASE_URL`/`PDN_CLEANER_URL` через env и
от размещения не зависят.

## Связи

- [[concept:deployment-topologies]]
- [[concept:contracts]]
