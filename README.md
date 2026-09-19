# wonrich-infra

Shared infrastructure for the **Wonrich Dairy Milk Quality Monitoring and Traceability System** (SE3022, Group 16).

This repository holds the infrastructure that every microservice depends on, so that it is defined once instead of being copied into each service repository. It currently provides the **Kafka event bus**.

| Service repository | Uses from here |
|---|---|
| mcc-intake-service | Kafka broker, topics |
| processing-service | Kafka broker, topics |
| quality-lab-service | Kafka broker, topics |
| traceability-service | Kafka broker, topics |

---

## Contents

```
wonrich-infra/
├── docker-compose.yml        # Local Kafka broker, topic creation, Kafka UI
├── kafka/
│   ├── topics.env            # Single definition of every topic
│   └── create-topics.sh      # Creates the topics on a broker (idempotent)
└── docs/
    └── kafka.md              # Topics, consumer groups, conventions
```

---

## Prerequisites

- Docker Desktop
- Port **29092** (Kafka) and **8085** (Kafka UI) free on your machine

---

## Getting started

Start the shared infrastructure **before** starting any service:

```bash
docker compose up -d
```

This starts:

| Container | Purpose | Address |
|---|---|---|
| `wonrich-kafka` | Single-node Kafka broker (KRaft, no ZooKeeper) | `kafka:9092` from containers · `localhost:29092` from your machine |
| `wonrich-kafka-init` | Creates every topic in `kafka/topics.env`, then exits | – |
| `wonrich-kafka-ui` | Web UI for topics, messages and consumer groups | http://localhost:8085 |

Verify:

```bash
docker compose ps                  # wonrich-kafka is "healthy"
docker compose logs kafka-init     # lists the topics that were created
```

Then start any service from its own repository (`docker compose up -d`).

### Stopping

```bash
docker compose down        # stop, keep topics and messages
docker compose down -v     # stop and delete all Kafka data (clean start)
```

---

## Connecting a service

Each service joins the shared `wonrich-net` Docker network and reaches the broker at `kafka:9092`.

In the service's `docker-compose.yml`:

```yaml
services:
  my-service:
    # ...
    environment:
      Kafka__BootstrapServers: "kafka:9092"
    networks:
      - default        # keep if the service has other containers (e.g. observability)
      - wonrich-net

networks:
  wonrich-net:
    external: true
```

Do **not** run a separate Kafka container in a service repository. Two brokers compete for port 29092, and services on different brokers cannot exchange events.

When running a service outside Docker (`dotnet run`), use `localhost:29092`.

---

## Adding a topic

1. Add one line to `kafka/topics.env` (`name:partitions:retention-ms`), following the conventions in [docs/kafka.md](docs/kafka.md).
2. Update the tables in `docs/kafka.md`.
3. Run `docker compose up -d`. `kafka-init` creates the new topic and leaves existing ones untouched.
4. Open a pull request. Topic changes affect every service, so they need review.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Bind for 0.0.0.0:29092 failed: port is already allocated` | Another Kafka container (often an old one from a service repo) is running | `docker ps \| grep 29092`, then `docker rm -f <container>` |
| `dependency kafka failed to start: container wonrich-kafka is unhealthy` | Broker crashed at start-up | `docker logs wonrich-kafka 2>&1 \| grep -iE "error\|exception" \| head` |
| `network wonrich-net not found` when starting a service | Shared infra not running | Run `docker compose up -d` here first |
| Topic missing | Not in `topics.env`, or `kafka-init` failed | Check `docker compose logs kafka-init` |
