# PostgreSQL to OpenSearch CDC Pipeline

Real-time Change Data Capture (CDC) pipeline that streams data from PostgreSQL to OpenSearch using Debezium and Kafka.

## Table of Contents

- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Setup Instructions](#setup-instructions)
- [Usage](#usage)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)

## Architecture

```
┌─────────────┐    ┌───────────┐    ┌─────────┐    ┌────────────┐
│ PostgreSQL  │───▶│ Debezium  │───▶│  Kafka  │───▶│ OpenSearch │
│  (Source)   │    │  (CDC)    │    │(Broker) │    │  (Target)  │
└─────────────┘    └───────────┘    └─────────┘    └────────────┘
                                           │
                                           ▼
                                  ┌─────────────────┐
                                  │ Python Consumer │
                                  └─────────────────┘
```

**Data Flow:**
1. PostgreSQL captures changes using logical replication (`wal_level=logical`)
2. Debezium reads WAL (Write-Ahead Log) and publishes CDC events to Kafka topics
3. Python consumer reads from Kafka and writes to OpenSearch

**Components:**

| Service | Port | Description |
|---------|------|-------------|
| PostgreSQL | 5432 | Source database (existing: `postgres_container`) |
| OpenSearch | 9200 | Target search engine (existing: `ops`) |
| Zookeeper | 2181 | Kafka coordination |
| Kafka | 9092, 29092 | Message broker |
| Kafka UI | 8080 | Web interface for monitoring |
| Debezium Connect | 8083 | CDC connector |

## Quick Start

### Prerequisites

- Docker and Docker Compose
- PostgreSQL container named `postgres_container` running
- OpenSearch container named `ops` running
- Python 3 with `kafka-python` and `requests`

### Installation

```bash
# 1. Install Python dependencies
pip3 install kafka-python requests

# 2. Start CDC services
docker-compose -f docker-compose-cdc-only.yml up -d

# 3. Wait for services to be healthy (30-60 seconds)
docker ps
```

### Setup Tables for CDC

**Option A: m_savings_account_transaction (Single Table)**

```bash
./setup-savings-table.sh         # Configure PostgreSQL
./register-debezium-savings.sh   # Register Debezium
./create-opensearch-indices.sh   # Create OpenSearch indices
python3 kafka-to-opensearch.py   # Start syncing
```

**Option B: Card Tables (Multiple Tables with Existing Data)**

```bash
./setup-card-tables.sh           # Configure PostgreSQL
./register-debezium-cards.sh     # Register Debezium
./create-opensearch-indices.sh   # Create OpenSearch indices
python3 kafka-to-opensearch-multi.py  # Start syncing (supports all tables)
```

### Verification

```bash
./quick-test.sh  # Automated health check
```

## Configuration

All configuration is centralized in **`config.sh`**. Edit this file to customize:

```bash
# PostgreSQL
POSTGRES_CONTAINER="postgres_container"
POSTGRES_DATABASE="instance_template"

# OpenSearch
OPENSEARCH_URL="http://localhost:9200"

# Kafka
KAFKA_BOOTSTRAP_EXTERNAL="localhost:29092"

# Table configurations
TABLE_CARD="card"
TABLE_AUTHORIZE_TX="authorize_transaction"
TABLE_CARD_AUTH="card_authorization"
```

All setup scripts source this configuration automatically.

## Setup Instructions

### 1. PostgreSQL Configuration

PostgreSQL must be configured with logical replication:

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

**Verify:**
```bash
docker exec postgres_container psql -U postgres -c "SHOW wal_level;"
# Should output: logical
```

### 2. Table Setup

Each table needs two configurations:
1. **REPLICA IDENTITY FULL** - Captures all column values
2. **Publication** - Defines which tables to replicate

**For m_savings_account_transaction:**

```sql
docker exec -it postgres_container psql -U postgres -d instance_template

ALTER TABLE public.m_savings_account_transaction REPLICA IDENTITY FULL;
CREATE PUBLICATION instance_template_publication
FOR TABLE public.m_savings_account_transaction;
```

**For card tables:**

```sql
ALTER TABLE public.card REPLICA IDENTITY FULL;
ALTER TABLE public.authorize_transaction REPLICA IDENTITY FULL;
ALTER TABLE public.card_authorization REPLICA IDENTITY FULL;

CREATE PUBLICATION card_tables_publication FOR TABLE
  public.card,
  public.authorize_transaction,
  public.card_authorization;
```

**Or use the setup scripts:**
```bash
./setup-savings-table.sh   # For savings transactions
./setup-card-tables.sh     # For card tables
```

### 3. Debezium Connector Registration

Register connectors to start capturing changes:

```bash
# For savings transactions
./register-debezium-savings.sh

# For card tables
./register-debezium-cards.sh
```

**Manual registration example:**

```bash
curl -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "card-tables-source",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "host.docker.internal",
      "database.port": "5432",
      "database.user": "postgres",
      "database.password": "root",
      "database.dbname": "instance_template",
      "database.server.name": "postgres",
      "table.include.list": "public.card,public.authorize_transaction,public.card_authorization",
      "publication.name": "card_tables_publication",
      "slot.name": "card_tables_slot",
      "plugin.name": "pgoutput",
      "snapshot.mode": "initial",
      "key.converter": "org.apache.kafka.connect.json.JsonConverter",
      "key.converter.schemas.enable": "false",
      "value.converter": "org.apache.kafka.connect.json.JsonConverter",
      "value.converter.schemas.enable": "false"
    }
  }'
```

**Key Settings:**
- `snapshot.mode: initial` - Captures existing data on first run, then streams changes
- `plugin.name: pgoutput` - PostgreSQL's native logical decoding plugin
- `table.include.list` - Comma-separated list of tables to capture

### 4. OpenSearch Index Creation

Create indices with appropriate mappings:

```bash
./create-opensearch-indices.sh
```

This creates indices for all configured tables with optimized field mappings.

### 5. Start Python Consumer

**Single-table consumer:**
```bash
python3 kafka-to-opensearch.py
```

**Multi-table consumer (recommended):**
```bash
# Foreground (see progress)
python3 kafka-to-opensearch-multi.py

# Background
nohup python3 kafka-to-opensearch-multi.py > cdc-sync.log 2>&1 &
```

**Consumer features:**
- Subscribes to multiple Kafka topics simultaneously
- Handles INSERT/UPDATE (upserts to OpenSearch)
- Handles DELETE (removes from OpenSearch)
- Shows progress with emojis:
  - 📸 Snapshot (existing data)
  - ➕ Create
  - ✏️ Update
  - 🗑️ Delete

## Usage

### Working with Tables that Have Existing Data

The `card` table has existing data. Here's how it works:

1. **Automatic Snapshot:**
   - Debezium's `snapshot.mode: initial` captures ALL existing rows
   - Each row is published as CDC event with `op: "r"` (read/snapshot)
   - Snapshot happens ONCE on first connector registration

2. **After Snapshot:**
   - Switches to real-time streaming
   - Captures INSERT, UPDATE, DELETE as they happen

3. **No Manual Data Migration Needed:**
   - Just start the connector and consumer
   - Existing data syncs automatically
   - Real-time changes follow immediately

### Testing CDC Flow

**Insert test data:**

```sql
docker exec -it postgres_container psql -U postgres -d instance_template

INSERT INTO public.m_savings_account_transaction
(amount, transaction_date, is_reversed, transaction_type_enum,
 savings_account_id, office_id, booking_date, created_date,
 status_enum, running_balance_derived)
VALUES
(500.00, CURRENT_DATE, false, 1, 1, 1, CURRENT_DATE,
 CURRENT_TIMESTAMP, 0, 500.00);
```

**Update data:**

```sql
UPDATE public.card SET status = 'BLOCKED' WHERE id = 1;
```

**Delete data:**

```sql
DELETE FROM public.card_authorization WHERE id = 12345;
```

**Verify in OpenSearch:**

```bash
# Search recent changes
curl 'http://localhost:9200/card/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {"match_all": {}},
    "size": 5,
    "sort": [{"updated_at": {"order": "desc"}}]
  }'

# Count documents
curl 'http://localhost:9200/card/_count?pretty'

# Search by field
curl 'http://localhost:9200/card_authorization/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {"term": {"card_id": 123}}
  }'
```

### Adding More Tables

1. **Configure PostgreSQL table:**
```sql
ALTER TABLE schema.new_table REPLICA IDENTITY FULL;
ALTER PUBLICATION card_tables_publication ADD TABLE schema.new_table;
```

2. **Update Debezium connector:**
```bash
# Delete and recreate connector with updated table.include.list
curl -X DELETE http://localhost:8083/connectors/card-tables-source

# Re-register with new table added to table.include.list
./register-debezium-cards.sh  # (edit script first to add new table)
```

3. **Create OpenSearch index:**
```bash
curl -X PUT 'http://localhost:9200/new_table' \
  -H 'Content-Type: application/json' \
  -d '{"settings": {...}, "mappings": {...}}'
```

4. **Update Python consumer:**

Edit `kafka-to-opensearch-multi.py` and add topic mapping:

```python
TOPIC_INDEX_MAPPING = {
    # ... existing mappings ...
    'postgres.public.new_table': 'new_table',
}
```

5. **Restart consumer**

## Monitoring

### Quick Health Check

```bash
./quick-test.sh
```

Checks:
- CDC services are running
- PostgreSQL configuration (wal_level=logical)
- Debezium connector status
- Kafka topics exist
- OpenSearch indices exist
- Document counts match

### Kafka UI

Open **http://localhost:8080** to:
- View topics and messages
- Monitor consumer groups and lag
- Inspect message schemas
- Check broker health

### Check Connector Status

```bash
# List all connectors
curl http://localhost:8083/connectors

# Check specific connector
curl http://localhost:8083/connectors/card-tables-source/status | jq

# Expected output:
# {
#   "name": "card-tables-source",
#   "connector": {"state": "RUNNING"},
#   "tasks": [{"state": "RUNNING"}]
# }
```

### View Kafka Messages

```bash
# View messages from beginning
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.card \
  --from-beginning \
  --max-messages 5

# View CDC message structure
{
  "before": null,           // Previous state (null for insert)
  "after": {                // New state (null for delete)
    "id": 123,
    "status": "ACTIVE",
    ...
  },
  "op": "r",               // r=snapshot, c=create, u=update, d=delete
  "ts_ms": 1703000000000   // Timestamp
}
```

### Monitor Python Consumer

```bash
# If running in background
tail -f cdc-sync.log

# Check if running
ps aux | grep kafka-to-opensearch

# View statistics (Ctrl+C to see final stats)
```

### Compare Data Counts

```bash
# PostgreSQL count
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT COUNT(*) FROM card;"

# OpenSearch count
curl 'http://localhost:9200/card/_count' | jq '.count'

# Should match after snapshot completes!
```

## Troubleshooting

### PostgreSQL wal_level Not Logical

**Error:** Debezium fails with "wal_level must be logical"

**Fix:**
```bash
# Verify setting
docker exec postgres_container psql -U postgres -c "SHOW wal_level;"

# If not 'logical', recreate container with flags (see Setup section)
```

### Kafka Topic Not Created

**Issue:** Topic doesn't exist after registering connector

**Fix:**
```bash
# Check connector status
curl http://localhost:8083/connectors/card-tables-source/status | jq

# If failed, check logs
docker logs debezium

# Restart connector
curl -X POST http://localhost:8083/connectors/card-tables-source/restart
```

### Replication Slot Already Exists

**Error:** "replication slot already exists"

**Fix:**
```bash
# List slots
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT * FROM pg_replication_slots;"

# Drop slot
docker exec postgres_container psql -U postgres -d instance_template \
  -c "SELECT pg_drop_replication_slot('card_tables_slot');"

# Re-register connector
./register-debezium-cards.sh
```

### Documents Not Syncing

**Issue:** PostgreSQL has data but OpenSearch is empty

**Checks:**
```bash
# 1. Debezium capturing changes?
curl http://localhost:8083/connectors/card-tables-source/status | jq '.tasks[0].state'
# Should be: "RUNNING"

# 2. Kafka has messages?
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.card \
  --max-messages 1

# 3. Python consumer running?
ps aux | grep kafka-to-opensearch

# 4. Check consumer logs
tail -f cdc-sync.log
```

### Snapshot Taking Too Long

**Symptom:** Connector shows "SnapshotReader" for extended time

**This is normal for large tables.** Monitor progress:

```bash
# Check messages in Kafka (indicates snapshot progress)
docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic postgres.public.card

# Check Python consumer stats
tail -f cdc-sync.log
```

**For very large tables (millions of rows):**
- Consider running multiple consumer instances
- Use OpenSearch bulk API (modify consumer)
- Disable index refresh during snapshot

### Service Not Healthy

**Issue:** Docker containers failing health checks

**Fix:**
```bash
# Check logs
docker logs debezium
docker logs kafka
docker logs zookeeper

# Restart specific service
docker-compose -f docker-compose-cdc-only.yml restart debezium

# Or restart all
docker-compose -f docker-compose-cdc-only.yml down
docker-compose -f docker-compose-cdc-only.yml up -d
```

## Advanced Topics

### Connector Configuration Details

**snapshot.mode options:**
- `initial` - Full snapshot on first run, then stream (default)
- `always` - Full snapshot on every connector start
- `never` - Stream changes only, no snapshot
- `exported` - Use PostgreSQL's COPY (faster for large tables)

**Key settings:**
- `table.include.list` - Tables to capture (comma-separated)
- `table.exclude.list` - Tables to exclude
- `publication.name` - PostgreSQL publication name
- `slot.name` - Replication slot name (must be unique per connector)
- `heartbeat.interval.ms` - Keep connection alive

### Performance Tuning

**For large tables:**

1. **Increase Kafka partitions:**
```bash
docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
  --alter --topic postgres.public.card --partitions 3
```

2. **Run multiple consumers:**
```bash
# Same group_id = parallel processing
python3 kafka-to-opensearch-multi.py &
python3 kafka-to-opensearch-multi.py &
```

3. **Disable refresh during snapshot:**
```bash
# Before snapshot
curl -X PUT 'http://localhost:9200/card/_settings' \
  -H 'Content-Type: application/json' \
  -d '{"index": {"refresh_interval": "-1"}}'

# After snapshot
curl -X PUT 'http://localhost:9200/card/_settings' \
  -H 'Content-Type: application/json' \
  -d '{"index": {"refresh_interval": "5s"}}'
```

### Useful Commands

**Connector management:**
```bash
# List connectors
curl http://localhost:8083/connectors

# Delete connector
curl -X DELETE http://localhost:8083/connectors/card-tables-source

# Pause connector
curl -X PUT http://localhost:8083/connectors/card-tables-source/pause

# Resume connector
curl -X PUT http://localhost:8083/connectors/card-tables-source/resume
```

**Kafka operations:**
```bash
# List topics
docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list

# Describe topic
docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
  --describe --topic postgres.public.card

# Delete topic
docker exec kafka kafka-topics --bootstrap-server localhost:9092 \
  --delete --topic postgres.public.card
```

**OpenSearch operations:**
```bash
# List indices
curl 'http://localhost:9200/_cat/indices?v'

# Get mapping
curl 'http://localhost:9200/card/_mapping?pretty'

# Delete index
curl -X DELETE 'http://localhost:9200/card'

# Bulk search
curl 'http://localhost:9200/card/_search?pretty&size=100'
```

### Cleanup

**Stop syncing (preserve data):**
```bash
# Stop consumer
pkill -f kafka-to-opensearch

# Pause connector
curl -X PUT http://localhost:8083/connectors/card-tables-source/pause

# Stop CDC services
docker-compose -f docker-compose-cdc-only.yml down
```

**Remove everything:**
```bash
# Stop CDC services and remove volumes
docker-compose -f docker-compose-cdc-only.yml down -v

# Delete connectors
curl -X DELETE http://localhost:8083/connectors/instance-template-source
curl -X DELETE http://localhost:8083/connectors/card-tables-source

# Drop PostgreSQL publications and slots
docker exec postgres_container psql -U postgres -d instance_template <<EOF
DROP PUBLICATION IF EXISTS instance_template_publication;
DROP PUBLICATION IF EXISTS card_tables_publication;
SELECT pg_drop_replication_slot('instance_template_slot');
SELECT pg_drop_replication_slot('card_tables_slot');
EOF

# Delete OpenSearch indices
curl -X DELETE 'http://localhost:9200/m_savings_account_transaction'
curl -X DELETE 'http://localhost:9200/card'
curl -X DELETE 'http://localhost:9200/authorize_transaction'
curl -X DELETE 'http://localhost:9200/card_authorization'
```

## Project Structure

```
.
├── config.sh                          # Centralized configuration
├── docker-compose-cdc-only.yml        # CDC services definition
│
├── kafka-to-opensearch.py             # Single-table consumer
├── kafka-to-opensearch-multi.py       # Multi-table consumer (recommended)
│
├── setup-savings-table.sh             # Setup savings transaction table
├── setup-card-tables.sh               # Setup card-related tables
│
├── register-debezium-savings.sh       # Register savings connector
├── register-debezium-cards.sh         # Register card connector
│
├── create-opensearch-indices.sh       # Create all OpenSearch indices
│
├── quick-test.sh                      # Automated verification
└── README.md                          # This file
```

## License

MIT License
