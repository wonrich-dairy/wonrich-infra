#!/usr/bin/env bash
# Provision the Azure VM that hosts the shared Wonrich Kafka broker.
#
#   az login
#   ./azure/kafka-vm/provision.sh
#
# Creates: resource group, Ubuntu VM (B2ls_v2), static public IP with a DNS name, and the
# network security group rules. Idempotent: existing resources are left as they are.
#
# It does NOT install or start Kafka; run azure/kafka-vm/deploy.sh afterwards.
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-wonrich-kafka}"
LOCATION="${LOCATION:-southeastasia}"
VM_NAME="${VM_NAME:-vm-wonrich-kafka}"
VM_SIZE="${VM_SIZE:-Standard_B2ls_v2}"       # 2 vCPU / 4 GiB. B1ms had no capacity in the region
DNS_LABEL="${DNS_LABEL:-wonrich-kafka}"      # -> <label>.<region>.cloudapp.azure.com
ADMIN_USER="${ADMIN_USER:-azureuser}"

echo "== resource group $RESOURCE_GROUP ($LOCATION)"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

if ! az vm show --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
  echo "== creating VM $VM_NAME ($VM_SIZE)"
  az vm create \
    --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
    --image Ubuntu2204 --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --public-ip-sku Standard --public-ip-address-dns-name "$DNS_LABEL" \
    --output none
else
  echo "== VM $VM_NAME already exists"
fi

FQDN=$(az vm show -d --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" --query fqdns -o tsv)
IP=$(az vm show -d --name "$VM_NAME" --resource-group "$RESOURCE_GROUP" --query publicIps -o tsv)

# Kafka's external listeners: 9094 for the staging broker, 9095 for the production broker
# (SCRUM-126). Opened only to the addresses in KAFKA_ALLOWED_IPS: the App Services' outbound IPs
# plus the team's own addresses. Never "*".
if [ -n "${KAFKA_ALLOWED_IPS:-}" ]; then
  for rule in "9094 1010" "9095 1020"; do
    read -r port priority <<<"$rule"
    echo "== allowing $port from: $KAFKA_ALLOWED_IPS"
    # shellcheck disable=SC2086
    az network nsg rule create \
      --resource-group "$RESOURCE_GROUP" --nsg-name "${VM_NAME}NSG" \
      --name "allow-kafka-$port" --priority "$priority" \
      --access Allow --protocol Tcp --direction Inbound \
      --destination-port-ranges "$port" \
      --source-address-prefixes $KAFKA_ALLOWED_IPS \
      --output none
  done
else
  echo "!! KAFKA_ALLOWED_IPS not set - ports 9094 and 9095 were NOT opened."
  echo "   Re-run with, for example:"
  echo "   KAFKA_ALLOWED_IPS='20.1.2.3 20.1.2.4 <your-home-ip>' $0"
fi

cat <<DONE

== VM ready
   host : $FQDN
   ip   : $IP
   ssh  : ssh $ADMIN_USER@$FQDN

   Next: ./azure/kafka-vm/deploy.sh $FQDN
   Then set on every service's App Service:
     Kafka__BootstrapServers = $FQDN:9094
     Kafka__SecurityProtocol = SaslPlaintext
     Kafka__SaslMechanism    = Plain
     Kafka__SaslUsername     = <username from the VM's .env>
     Kafka__SaslPassword     = <password from the VM's .env>
DONE
