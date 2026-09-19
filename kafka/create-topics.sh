#!/usr/bin/env bash
# Create the Wonrich topics on a Kafka broker (SCRUM-88).
#
# Runs as the kafka-init container on every `docker compose up`, and can be run by hand against
# any broker:
#
#   KAFKA_BOOTSTRAP=localhost:29092 ./infra/kafka/create-topics.sh
#
# Idempotent by way of --if-not-exists: a topic that already exists is left untouched, including
# its data. It is safe to run against a broker that is already configured.
set -euo pipefail

KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-localhost:29092}"
KAFKA_TOPICS="${KAFKA_TOPICS:-/opt/kafka/bin/kafka-topics.sh}"

# The definitions live next to this script, so running it from anywhere still finds them.
definitions="$(dirname "$0")/topics.env"
[ -f "$definitions" ] || { echo "cannot find $definitions" >&2; exit 1; }

# One broker locally, so nothing can be replicated anywhere. Event Hubs replicates for us and
# ignores this, which is why staging is provisioned by a different script.
REPLICATION="${KAFKA_REPLICATION_FACTOR:-1}"

echo "== creating topics on $KAFKA_BOOTSTRAP"

while IFS=: read -r name partitions retention; do
  # Skip blank lines and comments.
  case "${name# }" in ''|'#'*) continue ;; esac

  "$KAFKA_TOPICS" --bootstrap-server "$KAFKA_BOOTSTRAP" \
    --create --if-not-exists \
    --topic "$name" \
    --partitions "$partitions" \
    --replication-factor "$REPLICATION" \
    --config "retention.ms=$retention"

  echo "   $name  partitions=$partitions retention=${retention}ms"
done < "$definitions"

echo
echo "== topics now on the broker"
"$KAFKA_TOPICS" --bootstrap-server "$KAFKA_BOOTSTRAP" --list
