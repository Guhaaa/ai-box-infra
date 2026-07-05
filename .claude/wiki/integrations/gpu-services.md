---
title: GPU-сервисы — ollama-router и pdn-cleaner
type: integration
tags: [gpu, ollama, pdn, split]
sources: [README.md, docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md]
updated: 2026-07-05
---

# GPU-сервисы

Два сервиса с NVIDIA-зависимостью.

**doitai.ru (2026-07-05): GPU установлен, ollama переведён на карту.**
RTX 2080 Ti (11 GiB), драйвер 550.163.01 (DKMS под ядро 6.12.94), NVIDIA
Container Toolkit 1.19, nvidia runtime в docker. ollama-router — single-GPU
режим (`docker-compose.gpu-single.yml` + `config.single.yaml`), модели на
отдельном диске `/mnt/data/ollama` (`OLLAMA_MODELS_DIR`); qwen3:8b-q4_K_M
100% GPU, ~85 ток/с. Приложения doitai (осн.+тест) ходят на локальный
`ollama-router:11434`. **pdn-cleaner тоже на GPU** (2026-07-05): GPU-образ
(torch cu124), модель на `/mnt/data/pdn-models`, BERT-NER на карте
(`torch.cuda.is_available()`), маскирование проверено. ollama и pdn делят
одну карту, **модели держатся в VRAM постоянно** (не грузятся на запрос):
qwen3:8b 6.2G + embeddinggemma 0.8G + pdn BERT 0.87G = ~7.9G из 11G.
PDN_CLEANER_URL приложений (осн+тест) → `ai-box-pdn-cleaner:8000`.

**Как модели удерживаются в VRAM (боевые находки):**
- ollama: `min_replicas` hints в config.single.yaml → preloader роутера шлёт
  warm-up с keep_alive=-1 при старте. НО preloadModel слал только
  `/api/generate` — для embedding-модели (embeddinggemma) он не удерживает
  её в VRAM (нужен `/api/embed`); добавлен fallback generate→embed в
  router.go preloadModel;
- pdn: `warmup()` грузил модель без `.to(device)` → BERT работал на CPU
  несмотря на GPU-образ; патч api.py (модель на cuda при warmup, вызывается
  в FastAPI lifespan на старте) + inference/bert.py (входы на device модели,
  логиты на CPU). CPU-fallback сохранён.

Грабли установки GPU (боевые уроки, вшиты в конфиги):
- метапакет `nvidia-driver` НЕ тянет `libcuda1` → без libcuda.so.1
  `nvidia-smi` работает (utility), но CUDA N/A и инференс на CPU;
  ставить `libcuda1` явно;
- nvidia-runtime через `deploy.reservations.devices` даёт только utility —
  нужен `NVIDIA_DRIVER_CAPABILITIES=compute,utility` в env (иначе CPU) —
  касается И ollama, И pdn (torch не видит CUDA);
- одна карта → single-GPU override ollama (второй инстанс под profile multi);
- у pdn и ollama compose-файлы в подкаталогах (.docker/ и docker/) → имя
  проекта по умолчанию «docker» пересекается; заданы явные `name:`
  (ai_box_pdn / ollama_router), иначе remove-orphans одного убьёт другой;
- pdn GPU-образ (полный cu124-стек: cudnn/cublas/triton) тяжёл для сборки
  (пик ~25G из-за дублирования uv-кэша) → `UV_NO_CACHE=1` в Dockerfile;
  диск sdb расширен до 50G (hot-resize online).

В прод-сплите (addons) GPU-сервисы работают по-старому на LAN-хосте
`192.168.101.114`:

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
