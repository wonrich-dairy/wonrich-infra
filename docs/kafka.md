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
| Retention | 7 days on event topics; dead-letter topics 30 days locally, 7 days on staging |
| Replication factor | 1 (single broker, locally and on staging) |
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

| Topic | For consumer group | Partitions | Retention |
|---|---|---|---|
| `wonrich.dlq.processing-lab-results.v1` | `processing-lab-results` | 1 | 30 days (7 on staging) |
| `wonrich.dlq.processing-stage-events.v1` | `processing-stage-events` | 1 | 30 days (7 on staging) |
| `wonrich.dlq.processing-hold-events.v1` | `processing-hold-events` | 1 | 30 days (7 on staging) |
| `wonrich.dlq.quality-lab-stage-events.v1` | `quality-lab-stage-events` | 1 | 30 days (7 on staging) |

Dead-letter topics have **one partition**: they are low volume and nothing consumes them in order, so partitioning buys nothing.

Retention is longer than the source topic locally, so a failed message is still there after a weekend. Staging keeps dead letters for 7 days, as SCRUM-110 AC3 specifies. `topics.env` holds the local values; `create-topics.sh` replaces the dead-letter value with `DLQ_RETENTION_MS` when it is set, and the staging `kafka-init` (`azure/kafka-vm/docker-compose.yml`) sets it to `604800000`.

---

## Consumer groups

| Consumer group | Service | Consumes | Dead-letter topic |
|---|---|---|---|
| `processing-lab-results` | Processing Service | `wonrich.intake.lab-results.v1` | `wonrich.dlq.processing-lab-results.v1` |
| `processing-stage-events` | Processing Service | `wonrich.processing.stage-events.v1` | `wonrich.dlq.processing-stage-events.v1` |
| `processing-hold-events` | Processing Service | `wonrich.processing.hold-events.v1` | `wonrich.dlq.processing-hold-events.v1` |
| `quality-lab-stage-events` | Quality Lab Service | `wonrich.processing.stage-events.v1` | `wonrich.dlq.quality-lab-stage-events.v1` |

A consumer group is created by the broker the first time a consumer connects with that group ID, locally and on staging. It does not appear in `kafka-consumer-groups.sh --list` until then.

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

## Hosted broker (staging)

The deployed services on Azure App Service use a single Kafka broker running on an Azure VM: the same `apache/kafka` image as local development, with an extra listener for clients outside the VM.

Azure Event Hubs was considered and ruled out: its Kafka endpoint needs a Standard-tier namespace, which the team's Azure for Students subscription does not include.

| Item | Value |
|---|---|
| Host | `wonrich-kafka.southeastasia.cloudapp.azure.com` |
| VM | `Standard_B2ls_v2`, Southeast Asia |
| Client listener | `9094`, SASL_PLAINTEXT with SASL/PLAIN |
| Internal listener | `9092`, PLAINTEXT, reachable only inside the VM's Docker network (used by `kafka-init`) |
| Topics | Created from `kafka/topics.env` by `kafka-init`, dead-letter retention 7 days |

### Provisioning

Scripted and repeatable; both scripts are safe to re-run.

```bash
az login
./azure/kafka-vm/provision.sh                 # VM, public IP with DNS name, NSG rules
./azure/kafka-vm/deploy.sh <vm-fqdn>          # Docker, broker, topics, SASL credentials
```

`deploy.sh` copies `topics.env` and `create-topics.sh` to the VM and starts the broker; `kafka-init` then creates any missing topics and applies retention. Re-run it after changing `topics.env`. On the first run it generates the SASL password and prints it once; it is never stored in this repository.

To run the topic script from your own machine instead, with a client config file holding the SASL settings:

```bash
docker run --rm \
  -v "$PWD/kafka:/scripts:ro" \
  -v /tmp/staging.properties:/tmp/staging.properties:ro \
  -e KAFKA_BOOTSTRAP=wonrich-kafka.southeastasia.cloudapp.azure.com:9094 \
  -e KAFKA_COMMAND_CONFIG=/tmp/staging.properties \
  -e DLQ_RETENTION_MS=604800000 \
  apache/kafka:3.9.1 bash /scripts/create-topics.sh
```

### Service settings

Each service's App Service needs:

| Setting | Value |
|---|---|
| `Kafka__BootstrapServers` | `wonrich-kafka.southeastasia.cloudapp.azure.com:9094` |
| `Kafka__SecurityProtocol` | `SaslPlaintext` |
| `Kafka__SaslMechanism` | `Plain` |
| `Kafka__SaslUsername` | `wonrich` |
| `Kafka__SaslPassword` | Shared privately by DevOps. Never in git, Jira or the group chat |

### Access control

- The client listener accepts authenticated SASL connections only; there is no anonymous access from outside the VM.
- The credential lives in App Service settings and .NET user secrets, never in a repository.
- No authorizer is configured, so an authenticated client has full rights on the broker, including creating topics and changing their configuration. This is how `create-topics.sh` can run against staging from a laptop. See known limitations.

### Known limitations

Accepted for the case-study environment, which carries no real data. The VM is deleted after the final evaluation.

- **No encryption in transit.** SASL_PLAINTEXT authenticates clients but does not encrypt traffic. Follow-up: SASL_SSL.
- **One shared credential with full rights, no ACLs.** Every service uses the same SASL user, and without an authorizer that user can produce, consume and administer every topic. Follow-up: enable the KRaft `StandardAuthorizer`, one user per service, and ACLs granting each only the topics it produces to and consumes from, the self-hosted equivalent of separate Send and Listen rules.
- **Port 9094 open to all source addresses**, because App Service outbound IPs are shared and change.
- **Single broker**, no replication. A VM restart makes the broker unavailable for about a minute; producers retry.
