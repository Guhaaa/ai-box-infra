# Индекс вики ai-box-infra

## Корень

- [[overview]] — обзор репозитория и статус переезда.

## Сущности (`entities/`)

- [[entity:shared-stack]] — сервисы compose и overlay-файлы окружений.
- [[entity:php-base-image]] — общий базовый PHP-образ приложений.
- [[entity:nginx-edge]] — вход: шаблоны vhost'ов, TLS, внутренние порты.

## Концепции (`concepts/`)

- [[concept:contracts]] — контракты для приложений (имена, порты, Redis-индексы, пути).
- [[concept:deployment-topologies]] — модели размещения, окружения, чек-лист нового хоста.

## Интеграции (`integrations/`)

- [[integration:app-stacks]] — eco-стеки ai-box/DR/MCP и фронт.
- [[integration:gpu-services]] — ollama-router и pdn-cleaner (сплит).

## Решения (`decisions/`)

- [[decision:orchestration-no-k8s]] — оркестрация: docker-compose, не k8s; bootstrap скриптом, не Ansible.
- [[decision:voice-dictation]] — nginx-проксирование ASR ws-потока голосовой диктовки (auth_request + внешний ASR).
- [[decision:nginx-template-rendering]] — рендер nginx-шаблонов на деплое (envsubst только в entrypoint → тихий no-op).
- (прочая дизайн-история до вики — в `docs/superpowers/specs/` и runbook'ах)
