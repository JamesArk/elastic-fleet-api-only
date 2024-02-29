# Fleet Managed Elastic Agents: A pratical guide

A pratical guide to setup fleet server and fleet managed elastic agents without using Kibana UI.

## Why make this guide?

Although Elasticsearch provides good documentation on how to set up your own [fleet server](https://www.elastic.co/guide/en/fleet/8.12/add-fleet-server-on-prem.html) and [fleet managed elastic agents](https://www.elastic.co/guide/en/fleet/8.12/install-fleet-managed-elastic-agent.html), there are a few flaws:

- **Relies on the Kibana UI**: When we want to experiment with clean state elasticsearch deployment or we just want to automate things to remove human error, using the UI should be avoided as much as you can.
- **Running the fleet server on the host**: Elastic-agents should be installed at the host level in order to get the most accurate metrics of the host and applications running on the host. However, when it comes to the fleet server, we might not want to monitor the host the fleet-server is running on. Maybe we want to run a containerized fleet-server that manages host installed elastic agents. The kibana UI assumes you will install the fleet server at the host level, which may or may not be possible or wanted. We may just want a container running the fleet server on any host we feel like without interfering with the already installed elastic agent if there is any.
- **Unclear setup for containerized fleet server**: By following this [guide](https://www.elastic.co/guide/en/fleet/8.12/elastic-agent-container.html), we do get a nice step by step guide on how to run elastic-agents in containers, specially fleet-servers. The catch is ... it requires using Kibana's Fleet UI. Which we would like to avoid as much as possible.

I'd like to note that Elasticsearch does have documentation on the [fleet REST API](https://www.elastic.co/guide/en/fleet/8.12/fleet-api-docs.html) that does give us enough tools to set up our own fleet server and fleet managed elastic agents. The problem lies in the lack of a streamlined step by step guide on setting up a fleet server and fleet managed elastic agents using **ONLY** the provided fleet REST APIs and not relying on the Kibana UI in any of the steps.

## Self Signed CA and certificates

Elasticsearch has a nice tool for creating self signed CA's and other certificates that work well on Elastic products. To configure SSL/TLS using this tool, you can check out their guide [here](https://www.elastic.co/guide/en/fleet/8.12/secure-connections.html), but in this guide I will be creating our own CA using [openssl](https://www.openssl.org/) and using the Elasticsearch tools for the other certificates and keys.

The following command will create our own CA certificate and key with an expiration of 10 years:

```bash
mkdir ca && \
openssl req -x509 \
-newkey rsa:4096 \
-keyout ca/ca.key \
-out ca/ca.crt \
-sha256 -days 3650 \
-noenc -subj "/C=PT/ST=Lisbon/L=Lisbon/O=Marionete/OU=IT/CN=marionete"
```

Once the CA is created, we can now create certificates and keys for all other services:

- Include the CA certificate we just created:
```bash
mkdir certs && cp ca/ca.crt certs
```
- Generate the key with password
```bash
openssl genrsa -out certs/<service>.key 2048
```
- Create the CSR for the key
```bash
openssl req -new -key certs/<service>.key -out certs/<service>.csr -subj "/C=PT/ST=Lisbon/L=Lisbon/O=Marionete/OU=IT/CN=<service>"
```
- Sign the key with our self signed CA
```bash
openssl x509 -req \
  -in certs/<service>.csr \
  -CAkey ca/ca.key \
  -CA ca/ca.crt \
  -CAcreateserial \
  -out certs/<service>.crt \
  -days 3650 \
  -sha256 \
  -extfile <(printf "subjectAltName=DNS:<service>,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment,keyAgreement\nsubjectKeyIdentifier=hash")
```

Where ```<service>``` are can either be ```elastic```, ```kibana``` or ```fleet-server```.
## Setting up Elastic, Kibana and Fleet Server without the UI
In order to have fleet servers and fleet managed elastic agents, we need our own elasticsearch and kibana.

We can deploy kibana, a single elasticsearch node and a single fleet server using the following ```docker-compose.yml```:
```yaml
version: "2.2"

services:
  setup:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.2
    container_name: ecp-elasticsearch-security-setup
    volumes:
      - ./certs:/usr/share/elasticsearch/config/certs:z
    user: "1000"
    command: >
      bash -c '
        echo "Waiting for Elasticsearch availability";
        until curl -s --cacert config/certs/ca.crt https://elastic:9200 | grep -q "missing authentication credentials"; do sleep 30; done;
        echo "Setting kibana_system password";
        until curl -s -X POST --cacert config/certs/ca.crt -u elastic:elastic -H "Content-Type: application/json" https://elastic:9200/_security/user/kibana_system/_password -d "{\"password\":\"kibana\"}" | grep -q "^{}"; do sleep 10; done;
        echo "All done!";
      '
    healthcheck:
      test: ["CMD-SHELL", "[ -f config/certs/elastic.crt ]"]
      interval: 1s
      timeout: 5s
      retries: 120

  elasticsearch:
    depends_on:
      setup:
        condition: service_healthy
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.2
    container_name: elastic
    user: "1000"
    volumes:
      - ./certs:/usr/share/elasticsearch/config/certs:z
      - ./elastic-data:/usr/share/elasticsearch/data
    ports:
      - 9200:9200
    environment:
      - node.name=elastic
      - cluster.name=fleet-elasticsearch
      - ELASTIC_PASSWORD=elastic
      - bootstrap.memory_lock=false
      - discovery.type=single-node
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=true
      - xpack.security.http.ssl.key=certs/elastic.key
      - xpack.security.http.ssl.certificate=certs/elastic.crt
      - xpack.security.http.ssl.certificate_authorities=certs/ca.crt
      - xpack.security.http.ssl.verification_mode=certificate
      - xpack.security.http.ssl.client_authentication=optional
      - xpack.security.transport.ssl.enabled=true
      - xpack.security.transport.ssl.key=certs/elastic.key
      - xpack.security.transport.ssl.certificate=certs/elastic.crt
      - xpack.security.transport.ssl.certificate_authorities=certs/ca.crt
      - xpack.security.transport.ssl.verification_mode=certificate
      - xpack.security.transport.ssl.client_authentication=optional
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s --cacert config/certs/ca.crt https://elastic:9200 | grep -q 'missing authentication credentials'",
        ]
      interval: 10s
      timeout: 10s
      retries: 120

  kibana:
    depends_on:
      elasticsearch:
        condition: service_healthy
    image: docker.elastic.co/kibana/kibana:8.12.2
    container_name: kibana
    volumes:
      - ./certs:/usr/share/kibana/config/certs:z
      - ./kibana-data:/usr/share/kibana/data
      - ./kibana.yml:/usr/share/kibana/config/kibana.yml:Z
    ports:
      - 5601:5601
    environment:
      - SERVER_NAME=kibana
      - ELASTICSEARCH_HOSTS=https://elastic:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=kibana
      - ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES=config/certs/ca.crt
      - SERVER_SSL_ENABLED=true
      - SERVER_SSL_CERTIFICATE=config/certs/kibana.crt
      - SERVER_SSL_KEY=config/certs/kibana.key
      - SERVER_SSL_CERTIFICATEAUTHORITIES=config/certs/ca.crt
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -I -s --cacert config/certs/ca.crt https://kibana:5601 | grep -q 'HTTP/1.1 302 Found'",
        ]
      interval: 10s
      timeout: 10s
      retries: 120

  fleet-server:
      depends_on:
        kibana:
          condition: service_healthy
        elasticsearch:
          condition: service_healthy
      image: docker.elastic.co/beats/elastic-agent:8.12.2
      container_name: fleet-server
      volumes:
        - ./certs:/certs:z
      ports:
        - 8220:8220
      restart: always
      user: "1000"
      environment:
        - FLEET_ENROLL=1
        - FLEET_SERVER_POLICY_ID=fleet-server-policy
        - FLEET_SERVER_ENABLE=1
        - KIBANA_FLEET_SETUP=1
        - KIBANA_HOST=https://kibana:5601
        - FLEET_URL=https://fleet-server:8220
        - FLEET_SERVER_ELASTICSEARCH_HOST=https://elastic:9200
        - FLEET_CA=/certs/ca.crt
        - KIBANA_FLEET_USERNAME=elastic
        - KIBANA_FLEET_PASSWORD=elastic
        - FLEET_SERVER_CERT=/certs/fleet-server.crt
        - FLEET_SERVER_CERT_KEY=/certs/fleet-server.key
        - FLEET_SERVER_ELASTICSEARCH_CA=/certs/ca.crt
        - KIBANA_FLEET_CA=/certs/ca.crt
```
The ```kibana.yml``` should contain the following content:

```yaml

```
## Fleet Managed Elastic Agent Without the UI


```bash
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

curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPUT "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/settings" \
    -d "$(printf '{"fleet_server_hosts": ["%s"]}' "https://${FLEET_SERVER_HOSTNAME}:${FLEET_SERVER_PORT}")"


curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    -XPUT "${HEADERS[@]}" \
    "${KIBANA_URL}/api/fleet/outputs/fleet-default-output" \
    -d "$(printf '{"hosts": ["%s"], "config_yaml": "ssl.verification_mode: certificate\\nssl.certificate_authorities: [\\"%s\\"]"}' "https://${ELASTIC_HOSTNAME}:${ELASTIC_PORT}" "$(pwd)/ca/ca.crt")" 

ENROLLMENT_TOKEN=$(curl -k -s \
  -u ${ELASTIC_USERNAME}:${ELASTIC_PASSWORD} \
  ${KIBANA_URL}/api/fleet/enrollment_api_keys | \
  jq -r '.items[] | select(any(.; .policy_id == "elasticsearch-policy")) | .api_key')


sudo ./elastic-agent-8.12.2-linux-x86_64/elastic-agent install \
    --base-path=${HOME} \
    --url=https://localhost:8220 \
    --enrollment-token=${ENROLLMENT_TOKEN} \
    --certificate-authorities=$(pwd)/ca/ca.crt \
    --force
```

<!--
openssl req ... -subj "${SUBJ}"


https://www.youtube.com/watch?v=GIpXT_tqmA8
https://github.com/peasead/elastic-container/tree/main
https://www.elastic.co/guide/en/fleet/current/elastic-agent-container.html
https://www.elastic.co/guide/en/fleet/8.9/elastic-agent-cmd-options.html#elastic-agent-install-command
-->
