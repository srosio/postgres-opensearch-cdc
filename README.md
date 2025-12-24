# PostgreSQL to OpenSearch CDC Pipeline

A real-time Change Data Capture (CDC) pipeline that streams data from PostgreSQL to OpenSearch using Debezium and Kafka.

## Architecture

```
┌─────────────┐    ┌───────────┐    ┌─────────┐    ┌────────────┐
│ PostgreSQL  │───▶│ Debezium  │───▶│  Kafka  │───▶│ OpenSearch │
│  (Source)   │    │  (CDC)    │    │(Broker) │    │  (Target)  │
└─────────────┘    └───────────┘    └─────────┘    └────────────┘
```

**Data Flow:**
1. PostgreSQL captures changes using logical replication
2. Debezium reads changes and publishes to Kafka topics
3. Python consumer reads from Kafka and writes to OpenSearch

## Components

| Service | Port | Description |
|---------|------|-------------|
| PostgreSQL | 5432 | Source database (existing container: `postgres_container`) |
| OpenSearch | 9200 | Target search engine (existing container: `ops`) |
| Zookeeper | 2181 | Kafka coordination service |
| Kafka | 9092, 29092 | Message broker |
| Kafka UI | 8080 | Web UI for monitoring Kafka topics |
| Debezium Connect | 8083 | CDC connector for PostgreSQL |

## Prerequisites

- Docker and Docker Compose installed
- PostgreSQL container named `postgres_container` running
- OpenSearch container named `ops` running
- Python 3 with `kafka-python` and `requests` libraries
- `curl` and `jq` commands available

## Quick Start

### 1. Start CDC Services

```bash
# Start Kafka, Zookeeper, Debezium, and Kafka UI
docker-compose -f docker-compose-cdc-only.yml up -d

# Wait for services to be healthy (30-60 seconds)
docker ps
```

### 2. Configure PostgreSQL for CDC

PostgreSQL must be configured with logical replication enabled. Restart your PostgreSQL container with these flags:

```bash
# Stop existing PostgreSQL
docker stop postgres_container
docker rm postgres_container

# Start with CDC configuration
docker run -d --name postgres_container \
  -e POSTGRES_PASSWORD=root \
  -p 5432:5432 \
  -v core_postgres_data:/var/lib/postgresql/data \
  postgres:14-alpine \
  -c wal_level=logical \
  -c max_wal_senders=4 \
  -c max_replication_slots=4
```

### 3. Setup Database Publication

```bash
# Connect to PostgreSQL
docker exec -it postgres_container psql -U postgres -d instance_template

# Enable REPLICA IDENTITY FULL (captures all column values)
ALTER TABLE public.m_savings_account_transaction REPLICA IDENTITY FULL;

# Create publication for CDC
CREATE PUBLICATION instance_template_publication
FOR TABLE public.m_savings_account_transaction;

# Verify publication
SELECT * FROM pg_publication_tables WHERE pubname = 'instance_template_publication';

# Exit
\q
```

### 4. Register Debezium Connector

```bash
curl -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "instance-template-source",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "host.docker.internal",
      "database.port": "5432",
      "database.user": "postgres",
      "database.password": "root",
      "database.dbname": "instance_template",
      "database.server.name": "postgres",
      "table.include.list": "public.m_savings_account_transaction",
      "publication.name": "instance_template_publication",
      "slot.name": "instance_template_slot",
      "plugin.name": "pgoutput",
      "snapshot.mode": "initial",
      "key.converter": "org.apache.kafka.connect.json.JsonConverter",
      "key.converter.schemas.enable": "false",
      "value.converter": "org.apache.kafka.connect.json.JsonConverter",
      "value.converter.schemas.enable": "false"
    }
  }'

# Verify connector is RUNNING
curl http://localhost:8083/connectors/instance-template-source/status | jq
```

### 5. Create OpenSearch Index

```bash
curl -X PUT 'http://localhost:9200/m_savings_account_transaction' \
  -H 'Content-Type: application/json' \
  -d '{
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "id": {"type": "long"},
        "amount": {"type": "double"},
        "transaction_date": {"type": "date"},
        "savings_account_id": {"type": "long"},
        "office_id": {"type": "long"},
        "created_date": {"type": "date"},
        "running_balance_derived": {"type": "double"}
      }
    }
  }'
```

### 6. Install Python Dependencies

```bash
pip3 install kafka-python requests
```

### 7. Start Python Sync Script

```bash
# Run in foreground to monitor
python3 kafka-to-opensearch.py

# Or run in background
nohup python3 kafka-to-opensearch.py > kafka-sync.log 2>&1 &
```

## Verification

### Quick Test Script

```bash
./quick-test.sh
```

This script checks:
- CDC services are running and healthy
- PostgreSQL configuration (wal_level=logical)
- Debezium connector status
- Kafka topics exist
- OpenSearch index exists
- Document counts match between PostgreSQL and OpenSearch

### Manual Verification

