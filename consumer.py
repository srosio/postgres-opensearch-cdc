#!/usr/bin/env python3
"""
PostgreSQL to OpenSearch CDC Consumer
Syncs data from Kafka topics to OpenSearch indices
"""

import json
import sys
from kafka import KafkaConsumer
import requests

# Configuration
KAFKA_BOOTSTRAP = 'localhost:29092'
OPENSEARCH_URL = 'http://localhost:9200'

# Topic to index mapping
TOPICS = {
    'postgres.public.card': 'card',
    'postgres.public.authorize_transaction': 'authorize_transaction',
    'postgres.public.card_authorization': 'card_authorization',
}

def main():
    print(f"🚀 Starting CDC Consumer")
    print(f"   Kafka: {KAFKA_BOOTSTRAP}")
    print(f"   OpenSearch: {OPENSEARCH_URL}")
    print(f"   Topics: {len(TOPICS)}")
    for topic, index in TOPICS.items():
        print(f"      {topic} → {index}")
    print()

    # Create Kafka consumer
    try:
        consumer = KafkaConsumer(
            *list(TOPICS.keys()),
            bootstrap_servers=KAFKA_BOOTSTRAP,
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            group_id='opensearch-cdc-consumer',
            value_deserializer=lambda x: json.loads(x.decode('utf-8'))
        )
        print("✅ Connected to Kafka\n")
    except Exception as e:
        print(f"❌ Failed to connect to Kafka: {e}")
        sys.exit(1)

    # Process messages
    stats = {'total': 0, 'snapshot': 0, 'create': 0, 'update': 0, 'delete': 0}

    try:
        print("📡 Listening for CDC events...\n")

        for message in consumer:
            try:
                value = message.value
                topic = message.topic
                index_name = TOPICS.get(topic)

                # Handle INSERT/UPDATE
                if 'after' in value and value['after'] is not None:
                    doc = value['after']
                    doc_id = doc.get('id')

                    response = requests.put(
                        f"{OPENSEARCH_URL}/{index_name}/_doc/{doc_id}",
                        json=doc,
                        headers={'Content-Type': 'application/json'}
                    )

                    if response.status_code in [200, 201]:
                        stats['total'] += 1
                        op = value.get('op', '?')

                        if op == 'r':
                            stats['snapshot'] += 1
                            emoji = '📸'
                            op_name = 'snapshot'
                        elif op == 'c':
                            stats['create'] += 1
                            emoji = '➕'
                            op_name = 'create'
                        elif op == 'u':
                            stats['update'] += 1
                            emoji = '✏️'
                            op_name = 'update'
                        else:
                            emoji = '📝'
                            op_name = op

                        print(f"{emoji} [{stats['total']}] {index_name}:{doc_id} ({op_name})")

                # Handle DELETE
                elif value.get('op') == 'd':
                    doc_id = value.get('before', {}).get('id')
                    if doc_id:
                        response = requests.delete(f"{OPENSEARCH_URL}/{index_name}/_doc/{doc_id}")
                        if response.status_code in [200, 404]:
                            stats['total'] += 1
                            stats['delete'] += 1
                            print(f"🗑️  [{stats['total']}] {index_name}:{doc_id} (delete)")

            except Exception as e:
                print(f"❌ Error processing message: {e}")

    except KeyboardInterrupt:
        print(f"\n\n⏹️  Stopped by user")
    finally:
        # Print statistics
        print("\n" + "="*60)
        print("📊 Statistics")
        print("="*60)
        print(f"Total:    {stats['total']}")
        print(f"Snapshot: {stats['snapshot']}")
        print(f"Create:   {stats['create']}")
        print(f"Update:   {stats['update']}")
        print(f"Delete:   {stats['delete']}")
        print()

        consumer.close()

if __name__ == '__main__':
    main()
