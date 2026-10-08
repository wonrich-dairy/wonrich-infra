#!/usr/bin/env bash
# Install Docker on the Kafka VM, copy a broker's compose file and the topic definitions,
# and start the broker.
#
#   ./azure/kafka-vm/deploy.sh <vm-fqdn> [ssh-user]              # staging broker, port 9094
#   ENV=prod ./azure/kafka-vm/deploy.sh <vm-fqdn> [ssh-user]     # production broker, port 9095
#
# The two brokers are independent compose projects on the same VM, each with its own containers,
# data volume, cluster ID and credentials (staging: ~/kafka/.env, production: ~/kafka/.env.prod).
# On the first run for an environment it generates the SASL password (and, for production, the
# cluster ID); on later runs the existing values are kept, so this is safe to re-run after
# changing topics.env.
set -euo pipefail
cd "$(dirname "$0")/../.."      # repository root

FQDN="${1:?usage: [ENV=prod] $0 <vm-fqdn> [ssh-user]}"
SSH_USER="${2:-azureuser}"
REMOTE="$SSH_USER@$FQDN"

case "${ENV:-staging}" in
  staging)
    COMPOSE_SRC=azure/kafka-vm/docker-compose.yml
    COMPOSE_FILE=docker-compose.yml
    ENV_FILE=.env
    PORT=9094
    ;;
  prod|production)
    COMPOSE_SRC=azure/kafka-vm/docker-compose.prod.yml
    COMPOSE_FILE=docker-compose.prod.yml
    ENV_FILE=.env.prod
    PORT=9095
    ;;
  *) echo "ENV must be 'staging' or 'prod', got '$ENV'" >&2; exit 2 ;;
esac
COMPOSE="docker compose -f $COMPOSE_FILE --env-file $ENV_FILE"

echo "== ${ENV:-staging} broker on $FQDN:$PORT"

echo "== installing Docker on $FQDN (skipped if already present)"
ssh "$REMOTE" 'command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER)'

if [ "$PORT" = 9095 ]; then
  # The staging broker, Prometheus and Grafana already use about 1.6 GB; a second broker with a
  # 512 MB heap needs about 0.8 GB more.
  echo "== memory on the VM"
  ssh "$REMOTE" 'free -m'
  available=$(ssh "$REMOTE" "free -m | awk '/^Mem:/ {print \$7}'")
  if [ "$available" -lt 900 ]; then
    echo "!! only ${available} MB available; the production broker needs about 800 MB. Stopping." >&2
    exit 1
  fi
fi

echo "== copying broker files"
ssh "$REMOTE" 'mkdir -p ~/kafka/kafka'
scp "$COMPOSE_SRC" "$REMOTE:~/kafka/$COMPOSE_FILE"
scp kafka/topics.env kafka/create-topics.sh "$REMOTE:~/kafka/kafka/"

echo "== writing $ENV_FILE (kept if it already exists)"
ssh "$REMOTE" "FQDN='$FQDN' ENV_FILE='$ENV_FILE' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
cd ~/kafka
if [ ! -f "$ENV_FILE" ]; then
  # '|| true': head closes the pipe after 32 characters, which makes tr exit 141, and pipefail
  # would end the script silently right here.
  PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
  {
    echo "KAFKA_PUBLIC_HOST=$FQDN"
    echo "KAFKA_USERNAME=wonrich"
    echo "KAFKA_PASSWORD=$PASSWORD"
    if [ "$ENV_FILE" = .env.prod ]; then
      # Production must not share the staging broker's cluster ID. < /dev/null: without it docker
      # reads the rest of this script from stdin and the file is never finished.
      echo "KAFKA_CLUSTER_ID=$(sg docker -c 'docker run --rm apache/kafka:3.9.1 /opt/kafka/bin/kafka-storage.sh random-uuid' < /dev/null)"
    fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "-- generated new credentials in $ENV_FILE"
else
  echo "-- existing $ENV_FILE kept"
fi
REMOTE_SCRIPT

echo "== starting the broker"
ssh "$REMOTE" "cd ~/kafka && sg docker -c '$COMPOSE up -d' && sleep 40 && sg docker -c '$COMPOSE ps' && sg docker -c '$COMPOSE logs kafka-init'"

echo
echo "== credentials (share privately; they are not stored in this repository)"
ssh "$REMOTE" "cd ~/kafka && grep -E 'KAFKA_USERNAME|KAFKA_PASSWORD' $ENV_FILE"

cat <<DONE

== done. App Service settings for every ${ENV:-staging} service:

   Kafka__BootstrapServers = $FQDN:$PORT
   Kafka__SecurityProtocol = SaslPlaintext
   Kafka__SaslMechanism    = Plain
   Kafka__SaslUsername     = wonrich
   Kafka__SaslPassword     = <the password above>
DONE
