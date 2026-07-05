---
title: Оркестрация — docker-compose, не Kubernetes; bootstrap скриптом, не Ansible
type: decision
tags: [infrastructure, orchestration, decision]
sources: [docker-compose.yml, docs/runbooks]
updated: 2026-07-05
---

# Оркестрация: docker-compose, не Kubernetes

## Решение (2026-07-05, согласовано с владельцем)

Экосистема остаётся на **docker-compose** как оркестраторе. Kubernetes
**не вводим**. Host-провижининг (драйвер GPU, docker, диски) кодифицируем
**идемпотентным bootstrap-скриптом**, а не Ansible.

## Контекст

Возник вопрос: не перейти ли с docker-compose на k8s, и нужен ли Ansible
для раскатки серверов. Разобрано и отклонено.

## Почему НЕ Kubernetes

- **Разные слои.** k8s заменил бы docker-compose (оркестрация контейнеров),
  а не host-bootstrap. Даже под k8s ноды всё равно надо провижинить
  (nvidia-driver, containerd, диски) — «k8s вместо Ansible» некорректно.
- **Масштаб.** 2 сервера (addons-прод, doitai), ~15 контейнеров. k8s
  окупается на десятках нод с динамическим масштабом; здесь control-plane
  (etcd/API/CNI/ingress/CSI) — чистый оверхед на обслуживание.
- **Shared-GPU конфликт (главное).** Три модели на одной RTX 2080 Ti
  (qwen + embeddinggemma + pdn BERT шарят карту, см. [[integration:gpu-services]]).
  k8s nvidia device-plugin по умолчанию отдаёт GPU **целиком одному поду**;
  шеринг одной карты требует time-slicing/MPS — в k8s сложно и хрупко.
  В compose это просто работает.
- **Stateful-тяжесть.** MariaDB/Qdrant/модели на локальных дисках, разложены
  вручную по скорости (быстрый sda под БД, медленный sdb под образы/модели,
  см. [[concept:deployment-topologies]]). В k8s — StatefulSet + PV +
  storage-class, сложнее без выигрыша на 2 нодах.
- **Всё работает.** compose + shared-infra + GitHub Actions (push →
  `make eco-deploy`) + параллельные копии. Миграция = переписать всё
  (Helm, ingress, secrets, PV) без выгоды на этом масштабе.

## Почему bootstrap-скрипт, а не Ansible

Задача провижининга — воспроизвести то, что делалось руками в июле 2026
(nvidia-driver + libcuda1 + toolkit + runtime, docker + compose-plugin,
apt non-free, диски/fstab, docker data-root+containerd на отдельный диск).
Для 2 серверов **идемпотентный shell-скрипт** (или cloud-init) проще в
сопровождении, чем Ansible (inventory/роли окупаются на многих хостах).

## Когда пересмотреть

- **k8s** — если появится 5+ нод, реальный авто-масштаб под нагрузкой, или
  выделенная GPU-ферма (карты раздаются подам целиком — там device-plugin
  к месту), либо managed-кластер (EKS/GKE), где control-plane не ваша забота.
- **Ansible** — если серверов станет заметно больше и bootstrap-скрипт
  перестанет масштабироваться.

## Связи

- [[integration:gpu-services]]
- [[concept:deployment-topologies]]
- [[overview]]
