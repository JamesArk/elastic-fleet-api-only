# UI-less Fleet Managed Elastic Agents: A guide

A guide on how to setup Fleet Server and Fleet managed elastic agents in Elasticsearch using only REST API calls, avoiding Kibana UI.

## What are Fleet managed Elastic Agents?
Elastic Agents are a software that runs on a host machine that collects logs, metrics and other data from services running on the same host. 

Fleet managed Elastic Agents are a centrally managed in the Kibana UI, where you can create/update  Agent Policies, upgrade Elastic Agents, check the current health status of your Elastic Agents and add/update Elastic Agent integrations for app specific behaviour when collecting of logs and metrics. 

Elastic Agents also need to communicate through Fleet Servers, the service responsible for spreading the changes we apply through the Kibana UI to all relevant Elastic Agents. It is also responsible for spreading new changes to enrollment and unenrollment of Elastic Agents.

## Why make this guide?

Elasticsearch provides great documentation on how to set up your own [fleet server](https://www.elastic.co/guide/en/fleet/8.12/add-fleet-server-on-prem.html) and [fleet managed elastic agents](https://www.elastic.co/guide/en/fleet/8.12/install-fleet-managed-elastic-agent.html), but there are a few caveats:

- **Reliance on the Kibana UI**: When we want to experiment with Elasticsearch deployment and keep erasing its data for a clean state or we just want to automate things to remove human error, using the UI should be avoided as much as you can.
- **Monitoring the host machine with the Fleet Server**: Elastic Agents should be installed at the host level in order to get the most accurate metrics of the host and applications running on the host. However, we might not want to monitor the host the fleet-server is running on. The Kibana UI assumes you will install the fleet server at the host level, which may or may not be possible or desirable. It might be less important or relevant for us to monitor the host machine the fleet server is running on, maybe because it is not as important as the other hosts (Like a "frontend" host machine that hosts frontend/UI applications and services like Kibana).
- 
- **Unclear complete setup for containerized Fleet Server and Elastic Agents**: In the Elastic Documentation guide on elastic agents in a [container](https://www.elastic.co/guide/en/fleet/8.12/elastic-agent-container.html), we get a nice step by step guide on how to run elastic-agents in containers. The catch is ... it uses Kibana's Fleet UI. It assumes you would like to create an agent policy and Elastic Agent integration through the kibana UI. And as stated before, sometimes we would like to avoid the Kibana UI, so that we can automate enrollment of Elastic Agents, the creation of new Agent Policies and the addition or editing of Elastic Agent integrations.

Please note that Elasticsearch has documentation on the [Fleet REST API](https://www.elastic.co/guide/en/fleet/8.12/fleet-api-docs.html), that gives us enough tools to set up our own Fleet Server and Fleet managed Elastic Agents and as well as everything the Kibana UI can do with Fleet. There is also a declarative way to add Agent policies through the kibana.yml [here](https://www.elastic.co/guide/en/fleet/8.12/create-a-policy-no-ui.html#use-preconfiguration-to-create-policy), however, in my experience, updating the agent policies in already set up Elasticsearch Cluster and Kibana was a bit "flacky".

The problem lies in the lack of a streamlined step by step guide on setting up a Fleet Server and fleet managed elastic agents using **ONLY** the provided Fleet REST APIs and not relying on the Kibana UI in **ANY** of the steps.

With the "why" out of the way, let's get started with what is necessary to have a Fleet Server and Fleet managed Elastic Agents.
### What we need
In order to have our own Fleet Server and Fleet managed Elastic Agents, we need to have:
- An Elasticsearch Cluster
- A Kibana instance
- Certificates and keys for all services (Elasticsearch, Kibana and Fleet Server)

First, let's create our own self signed CA to create the certificates and keys so that the services that will be using in this guide can authenticate themselves.

### Self Signed CA and certificates

Elasticsearch has a nice tool for creating self signed CA's and other certificates that work well on Elastic products. To configure SSL/TLS using this tool, you can check out their [guide](https://www.elastic.co/guide/en/fleet/8.12/secure-connections.html), but in this guide we will be creating our own CA, certificates and certificate keys using [openssl](https://www.openssl.org/).

Let's start by creating our own CA certificate and key with an expiration of 10 years:

```bash
mkdir ca && \
openssl req -x509 \
-newkey rsa:4096 \
-keyout ca/ca.key \
-out ca/ca.crt \
-sha256 -days 3650 \
-noenc -subj "/C=PT/ST=Lisbon/L=Lisbon/O=Marionete/OU=IT/CN=marionete"
```

Now that we have our own self signed CA, we can create our own certificates and keys for the services. 

In this guide, we will need the following services: Elasticsearch, Kibana and a Fleet Server. Each service will have a key and a certificate of their own to authenticate themselves with the other services.

In the next few steps, ```<service>``` can take the following values: ```elastic```,```kibana``` and ```fleet-server```.

- Include the CA certificate we just created in all services:
```bash
mkdir certs && cp ca/ca.crt certs
```
- Generate a key
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

Once we have our certificates and keys for all services, we will deploy them using docker compose.
## Deploying Elastic, Kibana and a Fleet Server
We can deploy kibana, a single elasticsearch node and a single fleet server using the following ```docker-compose.yml```:
```yaml
version: "2.2"

services:
  setup:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.2
    container_name: elasticsearch-setup-container
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
      test: ["CMD-SHELL", "[ -f config/certs/ca.crt ]"]
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
    mem_limit: 2147483648 # ~ 2gb
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
    mem_limit: 2147483648 # ~ 2gb
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
This docker compose file will deploy a single node elasticsearch cluster with security enabled, set up and deploy kibana and deploy a fleet server.(Don't forget to create ```elastic-data``` and ```kibana-data``` directories for the volumes)

The ```kibana.yml``` file should contain at least the following content:

```yaml
xpack.encryptedSavedObjects.encryptionKey: "random-string-above-32-or-more-characters"
server.host: "0.0.0.0"
xpack.fleet.packages:
  - name: fleet_server
    version: latest
  - name: system
    version: latest
xpack.fleet.agentPolicies:
  - name: Fleet-Server-Policy
    id: fleet-server-policy
    namespace: default
    monitoring_enabled: []
    package_policies:
      - name: fleet_server-1
        package:
          name: fleet_server
```
Once the services are deployed, we can set up Fleet Settings and enroll fleet managed Elastic Agents.
## Fleet Managed Elastic Agents Without the UI
To deploy an Elastic Agent that is managed by Fleet we need to:
- Create an agent policy for the elastic agent to enroll into.
- Add an Elastic Agent integration to our agent policy.
- Setup the Default output and fleet server hosts.
- Install the Elastic Agent on the machine we want to monitor.

All of these steps are documented by Elastic using the UI but we will be using REST API calls with [curl](https://curl.se/) and [jq](https://jqlang.github.io/jq/) commands instead.

Let's start with creating a new agent policy. According to [Elastic documentation](https://www.elastic.co/guide/en/fleet/8.12/create-a-policy-no-ui.html), this step is rather straight forward. With the following command, we create a new agent policy named "Elastic-policy" with a custom identifier (this will come in handy in the next few steps).

```bash
curl -k -s -u "elastic:elastic" \
    -XPOST -H "kbn-xsrf: kibana" -H "Content-type: application/json" \
    "https://localhost:5601/api/fleet/agent_policies" \
    -d '{"id":"elastic-policy","name":"Elastic-Policy","namespace":"default","monitoring_enabled":["logs","metrics"]}'
```
If successful, the command will return a json of the created Agent Policy. After creating the agent policy with a custom identifier, we can add Elastic Agent integrations to it with this command:
```bash
curl -k -s -u "elastic:elastic" \
    -XPOST -H "kbn-xsrf: kibana" -H "Content-type: application/json" \
    "https://localhost:5601/api/fleet/package_policies" \
    -d '{"name":"Elastic-System-package","namespace":"default","policy_id":"elastic-policy", "package":{"name": "system", "version":"1.54.0"}}'
```
Next, we add a Fleet Server host:
```bash
curl -k -s -u "elastic:elastic" \
    -XPUT -H "kbn-xsrf: kibana" -H "Content-type: application/json" \
    "https://localhost:5601/api/fleet/settings" \
    -d '{"fleet_server_hosts": ["https://localhost:8220"]}'
```
To make all Elastic Agents send to our Elasticsearch cluster, we need to define the default output for fleet with the following command:
```bash
curl -k -s -u "elastic:elastic" \
    -XPUT -H "kbn-xsrf: kibana" -H "Content-type: application/json" \
    "https://localhost:5601/api/fleet/outputs/fleet-default-output" \
    -d '{"hosts": ["https://localhost:9200"], "config_yaml": "ssl.verification_mode: certificate\nssl.certificate_authorities: [\"/path/to/ca/ca.crt\"]"}'
```
Note that ```/path/to/ca/ca.crt``` will be the same for all Elastic Agents, so make sure the CA certificate has the same path on all machines that have an Elastic Agent installed.

Next, we download the appropriate Elastic Agent binary version for our host machine (in this case linux with x86_64 architecture) and unarchive it.
```bash
wget https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.12.2-linux-x86_64.tar.gz

tar xvzf elastic-agent-8.12.2-linux-x86_64.tar.gz 
```

And finally, we get our agent policy enrollment token and use it when installing the Elastic Agent in our host machine.
```bash
ENROLLMENT_TOKEN=$(curl -k -s \
  -u elastic:elastic \
  https://localhost:5601/api/fleet/enrollment_api_keys | \
  jq -r '.items[] | select(any(.; .policy_id == "elastic-policy")) | .api_key')

sudo ./elastic-agent-8.12.2-linux-x86_64/elastic-agent install \
    --base-path=/path/to/install/dir \
    --url=https://localhost:8220 \
    --enrollment-token=${ENROLLMENT_TOKEN} \
    --certificate-authorities=/path/to/ca/ca.crt \
    --force
```
Note that "/path/to/install/dir" is where the Elastic Agent will store its logs and configurations. And since we are using sudo, only sudo users can access that directory and its contents.

Once the installation is complete, you should see a new Elastic Agent appear in the [fleet page](https://localhost:5601/app/fleet) and system metrics about the host machine in this [dashboard](https://localhost:5601/app/dashboards#/view/system-Metrics-system-overview).

# Summary
Elastic's documentation is an extremely useful resource and should always be used when developing with Elastic's products. Setting up a Fleet Server and Fleet managed elastic agents is quite simple with the Kibana UI and without the Kibana UI, we can use the REST API that is just as easy if not easier. The lack of a straightforward guide using only the Fleet REST API was the problem and I hope this guide has helped to minimize the problem. There are developers who can't or don't desire to always rely on Kibana to set up any Fleet Server or Fleet managed Elastic Agents. Fleet's REST API is well documented and I highly urge you to explore it to figure out your exact needs when it comes to your Fleet Server and Fleet managed Elastic Agents.