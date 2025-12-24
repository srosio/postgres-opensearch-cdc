#!/bin/bash

# =====================================================
# Create OpenSearch Indices for All Tables
# =====================================================

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

echo "=== Creating OpenSearch Indices ==="
echo ""

create_index() {
    local index_name=$1
    local mappings=$2

    log_info "Creating index: ${index_name}"

    if curl -s "${OPENSEARCH_URL}/${index_name}" | grep -q "\"${index_name}\""; then
        log_warning "Index '${index_name}' already exists, skipping"
        return 0
    fi

    curl -X PUT "${OPENSEARCH_URL}/${index_name}" \
      -H 'Content-Type: application/json' \
      -d "${mappings}"

    echo ""
    log_success "Index '${index_name}' created"
    echo ""
}

# =====================================================
# m_savings_account_transaction
# =====================================================

create_index "${TABLE_SAVINGS_TRANSACTION}" '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "5s"
  },
  "mappings": {
    "properties": {
      "id": {"type": "long"},
      "amount": {"type": "double"},
      "transaction_date": {"type": "date"},
      "savings_account_id": {"type": "long"},
      "office_id": {"type": "long"},
      "created_date": {"type": "date"},
      "running_balance_derived": {"type": "double"},
      "transaction_type_enum": {"type": "integer"},
      "is_reversed": {"type": "boolean"},
      "booking_date": {"type": "date"},
      "status_enum": {"type": "integer"},
      "is_runningbalance_derived": {"type": "boolean"},
      "is_interest_posted": {"type": "boolean"},
      "is_enriched": {"type": "boolean"}
    }
  }
}'

# =====================================================
# card
# =====================================================

create_index "${TABLE_CARD}" '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "5s"
  },
  "mappings": {
    "properties": {
      "id": {"type": "long"},
      "version": {"type": "short"},
      "savings_account_id": {"type": "long"},
      "credit_account_id": {"type": "long"},
      "product_id": {"type": "long"},
      "user_id": {"type": "long"},
      "primary_account_number": {"type": "keyword"},
      "card_number": {"type": "keyword"},
      "expires_on": {"type": "date"},
      "status": {"type": "keyword"},
      "sub_status": {"type": "keyword"},
      "fulfillment_status": {"type": "keyword"},
      "card_type": {"type": "keyword"},
      "card_network": {"type": "keyword"},
      "is_virtual": {"type": "boolean"},
      "digital_first": {"type": "boolean"},
      "prepaid_card": {"type": "boolean"},
      "online_payment_enabled": {"type": "boolean"},
      "pos_payment_enabled": {"type": "boolean"},
      "contactless_payment_enabled": {"type": "boolean"},
      "atm_withdrawals_enabled": {"type": "boolean"},
      "international_payments_enabled": {"type": "boolean"},
      "registered_on": {"type": "date"},
      "activated_at": {"type": "date"},
      "created_at": {"type": "date"},
      "updated_at": {"type": "date"},
      "token": {"type": "keyword"},
      "external_card_id": {"type": "keyword"},
      "embossed_name": {"type": "text"}
    }
  }
}'

# =====================================================
# authorize_transaction
# =====================================================

create_index "${TABLE_AUTHORIZE_TX}" '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "5s"
  },
  "mappings": {
    "properties": {
      "id": {"type": "long"},
      "version": {"type": "short"},
      "savings_account_id": {"type": "long"},
      "office_id": {"type": "long"},
      "transaction_date": {"type": "date"},
      "amount": {"type": "double"},
      "pending_amount": {"type": "double"},
      "created_at": {"type": "date"},
      "updated_at": {"type": "date"},
      "is_manual": {"type": "boolean"},
      "is_active": {"type": "boolean"},
      "card_authorization_id": {"type": "long"},
      "savings_account_transaction_id": {"type": "long"},
      "transfer_id": {"type": "long"},
      "initiated_by_client_id": {"type": "long"},
      "transaction_type": {"type": "keyword"},
      "reference": {"type": "keyword"}
    }
  }
}'

# =====================================================
# card_authorization
# =====================================================

create_index "${TABLE_CARD_AUTH}" '{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "5s"
  },
  "mappings": {
    "properties": {
      "id": {"type": "long"},
      "version": {"type": "integer"},
      "card_id": {"type": "long"},
      "authorize_transaction_id": {"type": "long"},
      "initiated_by_client_id": {"type": "long"},
      "auth_id": {"type": "keyword"},
      "external_auth_id": {"type": "keyword"},
      "auth_type": {"type": "keyword"},
      "transaction_type": {"type": "keyword"},
      "status": {"type": "keyword"},
      "card_network": {"type": "keyword"},
      "currency": {"type": "keyword"},
      "local_currency": {"type": "keyword"},
      "amount": {"type": "double"},
      "local_currency_amount": {"type": "double"},
      "cleared_amount": {"type": "double"},
      "is_ecommerce": {"type": "boolean"},
      "international": {"type": "boolean"},
      "created_at": {"type": "date"},
      "updated_at": {"type": "date"},
      "released_at": {"type": "date"},
      "expiry_date": {"type": "date"},
      "merchant_id": {"type": "keyword"},
      "merchant_category_code": {"type": "integer"},
      "merchant_description": {"type": "text"},
      "merchant_country": {"type": "keyword"}
    }
  }
}'

# =====================================================
# Verification
# =====================================================

echo ""
echo "=== Verification ==="
echo ""

log_info "Indices created:"
curl -s "${OPENSEARCH_URL}/_cat/indices?v" | grep -E "(${TABLE_SAVINGS_TRANSACTION}|${TABLE_CARD}|${TABLE_AUTHORIZE_TX}|${TABLE_CARD_AUTH})"

echo ""
log_success "All indices created successfully!"
echo ""
log_info "Next step: Start Python consumer"
echo "  - Single table: python3 kafka-to-opensearch.py"
echo "  - Multi table:  python3 kafka-to-opensearch-multi.py"
echo ""
