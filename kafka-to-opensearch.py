#!/usr/bin/env python3
"""
Simple Kafka to OpenSearch consumer
Reads CDC messages from Kafka and writes to OpenSearch
"""

import json
import sys
from kafka import KafkaConsumer
import requests

# Configuration
KAFKA_BOOTSTRAP = 'localhost:29092'
KAFKA_TOPIC = 'm_savings_account_transaction'
OPENSEARCH_URL = 'http://localhost:9200'
INDEX_NAME = 'm_savings_account_transaction'

def main():
    print(f"🚀 Starting Kafka→OpenSearch consumer...")
    print(f"   Kafka: {KAFKA_BOOTSTRAP}")
    print(f"   Topic: {KAFKA_TOPIC}")
    print(f"   OpenSearch: {OPENSEARCH_URL}/{INDEX_NAME}")
    print()

    # Create Kafka consumer
    try:
        consumer = KafkaConsumer(
            KAFKA_TOPIC,
            bootstrap_servers=KAFKA_BOOTSTRAP,
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            group_id='opensearch-consumer-group',
            value_deserializer=lambda x: json.loads(x.decode('utf-8'))
        )
        print("✅ Connected to Kafka")
    except Exception as e:
        print(f"❌ Failed to connect to Kafka: {e}")
        sys.exit(1)

    # Process messages
    message_count = 0
    try:
        for message in consumer:
            try:
                value = message.value

                # Extract the 'after' field (contains the actual data)
                if 'after' in value and value['after'] is not None:
                    doc = value['after']
                    doc_id = doc.get('id')

                    # Index to OpenSearch
                    response = requests.put(
                        f"{OPENSEARCH_URL}/{INDEX_NAME}/_doc/{doc_id}",
                        json=doc,
                        headers={'Content-Type': 'application/json'}
                    )

                    if response.status_code in [200, 201]:
                        message_count += 1
                        print(f"✅ [{message_count}] Indexed document ID: {doc_id}, Amount: {doc.get('amount')}")
                    else:
                        print(f"❌ Failed to index: {response.text}")

                # Handle deletes
                elif value.get('op') == 'd':
                    doc_id = value.get('before', {}).get('id')
                    if doc_id:
                        response = requests.delete(f"{OPENSEARCH_URL}/{INDEX_NAME}/_doc/{doc_id}")
                        print(f"🗑️  Deleted document ID: {doc_id}")

            except Exception as e:
                print(f"❌ Error processing message: {e}")

    except KeyboardInterrupt:
        print(f"\n\n⏹️  Stopped. Processed {message_count} messages.")
    finally:
        consumer.close()

if __name__ == '__main__':
    main()
