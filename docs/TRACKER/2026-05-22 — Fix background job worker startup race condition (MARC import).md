---
title: Fix background job worker startup race condition (MARC import)
date: 2026.05.22
tags:
 - worker
 - race
 - import
---
# 2026-05-22 — Fix background job worker startup race condition (MARC import)

## Problem

Every batch background process (e.g. "Stage MARC for import", "Import staged MARC records") would behave unreliably because the background job workers started before RabbitMQ was ready to accept STOMP connections.

**Root cause:** In `files/run.sh` the startup order was:

1. `service koha-common start` — starts background job workers (which try to connect to STOMP on port 61613 exactly **once** at startup)
2. `service apache2 start`
3. `service rabbitmq-server start` — RabbitMQ (STOMP broker) starts **after** workers

Because workers attempt the STOMP connection only once, they always failed and fell back to polling `background_jobs` DB table every 10 seconds. While the DB-polling fallback does work (jobs are still processed), it means workers never benefit from instant Stomp notifications. More importantly, in some scenarios where the `JobsNotificationMethod` system preference is set to `STOMP`, the enqueue process sends a Stomp notification which is delivered to a RabbitMQ queue that nobody is subscribed to (workers are in poll mode), effectively losing the "push" trigger.

**Confirmed via:** `worker-output.