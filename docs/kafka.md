# Kafka

Apache Kafka is the event bus between the Wonrich microservices. Services publish domain events; other services consume them asynchronously, so no service has to call another synchronously to learn that something happened.

---

## Conventions

| Item | Convention |
|---|---|
| Topic name | `wonrich.<owning service>.<event in plural>.v<schema version>` |
| Dead-letter topic | `wonrich.dlq.<consumer group>.v<version>`, **one per consumer group** |
| Message key | The business identifier the events relate to (e.g. `batchId`), so events for one entity stay in order |
| Partitions | 3 on event topics, 1 on dead-letter topics |
| Retention | 7 days on event topics, 30 days on dead-letter topics (local) |
| Replication factor | 1 locally (single broker) |
| Consumer group | Named after the consuming service and what it consumes; one group per service, never shared |
| Topic creation | Explicit only (`topics.env`). Automatic topic creation is disabled on the broker |

**Why a version in the name:** a breaking change to an event's schema gets a new topic (`.v2`) so existing consumers keep working until they migrate. Non-breaking changes (adding an optional field) stay on the same version.

**Why one dead-letter topic per consumer group:** when a message cannot be processed, what matters for replaying it is which consumer failed, because that is the code being fixed.

**Why 3 partitions:** the partition count is the upper limit on parallel consumers in one group. It can be increased later but never reduced.

---

## Topics

Defined in [`kafka/topics.env`](../kafka/topics.env), the single source of truth.

### Event topics

| Topic | Owner (producer) | Events | Key | Partitions | Retention |
|---|---|---|---|---|---|
| `wonrich.intake.lab-results.v1` | MCC & Intake Service | Intake lab results | `batchId` | 3 | 7 days |
| `wonrich.processing.stage-events.v1` | Processing Service | Processing stage events (incl. run ready for final testing) | `batchId` | 3 | 7 days |
| `wonrich.processing.hold-events.v1` | Processing Service | Batch hold events | `batchId` | 3 | 7 days |
| `wonrich.quality-lab.batch-determinations.v1` | Quality Lab Service | `BatchCleared`, `BatchFailed` | `batchId` | 3 | 7 days |

`wonrich.quality-lab.batch-determinations.v1` carries both outcomes on one topic. Each message includes an event-type field so consumers can distinguish `BatchCleared` from `BatchFailed`.

### Dead-letter topics

| Topic | For consumer group | Partitions | Retention (local) |
|---|---|---|---|
| `wonrich.dlq.processing-lab-results.v1` | `processing-lab-results` | 1 | 30 days |
| `wonrich.dlq.processing-stage-events.v1` | `processing-stage-events` | 1 | 30 days |
| `wonrich.dlq.processing-hold-events.v1` | `processing-hold-events` | 1 | 30 days |
| `wonrich.dlq.quality-lab-stage-events.v1` | `quality-lab-stage-events` | 1 | 30 days |

---

## Consumer groups

| Consumer group | Service | Consumes | Dead-letter topic |
|---|---|---|---|
| `processing-lab-results` | Processing Service | `wonrich.intake.lab-results.v1` | `wonrich.dlq.processing-lab-results.v1` |
| `processing-stage-events` | Processing Service | `wonrich.processing.stage-events.v1` | `wonrich.dlq.processing-stage-events.v1` |
| `processing-hold-events` | Processing Service | `wonrich.processing.hold-events.v1` | `wonrich.dlq.processing-hold-events.v1` |
| `quality-lab-stage-events` | Quality Lab Service | `wonrich.processing.stage-events.v1` | `wonrich.dlq.quality-lab-stage-events.v1` |

On the local broker, a consumer group is created automatically the first time a consumer connects with that group ID. On Azure Event Hubs, consumer groups must be declared explicitly (see [Hosted broker](#hosted-broker)).

Traceability & QC Dashboard Service consumer groups will be added here when that service's consumers are defined.

---

## Adding a topic or consumer group

1. Follow the conventions above.
2. **Topic:** add a line to `kafka/topics.env` in the form `name:partitions:retention-ms`.
   - 7 days = `604800000`
   - 30 days = `2592000000`
3. **Consumer group:** add a row to the consumer group table above, and a dead-letter topic for it in `topics.env`.
4. Update the tables in this document.
5. Run `docker compose up -d` to create the new topic locally.
6. Open a pull request and tag the DevOps members of the affected services.

---

## Local verification

```bash
# List topics
docker exec wonrich-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Check partitions and retention of a topic
docker exec wonrich-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic wonrich.quality-lab.batch-determinations.v1

# List consumer groups
docker exec wonrich-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list
```

Or use Kafka UI at http://localhost:8085.

### Produce and consume a test message

```bash
# Terminal 1: consume with a consumer group
docker exec -it wonrich-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic wonrich.processing.stage-events.v1 \
  --group quality-lab-stage-events --from-beginning

# Terminal 2: produce a message
echo '{"batchId":"WR-2609-0001","stage":"ReadyForFinalTesting"}' | docker exec -i wonrich-kafka \
  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic wonrich.processing.stage-events.v1
```

---

## Hosted broker

The deployed services on Azure App Service need a broker reachable from Azure. **The hosting option has not been decided yet.**

| Option | Notes |
|---|---|
| Azure Event Hubs (Standard tier) | Managed; speaks the Kafka protocol. Basic tier does not support Kafka. Retention capped at 7 days, so dead-letter topics keep 7 days instead of 30. Consumer groups must be declared per event hub. |
| Apache Kafka on an Azure VM | Same `apache/kafka` image as local development. Self-managed (networking, authentication, uptime). |

Whichever is chosen, the topic names, partitions and consumer groups in this document stay the same; only the bootstrap address and security settings differ.

If Event Hubs is chosen, `azure/eventhubs.sh` provisions the topics from `kafka/topics.env`. Each service's App Service then needs these settings:

| Setting | Value |
|---|---|
| `Kafka__BootstrapServers` | `<namespace>.servicebus.windows.net:9093` |
| `Kafka__SecurityProtocol` | `SaslSsl` |
| `Kafka__SaslMechanism` | `Plain` |
| `Kafka__SaslUsername` | `$ConnectionString` |
| `Kafka__SaslPassword` | Connection string of a Send + Listen authorization rule (not Manage) |
