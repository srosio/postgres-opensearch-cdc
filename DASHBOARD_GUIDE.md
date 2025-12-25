# OpenSearch Dashboards - Sample Dashboard Guide

## Quick Setup

### 1. Create Sample Data

```bash
./create-sample-data.sh  # Creates sample cards, transactions, etc.
./setup.sh               # Configure CDC pipeline
python3 consumer.py      # Sync data to OpenSearch (run for 30 seconds)
```

### 2. Access Dashboards

Open http://localhost:5601

### 3. Create Index Patterns

**Management → Index Patterns → Create**

Create these patterns:
- `card*` - Card master data
- `*transaction*` - All transaction tables
- `*` - All indices (alternative)

### 4. Build Visualizations

**Dashboard → Create Visualization**

**Recommended Visualizations:**

**A. Card Status Distribution (Pie Chart)**
- Index: `card*`
- Metric: Count
- Buckets: Split Slices by `status.keyword`

**B. Transaction Amount Over Time (Line Chart)**
- Index: `*savings*transaction*`
- Y-axis: Sum of `amount`
- X-axis: Date Histogram on `created_date`

**C. Active vs Pending Authorizations (Metric)**
- Index: `authorize_transaction*`
- Metrics:
  - Count where `is_active: true`
  - Count where `is_active: false`

**D. Card Type Breakdown (Bar Chart)**
- Index: `card*`
- Y-axis: Count
- X-axis: Terms on `card_type.keyword`

**E. Card Network Distribution (Pie)**
- Index: `card*`
- Metric: Count
- Split: `card_network.keyword`

**F. Recent Transactions (Data Table)**
- Index: `*transaction*`
- Columns: `id`, `amount`, `transaction_date`, `reference`
- Sort: `created_date` descending

### 5. Create Dashboard

**Dashboard → Create Dashboard → Add Visualizations**

Arrange visualizations:
```
┌─────────────────┬─────────────────┐
│  Card Status    │  Card Network   │
│  (Pie)          │  (Pie)          │
├─────────────────┴─────────────────┤
│  Transaction Amount Over Time     │
│  (Line Chart)                     │
├───────────────────────────────────┤
│  Card Type Distribution (Bar)     │
├───────────────────────────────────┤
│  Recent Transactions (Table)      │
└───────────────────────────────────┘
```

**Save as:** "CDC Pipeline Dashboard"

### 6. Explore Data

**Discover Tab:**
- Select index pattern
- Filter by date range
- Search: `status:ACTIVE AND card_type:DEBIT`
- Add columns: `id`, `status`, `card_network`, `created_at`

**Dev Tools Tab:**

Test queries:
```json
GET card/_search
{
  "query": { "match": { "status": "ACTIVE" }},
  "size": 10
}

GET *transaction*/_search
{
  "query": {
    "range": {
      "amount": { "gte": 100 }
    }
  }
}
```

## Tips

1. **Refresh Data:** Set auto-refresh (top-right) to see real-time updates
2. **Time Range:** Adjust time filter to match your data
3. **Save Searches:** Save useful filters for quick access
4. **Export:** Share dashboards as JSON
5. **Alerts:** Set up alerts for specific conditions

## Sample Queries

**Find high-value transactions:**
```
amount > 1000 AND status_enum:0
```

**Active cards only:**
```
status:ACTIVE AND physical_card_activated:true
```

**Recent authorizations:**
```
is_active:true AND pending_amount > 0
```

That's it! 🎉