```bash
# 1. Check Kafka topic exists
docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list | grep m_savings_account_transaction

# 2. View Kafka messages
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic m_savings_account_transaction \
  --from-beginning \
  --max-messages 5

# 3. Check OpenSearch index
curl 'http://localhost:9200/_cat/indices?v' | grep m_savings_account_transaction

# 4. Count documents
curl 'http://localhost:9200/m_savings_account_transaction/_count?pretty'

# 5. Compare counts
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT COUNT(*) FROM public.m_savings_account_transaction;"
```

## Testing CDC Flow

### Insert Test Data

```bash
# Connect to PostgreSQL
docker exec -it postgres_container psql -U postgres -d instance_template

# Insert new transaction
INSERT INTO public.m_savings_account_transaction
(amount, transaction_date, is_reversed, transaction_type_enum, savings_account_id,
 office_id, booking_date, created_date, status_enum, is_runningbalance_derived,
 is_interest_posted, is_enriched, running_balance_derived)
VALUES
(500.00, CURRENT_DATE, false, 1, 1, 1, CURRENT_DATE, CURRENT_TIMESTAMP,
 0, false, false, false, 500.00);
```

### Update Existing Data

```sql
UPDATE public.m_savings_account_transaction
SET amount = 750.00, running_balance_derived = 750.00
WHERE id = (SELECT MAX(id) FROM public.m_savings_account_transaction);
```

### Delete Data

```sql
DELETE FROM public.m_savings_account_transaction
WHERE id = (SELECT MAX(id) FROM public.m_savings_account_transaction);
```

### Verify in OpenSearch

```bash
# Search for recent transactions
curl 'http://localhost:9200/m_savings_account_transaction/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {"match_all": {}},
    "size": 5,
    "sort": [{"created_date": {"order": "desc"}}]
  }'

# Search by amount
curl 'http://localhost:9200/m_savings_account_transaction/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {"range": {"amount": {"gte": 500}}}
  }'

# Search by savings account
curl 'http://localhost:9200/m_savings_account_transaction/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {"term": {"savings_account_id": 1}}
  }'
```

## Monitoring

### Kafka UI

Open http://localhost:8080 in your browser to:
- View Kafka topics and messages
- Monitor consumer groups
- Inspect message schemas and payloads
- Check broker health

### Check Connector Status

```bash
# Debezium source connector
curl http://localhost:8083/connectors/instance-template-source/status | jq

# Expected output:
# {
#   "name": "instance-template-source",
#   "connector": {
#     "state": "RUNNING",
#     "worker_id": "..."
#   },
#   "tasks": [...]
# }
```

### View Kafka Messages

```bash
# View raw CDC messages
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic m_savings_account_transaction \
  --from-beginning \
  --max-messages 1

# Example CDC message structure:
# {
#   "before": null,
#   "after": {
#     "id": 1,
#     "amount": 1000000.0,
#     "transaction_date": 19723,
#     "savings_account_id": 1,
#     ...
#   },
#   "op": "r",  # r=read, c=create, u=update, d=delete
#   "ts_ms": 1734000000000
# }
```

### Check Python Sync Script

```bash
# If running in background
tail -f kafka-sync.log

# Check process is running
ps aux | grep kafka-to-opensearch.py
```

## Troubleshooting

### PostgreSQL wal_level Not Logical

**Error:** Debezium fails with "wal_level must be logical"

**Fix:**
```bash
# Verify current setting
docker exec postgres_container psql -U postgres -c "SHOW wal_level;"

# If not 'logical', recreate container with flags (see Setup step 2)
```

### Kafka Topic Not Created

**Issue:** Topic `m_savings_account_transaction` doesn't exist

**Fix:**
```bash
# Check Debezium connector status
curl http://localhost:8083/connectors/instance-template-source/status | jq

# If connector failed, check logs
docker logs debezium

# Restart connector
curl -X POST http://localhost:8083/connectors/instance-template-source/restart
```

### OpenSearch Index Not Found

**Error:** `index_not_found_exception`

**Fix:**
```bash
# Create the index (see Setup step 5)
curl -X PUT 'http://localhost:9200/m_savings_account_transaction' ...

# Restart Python sync script to populate data
```

### Documents Not Syncing

**Issue:** PostgreSQL has data but OpenSearch is empty

**Checks:**
```bash
# 1. Verify Debezium is capturing changes
curl http://localhost:8083/connectors/instance-template-source/status | jq '.tasks[0].state'

# 2. Check Kafka has messages
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic m_savings_account_transaction \
  --max-messages 1

# 3. Verify Python script is running
ps aux | grep kafka-to-opensearch.py

# 4. Check Python script output
tail -f kafka-sync.log
```

### Replication Slot Already Exists

**Error:** Connector fails with "replication slot already exists"

**Fix:**
```bash
# List replication slots
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT * FROM pg_replication_slots;"

# Drop the slot
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT pg_drop_replication_slot('instance_template_slot');"

# Re-register Debezium connector
```

### Service Not Healthy

**Issue:** Docker containers not passing health checks

**Fix:**
```bash
# Check specific service logs
docker logs debezium
docker logs kafka
docker logs zookeeper

# Restart specific service
docker-compose -f docker-compose-cdc-only.yml restart debezium

# Or restart all CDC services
docker-compose -f docker-compose-cdc-only.yml down
docker-compose -f docker-compose-cdc-only.yml up -d
```

