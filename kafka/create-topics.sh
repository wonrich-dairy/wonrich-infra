#!/usr/bin/env bash
# Create the Wonrich topics on a Kafka broker (SCRUM-88).
#
# Runs as the kafka-init container on every `docker compose up`, and can be run by hand against
# any broker:
#
#   KAFKA_BOOTSTRAP=localhost:29092 ./kafka/create-topics.sh
#
# Against the staging broker on the Azure VM, which needs SASL:
#
#   KAFKA_BOOTSTRAP=<vm-dns>:9094 \
#   KAFKA_COMMAND_CONFIG=/tmp/staging.properties \
#   DLQ_RETENTION_MS=604800000 \
#   ./kafka/create-topics.sh
#
# Idempotent: --if-not-exists leaves an existing topic and its data untouched, and retention is
# re-applied afterwards so a changed value in topics.env reaches topics that already exist.
set -euo pipefail

KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-localhost:29092}"
KAFKA_TOPICS="${KAFKA_TOPICS:-/opt/kafka/bin/kafka-topics.sh}"
KAFKA_CONFIGS="${KAFKA_CONFIGS:-/opt/kafka/bin/kafka-configs.sh}"

# Client properties for a broker that needs authentication (the staging VM). Empty locally.
KAFKA_COMMAND_CONFIG="${KAFKA_COMMAND_CONFIG:-}"
auth=()
[ -n "$KAFKA_COMMAND_CONFIG" ] && auth=(--command-config "$KAFKA_COMMAND_CONFIG")

# Dead letters keep longer than their source topic, so a failure is still there after a weekend.
# Staging overrides this to 7 days because the VM's disk is small; deploy.sh exports it.
DLQ_RETENTION_MS="${DLQ_RETENTION_MS:-2592000000}"

# The definitions live next to this script, so running it from anywhere still finds them.
definitions="$(dirname "$0")/topics.env"
[ -f "$definitions" ] || { echo "cannot find $definitions" >&2; exit 1; }

# One broker, so nothing can be replicated anywhere. The staging VM runs a single broker too.
REPLICATION="${KAFKA_REPLICATION_FACTOR:-1}"

echo "== creating topics on $KAFKA_BOOTSTRAP"

while IFS=: read -r name partitions retention || [ -n "$name" ]; do
  # Skip blank lines and comments.
  case "${name# }" in ''|'#'*) continue ;; esac

  # Dead-letter retention is environment-specific; everything else comes from topics.env.
  case "$name" in wonrich.dlq.*) retention="$DLQ_RETENTION_MS" ;; esac

  "$KAFKA_TOPICS" --bootstrap-server "$KAFKA_BOOTSTRAP" "${auth[@]}" \
    --create --if-not-exists \
    --topic "$name" \
    --partitions "$partitions" \
    --replication-factor "$REPLICATION" \
    --config "retention.ms=$retention"

  # --create --if-not-exists ignores --config on an existing topic, so apply it explicitly.
  # Retention can be changed in place; partitions cannot, so those are left alone.
  "$KAFKA_CONFIGS" --bootstrap-server "$KAFKA_BOOTSTRAP" "${auth[@]}" \
    --alter --entity-type topics --entity-name "$name" \
    --add-config "retention.ms=$retention" >/dev/null

  echo "   $name  partitions=$partitions retention=${retention}ms"
done < "$definitions"

echo
echo "== topics now on the broker"
"$KAFKA_TOPICS" --bootstrap-server "$KAFKA_BOOTSTRAP" "${auth[@]}" --list