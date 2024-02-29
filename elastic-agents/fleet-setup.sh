#!/bin/bash

set -eu

HEADERS=(
  -H "kbn-xsrf: kibana"
  -H "Content-Type: application/json"
)

KIBANA_URL=https://localhost:5601
ELASTIC_USERNAME=elastic
ELASTIC_PASSWORD=elastic
ELASTIC_HOSTNAME=localhost
ELASTIC_PORT=9200
FLEET_SERVER_HOSTNAME=localhost
FLEET_SERVER_PORT=8220
ELASTICSEARCH_POLICY_ID=elasticsearch-policy
SYSTEM_PACKAGE_POLICY_VERSION="1.54.0"
AGENT_POLICY_JSON=$(printf '{"id":"%s","name":"Elastic-policy","namespace":"default","monitoring_enabled":["logs","metrics"]}' "${ELASTICSEARCH_POLICY_ID}")
PACKAGE_POLICY_JSON=$(printf '{"name":"elasticsearch_system_package","namespace":"default","policy_id":"%s", "package":{"name": "system", "version":"%s"}}' "${ELASTICSEARCH_POLICY_ID}" "${SYSTEM_PACKAGE_POLICY_VERSION}")

echo "Checking if policy already exists..."
elasticsearch_policy=$(curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XGET -H "kbn-xsrf: kibana" \
    "${KIBANA_URL}/api/fleet/agent_policies/${ELASTICSEARCH_POLICY_ID}" | jq '.statusCode')

if [[ "$elasticsearch_policy" == "404" ]]; then
  echo "Creating Basic agent policy..."
  printf '%s' "$AGENT_POLICY_JSON" | curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPOST "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/agent_policies" \
    -d @- | jq

  echo "Adding System package to policy..."
  printf '%s' "$PACKAGE_POLICY_JSON" | curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPOST "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/package_policies" \
    -d @- | jq
fi

curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPUT "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/settings" \
    -d "$(printf '{"fleet_server_hosts": ["%s"]}' "https://${FLEET_SERVER_HOSTNAME}:${FLEET_SERVER_PORT}")" | jq


curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPUT "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/outputs/fleet-default-output" \
    -d "$(printf '{"hosts": ["%s"], "config_yaml": "ssl.verification_mode: certificate\\nssl.certificate_authorities: [\\"%s\\"]"}' "https://${ELASTIC_HOSTNAME}:${ELASTIC_PORT}" "$(pwd)/ca/ca.crt")" | jq

ENROLLMENT_TOKEN=$(curl -k -s \
  -u ${ELASTIC_USERNAME}:${ELASTIC_PASSWORD} \
  ${KIBANA_URL}/api/fleet/enrollment_api_keys | \
  jq -r '.items[] | select(any(.; .policy_id == "elasticsearch-policy")) | .api_key')


sudo ./elastic-agent-8.12.2-linux-x86_64/elastic-agent install \
    --base-path=${HOME} \
    --url=https://${FLEET_SERVER_HOSTNAME}:${FLEET_SERVER_PORT} \
    --enrollment-token=${ENROLLMENT_TOKEN} \
    --certificate-authorities=$(pwd)/ca/ca.crt \
    --force