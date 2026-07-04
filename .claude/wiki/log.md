# Журнал вики

## [2026-07-04] ingest | Первичная компиляция вики

Развёрнута llm-wiki по пакету beads-llm-wiki: overview, entities
(shared-stack, php-base-image, nginx-edge), concepts (contracts,
deployment-topologies), integrations (app-stacks, gpu-services), index.
Источник — кодовая база и документы `docs/` (спека дизайна, runbook
боевого переезда 2026-07-04). decisions/ пуста — наполняется при закрытии
задач beads.
## [2026-07-04] ingest | Развёрнута копия doitai.ru («всё внутри», CPU): инфра-стек без overlay (LE-серт certs-init), три приложения+фронт (бренд doitai), ollama-router+ollama CPU (qwen3:8b, embeddinggemma), pdn-cleaner CPU-образ (ждёт HF_TOKEN для модели), деплой GitHub Actions в пяти репо. Гочи: root-овый dist от bind-mount, --env-file для compose-файлов в подпапке, диск 82% после моделей
## [2026-07-04] ingest | doitai.ru переведён на внешние Ollama/pdn (192.168.101.114, связность проверена): в облаке тикет по GPU; локальный CPU-пул ollama свёрнут (volume моделей удалён, диск 82%→68%), env приложений переключены, воркеры стабильны, api/app 200. CPU-заготовки остаются в репозиториях до появления GPU
