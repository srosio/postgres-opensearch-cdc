#!/bin/bash

# =====================================================
# Centralized Configuration for PostgreSQL-OpenSearch CDC
# =====================================================
# Source this file in all scripts: source ./config.sh

# PostgreSQL Configuration
export POSTGRES_CONTAINER="postgres_container"
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="root"
export POSTGRES_DATABASE="instance_template"
export POSTGRES_HOST="host.docker.internal"
export POSTGRES_PORT="5432"

# OpenSearch Configuration
export OPENSEARCH_HOST="localhost"
export OPENSEARCH_PORT="9200"
export OPENSEARCH_URL="http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}"

# Kafka Configuration
export KAFKA_CONTAINER="kafka"
export KAFKA_BOOTSTRAP_INTERNAL="kafka:9092"
export KAFKA_BOOTSTRAP_EXTERNAL="localhost:29092"
export ZOOKEEPER_CONTAINER="zookeeper"
export ZOOKEEPER_PORT="2181"

# Debezium Configuration
export DEBEZIUM_CONTAINER="debezium"
export DEBEZIUM_HOST="localhost"
export DEBEZIUM_PORT="8083"
export DEBEZIUM_URL="http://${DEBEZIUM_HOST}:${DEBEZIUM_PORT}"

# Kafka Connect Configuration
export KAFKA_CONNECT_HOST="localhost"
export KAFKA_CONNECT_PORT="8084"
export KAFKA_CONNECT_URL="http://${KAFKA_CONNECT_HOST}:${KAFKA_CONNECT_PORT}"

# Kafka UI Configuration
export KAFKA_UI_PORT="8080"
export KAFKA_UI_URL="http://localhost:${KAFKA_UI_PORT}"

# CDC Pipeline Configuration
export TOPIC_PREFIX="postgres"

# Table Configurations
# Original table
export TABLE_SAVINGS_TRANSACTION="m_savings_account_transaction"
export PUBLICATION_SAVINGS="instance_template_publication"
export SLOT_SAVINGS="instance_template_slot"
export CONNECTOR_SAVINGS="instance-template-source"

# Card tables
export TABLE_CARD="card"
export TABLE_AUTHORIZE_TX="authorize_transaction"
export TABLE_CARD_AUTH="card_authorization"
export PUBLICATION_CARDS="card_tables_publication"
export SLOT_CARDS="card_tables_slot"
export CONNECTOR_CARDS="card-tables-source"

# Python Consumer Configuration
export CONSUMER_GROUP_SINGLE="opensearch-consumer-group"
export CONSUMER_GROUP_MULTI="opensearch-multi-consumer-group"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_success() {
    echo -e "${GREEN}✓${NC}  $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

log_error() {
    echo -e "${RED}✗${NC}  $1"
}

# Check if required tools are installed
check_dependencies() {
    local missing_deps=()

    command -v docker >/dev/null 2>&1 || missing_deps+=("docker")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v python3 >/dev/null 2>&1 || missing_deps+=("python3")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    return 0
}

# Wait for service to be ready
wait_for_service() {
    local service_name=$1
    local check_command=$2
    local max_attempts=${3:-30}
    local attempt=1

    log_info "Waiting for $service_name to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            log_success "$service_name is ready"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done

    echo ""
    log_error "$service_name failed to become ready after $max_attempts attempts"
    return 1
}
