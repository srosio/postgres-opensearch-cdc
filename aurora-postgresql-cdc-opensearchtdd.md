# Technical Design Document
## Change Data Capture Pipeline: AWS Aurora PostgreSQL to Amazon OpenSearch

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Component Design](#3-component-design)
4. [Data Flow](#4-data-flow)
5. [Infrastructure Setup](#5-infrastructure-setup)
6. [Security Design](#6-security-design)
7. [Monitoring & Alerting](#7-monitoring--alerting)
8. [Disaster Recovery](#8-disaster-recovery)
9. [Performance Considerations](#9-performance-considerations)
10. [Cost Estimation](#10-cost-estimation)
11. [Implementation Plan](#11-implementation-plan)
12. [Appendix](#12-appendix)

---

## 1. Executive Summary

### 1.1 Purpose

This document provides the technical design for implementing a real-time Change Data Capture (CDC) pipeline from AWS Aurora PostgreSQL to Amazon OpenSearch Service using native AWS services.

### 1.2 Scope

The design covers the end-to-end architecture for capturing INSERT, UPDATE, and DELETE operations from Aurora PostgreSQL and synchronizing them to OpenSearch indices in near real-time.

### 1.3 Goals

- Enable near real-time search capabilities on transactional data
- Achieve sub-second to seconds latency for CDC event propagation
- Ensure data consistency between source and target
- Minimize operational overhead using fully managed AWS services
- Support horizontal scaling for high-throughput workloads

### 1.4 Non-Goals

- Historical data migration (covered in separate migration plan)
- Schema evolution automation
- Multi-region active-active replication

---

## 2. Architecture Overview

### 2.1 High-Level Architecture

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Cloud (VPC)                                   │
│                                                                                │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   Aurora     │    │     AWS      │    │   Kinesis    │    │    Lambda    │  │
│  │  PostgreSQL  │───▶│     DMS      │───▶│    Data      │───▶│   Function   │  │
│  │   Cluster    │    │  (CDC Mode)  │    │   Streams    │    │  (Processor) │  │
│  └──────────────┘    └──────────────┘    └──────────────┘    └──────┬───────┘  │
│         │                                                           │          │
│         │                                                           ▼          │
│         │                                       ┌──────────────────────────┐   │
│         │                                       │    Amazon OpenSearch     │   │
│         │                                       │        Service           │   │
│         │                                       │  ┌────────────────────┐  │   │
│         │                                       │  │   Search Indices   │  │   │
│         │                                       │  └────────────────────┘  │   │
│         │                                       └──────────────────────────┘   │
│         │                                                                      │
│         │            ┌──────────────────────────────────────────────┐          │
│         └───────────▶│              Dead Letter Queue               │          │
│                      │                  (SQS)                       │          │
│                      └──────────────────────────────────────────────┘          │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Architecture Components

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| Source Database | Aurora PostgreSQL | Primary transactional database |
| CDC Engine | AWS Database Migration Service (DMS) | Capture database changes using logical replication |
| Stream Buffer | Amazon Kinesis Data Streams | Buffer and order CDC events |
| Event Processor | AWS Lambda | Transform and index events to OpenSearch |
| Search Engine | Amazon OpenSearch Service | Full-text search and analytics |
| Dead Letter Queue | Amazon SQS | Failed event handling |
| Monitoring | Amazon CloudWatch | Metrics, logs, and alerting |
| Secrets | AWS Secrets Manager | Credential management |

### 2.3 Architecture Decision Records (ADR)

#### ADR-001: DMS over Debezium

**Decision:** Use AWS DMS instead of self-managed Debezium on ECS/EKS.

**Rationale:**
- Fully managed service reduces operational overhead
- Native integration with AWS services
- Built-in monitoring and auto-recovery
- No need to manage Kafka/MSK infrastructure

**Trade-offs:**
- Less transformation flexibility compared to Kafka Connect SMTs
- Slightly higher latency than a direct Debezium setup

#### ADR-002: Kinesis over Direct OpenSearch

**Decision:** Use Kinesis Data Streams as an intermediate buffer.

**Rationale:**
- Decouples ingestion from processing
- Provides replay capability for failed events
- Handles backpressure during OpenSearch slowdowns
- Enables fan-out to multiple consumers if needed

#### ADR-003: Lambda over Kinesis Firehose

**Decision:** Use Lambda for processing instead of Kinesis Firehose to OpenSearch.

**Rationale:**
- Full control over document transformation
- Custom error handling and retry logic
- Support for DELETE operations (Firehose only supports upserts)
- Complex routing logic based on table/operation type

---

## 3. Component Design

### 3.1 Aurora PostgreSQL Configuration

#### 3.1.1 Parameter Group Settings

Create a custom DB Cluster Parameter Group with the following settings:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `rds.logical_replication` | `1` | Enable logical replication (requires reboot) |
| `max_replication_slots` | `10` | Maximum replication slots |
| `max_wal_senders` | `10` | Maximum WAL sender processes |
| `wal_sender_timeout` | `30000` | Timeout in milliseconds |

#### 3.1.2 Database Setup

```sql
-- Create dedicated CDC user
CREATE USER dms_user WITH LOGIN PASSWORD 'STORED_IN_SECRETS_MANAGER';

-- Grant replication privileges
GRANT rds_replication TO dms_user;

-- Grant read access to tables
GRANT USAGE ON SCHEMA public TO dms_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dms_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dms_user;

-- Create publication for CDC (PostgreSQL 10+)
CREATE PUBLICATION dms_publication FOR ALL TABLES;

-- Or for specific tables only:
-- CREATE PUBLICATION dms_publication FOR TABLE 
--     public.orders, 
--     public.customers, 
--     public.products;
```

#### 3.1.3 Table Requirements

Tables must have primary keys for CDC to work correctly:

```sql
-- Verify all tables have primary keys
SELECT 
    t.table_schema,
    t.table_name
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints tc 
    ON t.table_schema = tc.table_schema 
    AND t.table_name = tc.table_name 
    AND tc.constraint_type = 'PRIMARY KEY'
WHERE t.table_schema = 'public'
    AND t.table_type = 'BASE TABLE'
    AND tc.constraint_name IS NULL;
```

### 3.2 AWS DMS Configuration

#### 3.2.1 Replication Instance

| Setting | Value | Justification |
|---------|-------|---------------|
| Instance Class | `dms.r5.large` | Baseline for moderate throughput |
| Allocated Storage | 100 GB | Buffer for WAL processing |
| Multi-AZ | Yes | High availability for production |
| VPC | Same as Aurora | Minimize network latency |

#### 3.2.2 Source Endpoint Configuration

```json
{
  "EndpointIdentifier": "aurora-postgresql-source",
  "EndpointType": "source",
  "EngineName": "aurora-postgresql",
  "ServerName": "${aurora_cluster_endpoint}",
  "Port": 5432,
  "DatabaseName": "${database_name}",
  "Username": "dms_user",
  "Password": "${secrets_manager_reference}",
  "SslMode": "require",
  "ExtraConnectionAttributes": "PluginName=pgoutput;captureDDLs=N"
}
```

#### 3.2.3 Target Endpoint Configuration (Kinesis)

```json
{
  "EndpointIdentifier": "kinesis-target",
  "EndpointType": "target",
  "EngineName": "kinesis",
  "KinesisSettings": {
    "StreamArn": "arn:aws:kinesis:${region}:${account}:stream/cdc-stream",
    "MessageFormat": "json-unformatted",
    "IncludeTransactionDetails": false,
    "IncludePartitionValue": true,
    "PartitionIncludeSchemaTable": true,
    "IncludeTableAlterOperations": false,
    "IncludeControlDetails": false,
    "IncludeNullAndEmpty": true,
    "ServiceAccessRoleArn": "arn:aws:iam::${account}:role/dms-kinesis-role"
  }
}
```

#### 3.2.4 Replication Task Configuration

```json
{
  "ReplicationTaskIdentifier": "aurora-to-kinesis-cdc",
  "SourceEndpointArn": "${source_endpoint_arn}",
  "TargetEndpointArn": "${target_endpoint_arn}",
  "ReplicationInstanceArn": "${replication_instance_arn}",
  "MigrationType": "cdc",
  "TableMappings": {
    "rules": [
      {
        "rule-type": "selection",
        "rule-id": "1",
        "rule-name": "include-all-tables",
        "object-locator": {
          "schema-name": "public",
          "table-name": "%"
        },
        "rule-action": "include"
      },
      {
        "rule-type": "selection",
        "rule-id": "2",
        "rule-name": "exclude-audit-tables",
        "object-locator": {
          "schema-name": "public",
          "table-name": "audit_%"
        },
        "rule-action": "exclude"
      }
    ]
  },
  "ReplicationTaskSettings": {
    "TargetMetadata": {
      "ParallelLoadThreads": 4,
      "ParallelLoadBufferSize": 500
    },
    "FullLoadSettings": {
      "TargetTablePrepMode": "DO_NOTHING"
    },
    "Logging": {
      "EnableLogging": true,
      "LogComponents": [
        {"Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEFAULT"},
        {"Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT"}
      ]
    },
    "ChangeProcessingTuning": {
      "BatchApplyEnabled": true,
      "BatchApplyPreserveTransaction": true,
      "BatchSplitSize": 0,
      "MinTransactionSize": 1000,
      "CommitTimeout": 1,
      "MemoryLimitTotal": 1024,
      "MemoryKeepTime": 60,
      "StatementCacheSize": 50
    },
    "StreamBufferSettings": {
      "StreamBufferCount": 3,
      "StreamBufferSizeInMB": 8
    }
  }
}
```

### 3.3 Kinesis Data Streams Configuration

#### 3.3.1 Stream Settings

| Setting | Value | Justification |
|---------|-------|---------------|
| Stream Name | `cdc-stream` | Descriptive name |
| Capacity Mode | On-Demand | Auto-scaling based on throughput |
| Data Retention | 24 hours | Balance between replay capability and cost |
| Encryption | AWS managed key | Server-side encryption |

#### 3.3.2 Partition Key Strategy

DMS partitions records by `schema.table` when `PartitionIncludeSchemaTable` is enabled. This ensures:
- Records for the same table go to the same shard
- Ordering is preserved per table
- Even distribution across shards for multi-table workloads

### 3.4 Lambda Function Design

#### 3.4.1 Function Configuration

| Setting | Value |
|---------|-------|
| Runtime | Java 17 (Corretto) |
| Memory | 1024 MB |
| Timeout | 60 seconds |
| Reserved Concurrency | 10 |
| Batch Size | 100 records |
| Batch Window | 5 seconds |
| Parallelization Factor | 2 |

#### 3.4.2 Lambda Function Code

```java
package com.example.cdc;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.KinesisEvent;
import com.google.gson.Gson;
import com.google.gson.JsonObject;
import org.apache.http.HttpHost;
import org.opensearch.action.bulk.BulkRequest;
import org.opensearch.action.bulk.BulkResponse;
import org.opensearch.action.delete.DeleteRequest;
import org.opensearch.action.index.IndexRequest;
import org.opensearch.client.RequestOptions;
import org.opensearch.client.RestClient;
import org.opensearch.client.RestHighLevelClient;
import org.opensearch.common.xcontent.XContentType;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.signer.Aws4Signer;
import org.opensearch.client.RestClientBuilder;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

public class CdcProcessor implements RequestHandler<KinesisEvent, Void> {

    private static final Gson gson = new Gson();
    private static final String OPENSEARCH_ENDPOINT = System.getenv("OPENSEARCH_ENDPOINT");
    private static final String AWS_REGION = System.getenv("AWS_REGION");
    
    private final RestHighLevelClient openSearchClient;

    public CdcProcessor() {
        this.openSearchClient = createOpenSearchClient();
    }

    @Override
    public Void handleRequest(KinesisEvent event, Context context) {
        BulkRequest bulkRequest = new BulkRequest();
        
        for (KinesisEvent.KinesisEventRecord record : event.getRecords()) {
            try {
                String payload = new String(
                    record.getKinesis().getData().array(), 
                    StandardCharsets.UTF_8
                );
                
                JsonObject cdcEvent = gson.fromJson(payload, JsonObject.class);
                processEvent(cdcEvent, bulkRequest);
                
            } catch (Exception e) {
                context.getLogger().log("Error processing record: " + e.getMessage());
                // Send to DLQ for retry
                sendToDeadLetterQueue(record, e);
            }
        }

        if (bulkRequest.numberOfActions() > 0) {
            try {
                BulkResponse response = openSearchClient.bulk(bulkRequest, RequestOptions.DEFAULT);
                if (response.hasFailures()) {
                    context.getLogger().log("Bulk indexing had failures: " + 
                        response.buildFailureMessage());
                }
            } catch (Exception e) {
                context.getLogger().log("OpenSearch bulk request failed: " + e.getMessage());
                throw new RuntimeException("Failed to index to OpenSearch", e);
            }
        }

        return null;
    }

    private void processEvent(JsonObject cdcEvent, BulkRequest bulkRequest) {
        // Extract metadata
        JsonObject metadata = cdcEvent.getAsJsonObject("metadata");
        String operation = metadata.get("operation").getAsString();
        String schemaName = metadata.get("schema-name").getAsString();
        String tableName = metadata.get("table-name").getAsString();
        
        // Build index name: schema_table (lowercase, replace dots)
        String indexName = (schemaName + "_" + tableName)
            .toLowerCase()
            .replace(".", "_");
        
        // Extract data
        JsonObject data = cdcEvent.getAsJsonObject("data");
        String documentId = extractPrimaryKey(data, tableName);

        switch (operation.toLowerCase()) {
            case "insert":
            case "update":
                IndexRequest indexRequest = new IndexRequest(indexName)
                    .id(documentId)
                    .source(data.toString(), XContentType.JSON);
                bulkRequest.add(indexRequest);
                break;
                
            case "delete":
                DeleteRequest deleteRequest = new DeleteRequest(indexName, documentId);
                bulkRequest.add(deleteRequest);
                break;
                
            default:
                // Log unknown operation type
                break;
        }
    }

    private String extractPrimaryKey(JsonObject data, String tableName) {
        // Default: assume 'id' column as primary key
        // Extend this logic for composite keys or table-specific configurations
        if (data.has("id")) {
            return data.get("id").toString();
        }
        
        // Fallback: use hash of all fields
        return String.valueOf(data.hashCode());
    }

    private RestHighLevelClient createOpenSearchClient() {
        // Create client with IAM authentication
        RestClientBuilder builder = RestClient.builder(
            new HttpHost(OPENSEARCH_ENDPOINT, 443, "https")
        );
        
        // Configure AWS Signature V4 signing
        builder.setHttpClientConfigCallback(httpClientBuilder -> {
            httpClientBuilder.addInterceptorLast(
                new AwsRequestSigningApacheInterceptor(
                    "es",
                    Aws4Signer.create(),
                    DefaultCredentialsProvider.create(),
                    AWS_REGION
                )
            );
            return httpClientBuilder;
        });

        return new RestHighLevelClient(builder);
    }

    private void sendToDeadLetterQueue(KinesisEvent.KinesisEventRecord record, Exception e) {
        // Implementation: Send failed record to SQS DLQ
        // Include original record, error message, timestamp, retry count
    }
}
```

#### 3.4.3 Gradle Dependencies

```groovy
dependencies {
    implementation 'com.amazonaws:aws-lambda-java-core:1.2.3'
    implementation 'com.amazonaws:aws-lambda-java-events:3.11.4'
    implementation 'org.opensearch.client:opensearch-rest-high-level-client:2.11.1'
    implementation 'com.google.code.gson:gson:2.10.1'
    implementation 'software.amazon.awssdk:auth:2.21.0'
    implementation 'software.amazon.awssdk:sqs:2.21.0'
}
```

### 3.5 OpenSearch Configuration

#### 3.5.1 Domain Settings

| Setting | Value |
|---------|-------|
| Domain Name | `cdc-search-domain` |
| Engine Version | OpenSearch 2.11 |
| Instance Type | `r6g.large.search` |
| Instance Count | 3 (across 3 AZs) |
| Dedicated Master | Yes (3x `m6g.large.search`) |
| Storage | 500 GB gp3 per node |
| Encryption | At-rest and in-transit |

#### 3.5.2 Index Template

```json
PUT _index_template/cdc-template
{
  "index_patterns": ["public_*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "1s",
      "index.mapping.total_fields.limit": 2000,
      "analysis": {
        "analyzer": {
          "default": {
            "type": "standard"
          }
        }
      }
    },
    "mappings": {
      "dynamic": "true",
      "dynamic_templates": [
        {
          "strings_as_keywords": {
            "match_mapping_type": "string",
            "mapping": {
              "type": "keyword",
              "ignore_above": 256,
              "fields": {
                "text": {
                  "type": "text"
                }
              }
            }
          }
        },
        {
          "dates": {
            "match": "*_at",
            "mapping": {
              "type": "date",
              "format": "strict_date_optional_time||epoch_millis"
            }
          }
        }
      ],
      "properties": {
        "id": { "type": "keyword" },
        "created_at": { "type": "date" },
        "updated_at": { "type": "date" }
      }
    }
  }
}
```

#### 3.5.3 Index Lifecycle Policy

```json
PUT _plugins/_ism/policies/cdc-lifecycle
{
  "policy": {
    "description": "CDC index lifecycle management",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          {
            "rollover": {
              "min_size": "50gb",
              "min_index_age": "7d"
            }
          }
        ],
        "transitions": [
          {
            "state_name": "warm",
            "conditions": {
              "min_index_age": "30d"
            }
          }
        ]
      },
      {
        "name": "warm",
        "actions": [
          {
            "replica_count": {
              "number_of_replicas": 0
            }
          }
        ],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": {
              "min_index_age": "90d"
            }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [
          {
            "delete": {}
          }
        ]
      }
    ]
  }
}
```

---

## 4. Data Flow

### 4.1 CDC Event Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CDC Event Flow                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Transaction Commit                                                      │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ INSERT INTO orders (id, customer_id, amount, status)    │             │
│     │ VALUES (123, 456, 99.99, 'pending');                    │             │
│     │ COMMIT;                                                 │             │
│     └─────────────────────────────────────────────────────────┘             │
│                              │                                              │
│                              ▼                                              │
│  2. WAL Capture (PostgreSQL)                                                │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ LSN: 0/1234567                                          │             │
│     │ Transaction: INSERT on public.orders                    │             │
│     └─────────────────────────────────────────────────────────┘             │
│                              │                                              │
│                              ▼                                              │
│  3. DMS Capture & Transform                                                 │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ {                                                       │             │
│     │   "metadata": {                                         │             │
│     │     "operation": "insert",                              │             │
│     │     "schema-name": "public",                            │             │
│     │     "table-name": "orders",                             │             │
│     │     "timestamp": "2024-12-01T10:30:00Z"                 │             │
│     │   },                                                    │             │
│     │   "data": {                                             │             │
│     │     "id": 123,                                          │             │
│     │     "customer_id": 456,                                 │             │
│     │     "amount": 99.99,                                    │             │
│     │     "status": "pending"                                 │             │
│     │   }                                                     │             │
│     │ }                                                       │             │
│     └─────────────────────────────────────────────────────────┘             │
│                              │                                              │
│                              ▼                                              │
│  4. Kinesis Stream (Partition: public.orders)                               │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ Shard-001: [event1, event2, event3, ...]                │             │
│     └─────────────────────────────────────────────────────────┘             │
│                              │                                              │
│                              ▼                                              │
│  5. Lambda Processing                                                       │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ - Parse CDC event                                       │             │
│     │ - Determine operation type                              │             │
│     │ - Extract document ID (primary key)                     │             │
│     │ - Build OpenSearch request                              │             │
│     └─────────────────────────────────────────────────────────┘             │
│                              │                                              │
│                              ▼                                              │
│  6. OpenSearch Index                                                        │
│     ┌─────────────────────────────────────────────────────────┐             │
│     │ Index: public_orders                                    │             │
│     │ Document ID: 123                                        │             │
│     │ Action: INDEX (upsert)                                  │             │
│     └─────────────────────────────────────────────────────────┘             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Operation Mapping

| PostgreSQL Operation | DMS Operation | OpenSearch Action | Result |
|---------------------|---------------|-------------------|--------|
| `INSERT` | `insert` | `IndexRequest` | New document created |
| `UPDATE` | `update` | `IndexRequest` | Document replaced (full document) |
| `DELETE` | `delete` | `DeleteRequest` | Document removed |

### 4.3 Data Transformation Rules

| Source Type (PostgreSQL) | Target Type (OpenSearch) | Notes |
|-------------------------|-------------------------|-------|
| `INTEGER`, `BIGINT` | `long` | Direct mapping |
| `NUMERIC`, `DECIMAL` | `double` | Precision may be lost |
| `VARCHAR`, `TEXT` | `keyword` + `text` | Multi-field mapping |
| `BOOLEAN` | `boolean` | Direct mapping |
| `TIMESTAMP` | `date` | ISO 8601 format |
| `JSONB` | `object` | Nested object |
| `UUID` | `keyword` | String representation |
| `ARRAY` | `array` | Preserve array structure |

---

## 5. Infrastructure Setup

### 5.1 Terraform Configuration

#### 5.1.1 Provider and Variables

```hcl
# providers.tf
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# variables.tf
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs"
  type        = list(string)
}

variable "aurora_cluster_endpoint" {
  description = "Aurora cluster endpoint"
  type        = string
}

variable "database_name" {
  description = "Database name"
  type        = string
}
```

#### 5.1.2 Kinesis Data Stream

```hcl
# kinesis.tf
resource "aws_kinesis_stream" "cdc_stream" {
  name             = "cdc-stream-${var.environment}"
  shard_count      = null
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.cdc_key.id

  tags = {
    Environment = var.environment
    Purpose     = "CDC Pipeline"
  }
}
```

#### 5.1.3 DMS Resources

```hcl
# dms.tf
resource "aws_dms_replication_subnet_group" "cdc" {
  replication_subnet_group_id          = "cdc-subnet-group-${var.environment}"
  replication_subnet_group_description = "CDC replication subnet group"
  subnet_ids                           = var.private_subnet_ids
}

resource "aws_dms_replication_instance" "cdc" {
  replication_instance_id     = "cdc-instance-${var.environment}"
  replication_instance_class  = "dms.r5.large"
  allocated_storage          = 100
  multi_az                   = true
  publicly_accessible        = false
  replication_subnet_group_id = aws_dms_replication_subnet_group.cdc.id
  vpc_security_group_ids     = [aws_security_group.dms.id]

  tags = {
    Environment = var.environment
  }
}

resource "aws_dms_endpoint" "source" {
  endpoint_id   = "aurora-source-${var.environment}"
  endpoint_type = "source"
  engine_name   = "aurora-postgresql"
  server_name   = var.aurora_cluster_endpoint
  port          = 5432
  database_name = var.database_name
  username      = "dms_user"
  password      = data.aws_secretsmanager_secret_version.dms_password.secret_string
  ssl_mode      = "require"

  extra_connection_attributes = "PluginName=pgoutput"
}

resource "aws_dms_endpoint" "target" {
  endpoint_id   = "kinesis-target-${var.environment}"
  endpoint_type = "target"
  engine_name   = "kinesis"

  kinesis_settings {
    stream_arn                    = aws_kinesis_stream.cdc_stream.arn
    message_format               = "json-unformatted"
    include_partition_value      = true
    partition_include_schema_table = true
    service_access_role_arn      = aws_iam_role.dms_kinesis.arn
  }
}

resource "aws_dms_replication_task" "cdc" {
  replication_task_id       = "aurora-kinesis-cdc-${var.environment}"
  migration_type           = "cdc"
  replication_instance_arn = aws_dms_replication_instance.cdc.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target.endpoint_arn

  table_mappings = jsonencode({
    rules = [
      {
        rule-type = "selection"
        rule-id   = "1"
        rule-name = "include-all"
        object-locator = {
          schema-name = "public"
          table-name  = "%"
        }
        rule-action = "include"
      }
    ]
  })

  replication_task_settings = jsonencode({
    TargetMetadata = {
      ParallelLoadThreads = 4
    }
    Logging = {
      EnableLogging = true
    }
    ChangeProcessingTuning = {
      BatchApplyEnabled = true
      CommitTimeout     = 1
    }
  })

  start_replication_task = true
}
```

#### 5.1.4 Lambda Function

```hcl
# lambda.tf
resource "aws_lambda_function" "cdc_processor" {
  function_name = "cdc-processor-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "com.example.cdc.CdcProcessor::handleRequest"
  runtime       = "java17"
  timeout       = 60
  memory_size   = 1024

  filename         = "cdc-processor.jar"
  source_code_hash = filebase64sha256("cdc-processor.jar")

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearch_domain.cdc.endpoint
      AWS_REGION         = var.aws_region
      DLQ_URL            = aws_sqs_queue.dlq.url
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  reserved_concurrent_executions = 10

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_event_source_mapping" "kinesis" {
  event_source_arn                   = aws_kinesis_stream.cdc_stream.arn
  function_name                      = aws_lambda_function.cdc_processor.arn
  starting_position                  = "LATEST"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  parallelization_factor             = 2

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn
    }
  }
}
```

#### 5.1.5 OpenSearch Domain

```hcl
# opensearch.tf
resource "aws_opensearch_domain" "cdc" {
  domain_name    = "cdc-search-${var.environment}"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type            = "r6g.large.search"
    instance_count           = 3
    zone_awareness_enabled   = true
    dedicated_master_enabled = true
    dedicated_master_type    = "m6g.large.search"
    dedicated_master_count   = 3

    zone_awareness_config {
      availability_zone_count = 3
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 500
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.cdc_key.arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  vpc_options {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.opensearch.id]
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false
    master_user_options {
      master_user_arn = aws_iam_role.opensearch_master.arn
    }
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_role.arn
        }
        Action   = "es:*"
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/cdc-search-${var.environment}/*"
      }
    ]
  })

  tags = {
    Environment = var.environment
  }
}
```

### 5.2 Network Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                                    VPC                                     │
│                                                                            │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │                        Private Subnets                             │    │
│  │                                                                    │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │    │
│  │  │  AZ-1       │  │  AZ-2       │  │  AZ-3       │                 │    │
│  │  │             │  │             │  │             │                 │    │
│  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │                 │    │
│  │  │ │ Aurora  │ │  │ │ Aurora  │ │  │ │ Aurora  │ │                 │    │
│  │  │ │ (Writer)│ │  │ │(Reader) │ │  │ │(Reader) │ │                 │    │
│  │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │                 │    │
│  │  │             │  │             │  │             │                 │    │
│  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │             │                 │    │
│  │  │ │   DMS   │ │  │ │   DMS   │ │  │             │                 │    │
│  │  │ │(Primary)│ │  │ │(Standby)│ │  │             │                 │    │
│  │  │ └─────────┘ │  │ └─────────┘ │  │             │                 │    │
│  │  │             │  │             │  │             │                 │    │
│  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │                 │    │
│  │  │ │OpenSearch│ │ │ │OpenSearch│ │ │ │OpenSearch││                 │    │
│  │  │ │  Node   │ │  │ │  Node   │ │  │ │  Node   │ │                 │    │
│  │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │                 │    │
│  │  │             │  │             │  │             │                 │    │
│  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │                 │    │
│  │  │ │ Lambda  │ │  │ │ Lambda  │ │  │ │ Lambda  │ │                 │    │
│  │  │ │  (ENI)  │ │  │ │  (ENI)  │ │  │ │  (ENI)  │ │                 │    │
│  │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │                 │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                 │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        VPC Endpoints                                │   │
│  │  • Kinesis (Interface)    • Secrets Manager (Interface)             │   │
│  │  • SQS (Interface)        • CloudWatch (Interface)                  │   │
│  │  • S3 (Gateway)                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Security Design

### 6.1 IAM Roles and Policies

#### 6.1.1 DMS Role for Kinesis Access

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesis:PutRecord",
        "kinesis:PutRecords",
        "kinesis:DescribeStream"
      ],
      "Resource": "arn:aws:kinesis:*:*:stream/cdc-stream-*"
    }
  ]
}
```

#### 6.1.2 Lambda Execution Role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesis:GetRecords",
        "kinesis:GetShardIterator",
        "kinesis:DescribeStream",
        "kinesis:DescribeStreamSummary",
        "kinesis:ListShards"
      ],
      "Resource": "arn:aws:kinesis:*:*:stream/cdc-stream-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "es:ESHttp*"
      ],
      "Resource": "arn:aws:es:*:*:domain/cdc-search-*/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage"
      ],
      "Resource": "arn:aws:sqs:*:*:cdc-dlq-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

### 6.2 Encryption

| Component | Encryption Type | Key Management |
|-----------|-----------------|----------------|
| Aurora PostgreSQL | At-rest (AES-256) | AWS KMS (CMK) |
| Kinesis Data Streams | Server-side | AWS KMS (CMK) |
| OpenSearch | At-rest + In-transit | AWS KMS (CMK) + TLS 1.2 |
| Secrets Manager | At-rest | AWS KMS |
| Lambda Environment | At-rest | AWS KMS |

### 6.3 Network Security

#### 6.3.1 Security Groups

**DMS Security Group:**
```hcl
ingress = []  # No inbound required

egress = [
  { from_port = 5432, to_port = 5432, protocol = "tcp", cidr_blocks = [aurora_subnet_cidrs] },
  { from_port = 443, to_port = 443, protocol = "tcp", prefix_list_ids = [kinesis_prefix_list] }
]
```

**Lambda Security Group:**
```hcl
ingress = []  # No inbound required

egress = [
  { from_port = 443, to_port = 443, protocol = "tcp", security_groups = [opensearch_sg] },
  { from_port = 443, to_port = 443, protocol = "tcp", prefix_list_ids = [sqs_prefix_list] }
]
```

**OpenSearch Security Group:**
```hcl
ingress = [
  { from_port = 443, to_port = 443, protocol = "tcp", security_groups = [lambda_sg] }
]

egress = []  # No outbound required
```

### 6.4 Secrets Management

```hcl
resource "aws_secretsmanager_secret" "dms_credentials" {
  name = "cdc/dms/aurora-credentials"
  
  tags = {
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "dms_credentials" {
  secret_id = aws_secretsmanager_secret.dms_credentials.id
  secret_string = jsonencode({
    username = "dms_user"
    password = random_password.dms.result
  })
}
```

---

## 7. Monitoring & Alerting

### 7.1 Key Metrics

| Component | Metric | Threshold | Severity |
|-----------|--------|-----------|----------|
| DMS | `CDCLatencySource` | > 60 seconds | Critical |
| DMS | `CDCLatencyTarget` | > 30 seconds | Warning |
| DMS | `CDCChangesDiskSource` | > 10 GB | Warning |
| Kinesis | `GetRecords.IteratorAgeMilliseconds` | > 60000 ms | Critical |
| Kinesis | `WriteProvisionedThroughputExceeded` | > 0 | Critical |
| Lambda | `Errors` | > 10/min | Critical |
| Lambda | `Duration` | > 50000 ms | Warning |
| Lambda | `ConcurrentExecutions` | > 8 | Warning |
| OpenSearch | `ClusterStatus.red` | = 1 | Critical |
| OpenSearch | `FreeStorageSpace` | < 20 GB | Warning |
| OpenSearch | `CPUUtilization` | > 80% | Warning |
| SQS (DLQ) | `ApproximateNumberOfMessagesVisible` | > 0 | Warning |

### 7.2 CloudWatch Dashboard

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "title": "CDC Pipeline Health",
        "metrics": [
          ["AWS/DMS", "CDCLatencySource", "ReplicationInstanceIdentifier", "cdc-instance"],
          ["AWS/DMS", "CDCLatencyTarget", "ReplicationInstanceIdentifier", "cdc-instance"]
        ],
        "period": 60,
        "stat": "Average"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "Kinesis Stream Lag",
        "metrics": [
          ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds", "StreamName", "cdc-stream"]
        ],
        "period": 60,
        "stat": "Maximum"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "Lambda Processing",
        "metrics": [
          ["AWS/Lambda", "Invocations", "FunctionName", "cdc-processor"],
          ["AWS/Lambda", "Errors", "FunctionName", "cdc-processor"],
          ["AWS/Lambda", "Duration", "FunctionName", "cdc-processor"]
        ],
        "period": 60,
        "stat": "Sum"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "OpenSearch Indexing",
        "metrics": [
          ["AWS/ES", "IndexingRate", "DomainName", "cdc-search"],
          ["AWS/ES", "SearchRate", "DomainName", "cdc-search"]
        ],
        "period": 60,
        "stat": "Average"
      }
    }
  ]
}
```

### 7.3 Alerting Configuration

```hcl
resource "aws_cloudwatch_metric_alarm" "cdc_latency" {
  alarm_name          = "cdc-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CDCLatencySource"
  namespace           = "AWS/DMS"
  period              = 60
  statistic           = "Average"
  threshold           = 60
  alarm_description   = "CDC source latency exceeds 60 seconds"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ReplicationInstanceIdentifier = aws_dms_replication_instance.cdc.replication_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "cdc-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "CDC Dead Letter Queue has messages"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}
```

---

## 8. Disaster Recovery

### 8.1 Recovery Objectives

| Objective | Target | Justification |
|-----------|--------|---------------|
| RTO (Recovery Time Objective) | 15 minutes | Time to failover DMS and resume CDC |
| RPO (Recovery Point Objective) | 1 minute | Kinesis retention + checkpoint recovery |

### 8.2 Failure Scenarios

#### 8.2.1 DMS Replication Instance Failure

**Detection:** CloudWatch alarm on `ReplicationInstanceStatus`

**Recovery:**
1. DMS Multi-AZ automatically fails over (< 5 minutes)
2. Replication task resumes from last checkpoint
3. No data loss due to PostgreSQL WAL retention

#### 8.2.2 Lambda Processing Failure

**Detection:** CloudWatch alarm on Lambda `Errors` metric

**Recovery:**
1. Failed records sent to DLQ
2. Kinesis iterator advances to next batch
3. DLQ processor retries failed records
4. Manual intervention for persistent failures

#### 8.2.3 OpenSearch Cluster Failure

**Detection:** CloudWatch alarm on `ClusterStatus.red`

**Recovery:**
1. OpenSearch Multi-AZ provides automatic recovery
2. Kinesis retains data during outage (24 hours)
3. Lambda retries with exponential backoff
4. After recovery, backlog is processed automatically

### 8.3 Backup Strategy

| Component | Backup Method | Retention | Recovery Method |
|-----------|---------------|-----------|-----------------|
| Aurora PostgreSQL | Automated snapshots + PITR | 35 days | Restore to point in time |
| OpenSearch | Automated snapshots | 14 snapshots | Restore from snapshot |
| Lambda Code | S3 versioning | Unlimited | Redeploy from S3 |
| Terraform State | S3 + DynamoDB locking | Versioned | Restore from version |

### 8.4 Runbook: Full Pipeline Recovery

```
1. ASSESS IMPACT
   □ Check DMS replication task status
   □ Check Kinesis stream metrics
   □ Check Lambda error rates
   □ Check OpenSearch cluster health
   □ Check DLQ depth

2. IDENTIFY ROOT CAUSE
   □ Review CloudWatch logs
   □ Check recent deployments
   □ Verify network connectivity
   □ Check IAM permissions

3. RECOVER COMPONENTS (in order)
   a. Aurora PostgreSQL
      □ Verify replication slot exists: SELECT * FROM pg_replication_slots;
      □ Check WAL retention: SELECT pg_current_wal_lsn();
   
   b. DMS
      □ If stopped: aws dms start-replication-task --start-replication-task-type resume-processing
      □ If corrupted: Recreate task with start-position
   
   c. Kinesis
      □ Verify stream is active
      □ Check enhanced monitoring for hot shards
   
   d. Lambda
      □ Check reserved concurrency
      □ Review timeout settings
      □ Process DLQ messages
   
   e. OpenSearch
      □ Check cluster health: GET /_cluster/health
      □ Verify index mappings exist
      □ Force merge if needed: POST /<index>/_forcemerge

4. VERIFY RECOVERY
   □ Insert test record in source
   □ Verify appears in OpenSearch within SLA
   □ Check end-to-end latency metrics

5. POST-INCIDENT
   □ Document timeline
   □ Update runbooks
   □ Create preventive measures
```

---

## 9. Performance Considerations

### 9.1 Throughput Estimates

| Metric | Estimate | Notes |
|--------|----------|-------|
| Peak transactions/sec | 1,000 TPS | Based on Aurora capacity |
| Average event size | 1 KB | Typical row with 20 columns |
| Peak throughput | 1 MB/s | 1000 TPS × 1 KB |
| Kinesis capacity | 4 MB/s | On-demand auto-scales |
| Lambda concurrency | 10 | Reserved for consistent performance |
| OpenSearch indexing | 5,000 docs/sec | 3-node cluster capacity |

### 9.2 Latency Breakdown

| Stage | Expected Latency | Notes |
|-------|------------------|-------|
| PostgreSQL → DMS | 100-500 ms | Logical replication delay |
| DMS → Kinesis | 100-200 ms | Batch write latency |
| Kinesis → Lambda | 200-500 ms | Batch window + polling |
| Lambda → OpenSearch | 50-100 ms | Bulk indexing |
| **Total End-to-End** | **500 ms - 1.5 s** | Under normal conditions |

### 9.3 Optimization Strategies

#### 9.3.1 DMS Tuning

```json
{
  "ChangeProcessingTuning": {
    "BatchApplyEnabled": true,
    "BatchApplyPreserveTransaction": false,
    "BatchSplitSize": 0,
    "MinTransactionSize": 10000,
    "CommitTimeout": 1
  }
}
```

#### 9.3.2 Lambda Tuning

- **Memory:** 1024 MB provides 1 vCPU, optimal for I/O-bound operations
- **Batch Size:** 100 records balances latency vs. efficiency
- **Parallelization Factor:** 2 allows concurrent shard processing
- **Connection Pooling:** Reuse OpenSearch client across invocations

#### 9.3.3 OpenSearch Tuning

```json
{
  "index.refresh_interval": "1s",
  "index.number_of_replicas": 1,
  "index.translog.durability": "async",
  "index.translog.sync_interval": "5s"
}
```

---

## 10. Cost Estimation

### 10.1 Monthly Cost Breakdown

| Component | Configuration | Monthly Cost (USD) |
|-----------|---------------|-------------------|
| Aurora PostgreSQL | db.r6g.xlarge (Multi-AZ) | ~$700 |
| DMS Replication Instance | dms.r5.large (Multi-AZ) | ~$350 |
| Kinesis Data Streams | On-demand, ~1 TB/month | ~$40 |
| Lambda | 10M invocations, 1024 MB, 500 ms | ~$25 |
| OpenSearch | 3x r6g.large.search, 1.5 TB | ~$1,200 |
| Data Transfer | ~500 GB inter-AZ | ~$10 |
| CloudWatch | Logs, metrics, alarms | ~$50 |
| Secrets Manager | 2 secrets | ~$1 |
| **Total Estimated** | | **~$2,376/month** |

### 10.2 Cost Optimization Opportunities

1. **Reserved Instances:** 1-year commitment saves ~40% on Aurora and OpenSearch
2. **Kinesis Provisioned:** If throughput is predictable, provisioned mode may be cheaper
3. **OpenSearch UltraWarm:** Move older indices to warm storage (70% cost reduction)
4. **Lambda ARM64:** Use Graviton2 for 20% cost reduction

---

## 11. Implementation Plan

### 11.1 Phase 1: Foundation (Week 1-2)

| Task | Owner | Duration |
|------|-------|----------|
| Create Terraform modules | DevOps | 3 days |
| Configure Aurora parameter group | DBA | 1 day |
| Set up VPC endpoints | Network | 1 day |
| Create IAM roles and policies | Security | 2 days |
| Set up Secrets Manager | Security | 1 day |
| Deploy to Dev environment | DevOps | 2 days |

### 11.2 Phase 2: Core Pipeline (Week 3-4)

| Task | Owner | Duration |
|------|-------|----------|
| Deploy Kinesis stream | DevOps | 1 day |
| Configure DMS endpoints | DBA | 2 days |
| Create replication task | DBA | 1 day |
| Develop Lambda function | Backend | 5 days |
| Deploy OpenSearch domain | DevOps | 2 days |
| Create index templates | Backend | 1 day |

### 11.3 Phase 3: Testing (Week 5-6)

| Task | Owner | Duration |
|------|-------|----------|
| Unit testing Lambda | Backend | 2 days |
| Integration testing | QA | 3 days |
| Performance testing | QA | 3 days |
| Failover testing | DevOps | 2 days |
| Security review | Security | 2 days |

### 11.4 Phase 4: Production (Week 7-8)

| Task | Owner | Duration |
|------|-------|----------|
| Deploy to Staging | DevOps | 2 days |
| UAT testing | QA/Business | 3 days |
| Production deployment | DevOps | 2 days |
| Monitoring setup | DevOps | 2 days |
| Documentation | All | 3 days |
| Runbook creation | DevOps | 2 days |

### 11.5 Go-Live Checklist

```
PRE-DEPLOYMENT
□ All Terraform plans reviewed and approved
□ Security review completed
□ Performance testing passed
□ Runbooks documented
□ On-call rotation established
□ Rollback plan documented

DEPLOYMENT
□ Deploy infrastructure via Terraform
□ Configure Aurora replication
□ Start DMS replication task
□ Verify initial sync
□ Enable CloudWatch alarms
□ Verify end-to-end data flow

POST-DEPLOYMENT
□ Monitor latency metrics for 24 hours
□ Verify search functionality
□ Check for DLQ messages
□ Document any issues
□ Update capacity planning
```

---

## 12. Appendix

### 12.1 Glossary

| Term | Definition |
|------|------------|
| CDC | Change Data Capture - process of identifying and capturing changes made to data |
| WAL | Write-Ahead Log - PostgreSQL's transaction log |
| LSN | Log Sequence Number - unique identifier for WAL position |
| DMS | AWS Database Migration Service |
| DLQ | Dead Letter Queue - queue for failed messages |

### 12.2 References

- [AWS DMS Documentation](https://docs.aws.amazon.com/dms/)
- [Amazon Kinesis Data Streams](https://docs.aws.amazon.com/streams/)
- [Amazon OpenSearch Service](https://docs.aws.amazon.com/opensearch-service/)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)

### 12.3 DMS Event Message Format

```json
{
  "data": {
    "id": 123,
    "customer_id": 456,
    "amount": 99.99,
    "status": "pending",
    "created_at": "2024-12-01T10:30:00Z"
  },
  "metadata": {
    "timestamp": "2024-12-01T10:30:00.123456Z",
    "record-type": "data",
    "operation": "insert",
    "partition-key-type": "schema-table",
    "schema-name": "public",
    "table-name": "orders",
    "transaction-id": 12345678
  }
}
```

### 12.4 OpenSearch Query Examples

```json
// Search orders by customer
GET /public_orders/_search
{
  "query": {
    "term": { "customer_id": 456 }
  }
}

// Full-text search on product descriptions
GET /public_products/_search
{
  "query": {
    "match": { "description.text": "wireless bluetooth headphones" }
  }
}

// Aggregation: Orders by status
GET /public_orders/_search
{
  "size": 0,
  "aggs": {
    "by_status": {
      "terms": { "field": "status" }
    }
  }
}
```

---

**Document End**