## Configuration Details

### PostgreSQL Settings

Required configuration for CDC:
- **wal_level**: `logical` - Enables logical replication
- **max_wal_senders**: `4` - Maximum concurrent WAL senders
- **max_replication_slots**: `4` - Maximum replication slots

### Debezium Connector Settings

| Setting | Value | Description |
|---------|-------|-------------|
| connector.class | PostgresConnector | Debezium PostgreSQL connector |
| plugin.name | pgoutput | Native PostgreSQL logical decoding |
| snapshot.mode | initial | Full snapshot on first run, then stream changes |
| table.include.list | public.m_savings_account_transaction | Tables to capture |
| publication.name | instance_template_publication | PostgreSQL publication name |
| slot.name | instance_template_slot | Replication slot name |

### Python Sync Script

The `kafka-to-opensearch.py` script:
- Consumes messages from Kafka topic
- Extracts the `after` field from CDC events (contains the new row data)
- Writes to OpenSearch using document ID from PostgreSQL
- Handles deletes by removing documents from OpenSearch
- Auto-commits offsets to track progress

## Useful Commands

### Connector Management

```bash
# List all connectors
curl http://localhost:8083/connectors

# Get connector config
curl http://localhost:8083/connectors/instance-template-source | jq

# Delete connector
curl -X DELETE http://localhost:8083/connectors/instance-template-source

# Restart connector
curl -X POST http://localhost:8083/connectors/instance-template-source/restart
```

### Kafka Operations

```bash
# List all topics
docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list

# Describe topic
docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
  --describe --topic m_savings_account_transaction

# Get topic message count (approximate)
docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic m_savings_account_transaction

# Delete topic (if needed)
docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
  --delete --topic m_savings_account_transaction
```

### OpenSearch Operations

```bash
# List all indices
curl 'http://localhost:9200/_cat/indices?v'

# Get index mapping
curl 'http://localhost:9200/m_savings_account_transaction/_mapping?pretty'

# Get index settings
curl 'http://localhost:9200/m_savings_account_transaction/_settings?pretty'

# Count documents
curl 'http://localhost:9200/m_savings_account_transaction/_count?pretty'

# Delete index
curl -X DELETE 'http://localhost:9200/m_savings_account_transaction'

# Search all documents
curl 'http://localhost:9200/m_savings_account_transaction/_search?pretty&size=100'
```

### Database Operations

```bash
# Connect to PostgreSQL
docker exec -it postgres_container psql -U postgres -d instance_template

# View table structure
\d public.m_savings_account_transaction

# Check row count
SELECT COUNT(*) FROM public.m_savings_account_transaction;

# View recent transactions
SELECT id, amount, transaction_date, created_date
FROM public.m_savings_account_transaction
ORDER BY created_date DESC
LIMIT 10;

# Check replication slots
SELECT * FROM pg_replication_slots;

# Check publications
SELECT * FROM pg_publication_tables WHERE pubname = 'instance_template_publication';
```

## Cleanup

### Stop CDC Services (Preserve Data)

```bash
docker-compose -f docker-compose-cdc-only.yml down
```

### Stop and Remove All Data

```bash
# Stop CDC services and remove volumes
docker-compose -f docker-compose-cdc-only.yml down -v

# Delete OpenSearch index
curl -X DELETE 'http://localhost:9200/m_savings_account_transaction'

# Drop PostgreSQL publication and slot
docker exec postgres_container psql -U postgres -d instance_template -c "
  DROP PUBLICATION IF EXISTS instance_template_publication;
  SELECT pg_drop_replication_slot('instance_template_slot');
"
```

## Project Files

```
opensearch_pql_cdc/
├── README.md                        # This file
├── docker-compose-cdc-only.yml      # CDC services (Kafka, Debezium, etc.)
├── kafka-to-opensearch.py           # Python sync script
├── quick-test.sh                    # Quick verification script
└── verify-instance-template-cdc.sh  # Detailed verification script
```

## Use Cases

- **Real-time Search**: Search and analyze savings transactions as they happen
- **Analytics & Reporting**: Build dashboards in OpenSearch Dashboards
- **Audit Trail**: Maintain searchable logs of all database changes
- **Event-Driven Systems**: React to transaction events via Kafka consumers
- **Data Synchronization**: Keep OpenSearch in sync with PostgreSQL

## Next Steps

1. **Add More Tables**: Modify connector to capture additional tables
   ```bash
   # Update table.include.list to:
   "table.include.list": "public.m_savings_account_transaction,public.m_savings_account,public.m_client"
   ```

2. **Build Dashboards**: Use OpenSearch Dashboards at http://localhost:5601

3. **Scale Up**: Increase Kafka partitions for higher throughput
   ```bash
   docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
     --alter --topic m_savings_account_transaction --partitions 3
   ```

4. **Production Hardening**:
   - Enable SSL/TLS for all connections
   - Add authentication (PostgreSQL, Kafka, OpenSearch)
   - Configure retention policies for Kafka topics
   - Set up monitoring and alerts
   - Implement backup strategies

## License

MIT License
