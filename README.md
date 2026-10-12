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
├── docker-compose.stack.yml  # The whole platform, one command
├── .env.stack.example        # Settings for the stack (copy to .env)
├── kafka/
│   ├── topics.env            # Single definition of every topic
│   ├── consumer-groups.env   # Consumer group per topic (reference)
│   └── create-topics.sh      # Creates the topics on a broker (idempotent)
├── azure/kafka-vm/
│   ├── provision.sh          # Creates the staging VM, public IP and NSG rules
│   ├── deploy.sh             # Installs Docker, starts a broker, creates topics (ENV=prod for production)
│   ├── docker-compose.yml    # Staging broker with the SASL listener on 9094
│   └── docker-compose.prod.yml  # Production broker with the SASL listener on 9095
└── docs/
    └── kafka.md              # Topics, consumer groups, conventions
```

---

## The whole platform with one command

`docker-compose.stack.yml` starts everything: Kafka and Kafka UI, MCC and Intake, Auth, Processing, Quality Lab, Traceability, the frontend, and the observability stack (Prometheus, Loki, Promtail, Grafana).

### 1. Clone the repositories side by side

```
<workspace>/
  wonrich-infra/                    this repository
  mcc-intake-service/
  WD-Auth-service/
  processing-service/
  quality-lab-service/
  traceability-dashboard-service/
  frontend/
```

The folder names must match: the stack builds each service from `../<folder>`.

### 2. Configure

```bash
cd wonrich-infra
cp .env.stack.example .env       # fill in the database connection strings and the signing key
```

Every service connects to its database on the remote MySQL server, so there is no database container. The passwords and the signing key come from the DevOps member, privately. `.env` is git-ignored.

### 3. Start

```bash
docker compose -f docker-compose.stack.yml up -d --build
docker compose -f docker-compose.stack.yml ps
```

The first build compiles every service and the frontend, and takes several minutes.

| What | Address |
|---|---|
| Frontend | http://localhost:5173 |
| MCC and Intake | http://localhost:5237 |
| Auth | http://localhost:5238 |
| Processing | http://localhost:5210 |
| Quality Lab | http://localhost:5003 |
| Traceability | http://localhost:5240 |
| Kafka UI | http://localhost:8085 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |

Stop with `docker compose -f docker-compose.stack.yml down` (add `-v` to delete Kafka and monitoring data).

The services that use Kafka wait for the broker to be healthy before they start. To run only the broker, use `docker compose up -d` as described below.

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

## Staging and production brokers

Deployed services use two independent brokers on one Azure VM: staging on port 9094 and production on port 9095, provisioned by the scripts in `azure/kafka-vm/`. Connection settings, provisioning steps and known limitations are in [docs/kafka.md](docs/kafka.md#hosted-brokers-staging-and-production).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Bind for 0.0.0.0:29092 failed: port is already allocated` | Another Kafka container (often an old one from a service repo) is running | `docker ps \| grep 29092`, then `docker rm -f <container>` |
| `dependency kafka failed to start: container wonrich-kafka is unhealthy` | Broker crashed at start-up | `docker logs wonrich-kafka 2>&1 \| grep -iE "error\|exception" \| head` |
| `network wonrich-net not found` when starting a service | Shared infra not running | Run `docker compose up -d` here first |
| Topic missing | Not in `topics.env`, or `kafka-init` failed | Check `docker compose logs kafka-init` |
