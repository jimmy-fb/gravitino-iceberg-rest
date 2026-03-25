# Gravitino Iceberg REST Server — Kubernetes Deployment Guide

Deploy [Apache Gravitino](https://gravitino.apache.org/) as an **Iceberg REST Catalog** on Kubernetes, bridging your existing **Hive Metastore** and **S3** storage with any Iceberg-compatible query engine — including Firebolt, Spark, Trino, and others.

> **Scope of this guide**
> This repository covers **Gravitino deployment only**. It assumes you already have a running Hive Metastore and an S3 bucket. Firebolt and Spark setup are described in the integration sections.

---

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                       Kubernetes Cluster                        │
 │                                                                 │
 │   ┌────────────────────────────────────────────────────────┐   │
 │   │           gravitino  (namespace)                       │   │
 │   │                                                        │   │
 │   │   ┌──────────────────────────────────────┐            │   │
 │   │   │   Gravitino Iceberg REST Server      │            │   │
 │   │   │   apache/gravitino-iceberg-rest:1.2.0│            │   │
 │   │   │                                      │            │   │
 │   │   │   Listens on  :9001/iceberg/v1       │            │   │
 │   │   └──────────────┬───────────────────────┘            │   │
 │   │                  │  Thrift (port 9083)                 │   │
 │   └──────────────────┼────────────────────────────────────┘   │
 │                      │                                          │
 └──────────────────────┼──────────────────────────────────────── ┘
                        │
          ┌─────────────▼──────────────┐
          │   Hive Metastore (yours)   │  ← already running
          │   thrift://<host>:9083     │
          └─────────────┬──────────────┘
                        │ metadata
          ┌─────────────▼──────────────┐
          │       Amazon S3            │  ← already provisioned
          │   s3://<bucket>/iceberg    │
          └────────────────────────────┘
                        ▲
          ┌─────────────┴──────────────┐
          │  Query engines (external)  │
          │  • Firebolt Core           │
          │  • Apache Spark            │
          │  • Trino / Flink           │
          └────────────────────────────┘
```

Gravitino acts as an **Iceberg REST Catalog proxy**:
- All catalog operations (create namespace, create/list/drop tables) go through Gravitino's REST API (`/iceberg/v1/*`).
- Gravitino translates these calls to **Hive Metastore Thrift API** calls, so all existing Hive tables and databases remain accessible.
- Data files are stored directly on **S3** using `S3FileIO`.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes ≥ 1.24 | k3s, EKS, GKE, AKS or any distribution |
| `kubectl` configured | pointing to your cluster |
| Hive Metastore | Thrift endpoint reachable from the cluster |
| S3 bucket | with a prefix for Iceberg data |
| AWS credentials | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the warehouse prefix |

---

## Quick Start

### 1. Clone this repository

```bash
git clone https://github.com/jimmy-fb/gravitino-iceberg-rest.git
cd gravitino-iceberg-rest
```

### 2. Configure your environment

Edit **`k8s/02-gravitino-configmap.yaml`** and set:

| Key | Description | Example |
|---|---|---|
| `GRAVITINO_URI` | Hive Metastore Thrift endpoint | `thrift://hive-metastore:9083` |
| `GRAVITINO_WAREHOUSE` | S3 warehouse root for new Iceberg tables | `s3://my-bucket/iceberg` |
| `GRAVITINO_S3_REGION` | AWS region of your S3 bucket | `ap-south-1` |
| `GRAVITINO_S3_ENDPOINT` | S3 regional endpoint URL | `https://s3.ap-south-1.amazonaws.com` |
| `GRAVITINO_S3_PATH_STYLE_ACCESS` | `true` only for MinIO/path-style S3 | `false` (AWS S3 default) |

Edit **`k8s/01-secrets.yaml`** and replace the placeholder credential values, **or** create the secret directly (preferred for production):

```bash
kubectl create namespace gravitino

kubectl create secret generic aws-credentials \
  --namespace gravitino \
  --from-literal=AWS_ACCESS_KEY_ID=<your-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key> \
  --from-literal=AWS_REGION=ap-south-1
```

> **Production tip:** Use an IAM role attached to your node group / pod identity instead of static keys.

### 3. Apply all manifests

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml        # skip if you created the secret above
kubectl apply -f k8s/02-gravitino-configmap.yaml
kubectl apply -f k8s/03-gravitino.yaml
```

### 4. Verify the deployment

```bash
# Wait for the pod to become Ready
kubectl rollout status deployment/gravitino-iceberg-rest -n gravitino

# Check logs
kubectl logs -n gravitino deployment/gravitino-iceberg-rest --tail=50

# Port-forward for local access
kubectl port-forward -n gravitino svc/gravitino-iceberg-rest 9001:9001 &

# Hit the config endpoint
curl http://localhost:9001/iceberg/v1/config | python3 -m json.tool
```

Expected response:
```json
{
  "defaults": {},
  "overrides": {}
}
```

Use the provided verification script to run a full smoke test:
```bash
./scripts/verify.sh localhost 9001
```

---

## Configuration Reference

### Environment variables (injected by the ConfigMap)

| Variable | Description |
|---|---|
| `GRAVITINO_CATALOG_BACKEND` | Backend catalog type. Must be `hive` for Hive Metastore. |
| `GRAVITINO_URI` | Thrift URI of the Hive Metastore. |
| `GRAVITINO_WAREHOUSE` | S3 path used as the Iceberg warehouse root. |
| `GRAVITINO_IO_IMPL` | FileIO implementation. Use `org.apache.iceberg.aws.s3.S3FileIO` for S3. |
| `GRAVITINO_S3_ACCESS_KEY` | AWS access key ID (injected from the Secret). |
| `GRAVITINO_S3_SECRET_KEY` | AWS secret access key (injected from the Secret). |
| `GRAVITINO_S3_REGION` | AWS region. |
| `GRAVITINO_S3_ENDPOINT` | S3 endpoint URL. |
| `GRAVITINO_S3_PATH_STYLE_ACCESS` | `false` for AWS S3, `true` for MinIO or path-style storage. |
| `GRAVITINO_CREDENTIAL_PROVIDERS` | Set to `s3-token` to enable credential vending. |

### Service exposure

The deployment creates two services:

| Service | Type | Port | Use |
|---|---|---|---|
| `gravitino-iceberg-rest` | `ClusterIP` | 9001 | In-cluster access (Spark, Flink, etc.) |
| `gravitino-iceberg-rest-external` | `NodePort` | 30901 | External access for testing |

For production, replace the NodePort service with an **Ingress** or **LoadBalancer** and add TLS.

---

## Integrating with Apache Spark

Spark connects to Gravitino using the Iceberg Spark catalog extension.

### Required JARs

Download these JARs and add them to your Spark classpath (or use `--jars`):

```
iceberg-spark-runtime-3.5_2.12-1.5.2.jar
iceberg-aws-bundle-1.5.2.jar
```

Download links:
```bash
curl -Lo iceberg-spark-runtime.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.5.2/iceberg-spark-runtime-3.5_2.12-1.5.2.jar

curl -Lo iceberg-aws-bundle.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.5.2/iceberg-aws-bundle-1.5.2.jar
```

### spark-submit configuration

```bash
spark-submit \
  --jars "iceberg-spark-runtime.jar,iceberg-aws-bundle.jar" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.gravitino=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.gravitino.type=rest \
  --conf spark.sql.catalog.gravitino.uri=http://<GRAVITINO_HOST>:9001/iceberg/ \
  --conf spark.sql.catalog.gravitino.s3.access-key-id=<AWS_ACCESS_KEY_ID> \
  --conf spark.sql.catalog.gravitino.s3.secret-access-key=<AWS_SECRET_ACCESS_KEY> \
  --conf spark.sql.catalog.gravitino.s3.region=ap-south-1 \
  --conf spark.sql.catalog.gravitino.s3.endpoint=https://s3.ap-south-1.amazonaws.com \
  your_script.py
```

### PySpark example

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("gravitino-test").getOrCreate()

# Create a namespace
spark.sql("CREATE NAMESPACE IF NOT EXISTS gravitino.demo_db")

# Create an Iceberg table
spark.sql("""
  CREATE TABLE IF NOT EXISTS gravitino.demo_db.orders (
    order_id    BIGINT,
    customer_id BIGINT,
    amount      DOUBLE,
    order_date  DATE
  )
  USING iceberg
""")

# Insert sample rows
spark.sql("""
  INSERT INTO gravitino.demo_db.orders VALUES
    (1, 101, 250.00, DATE '2024-01-15'),
    (2, 102, 180.50, DATE '2024-01-16'),
    (3, 101, 320.75, DATE '2024-02-01')
""")

spark.sql("SELECT * FROM gravitino.demo_db.orders").show()
```

In-cluster endpoint: `http://gravitino-iceberg-rest.gravitino.svc.cluster.local:9001/iceberg/`

---

## Integrating with Firebolt

Firebolt supports two approaches for reading Iceberg tables created via Gravitino.

### Option A — FILE_BASED catalog (recommended, no OAuth needed)

This approach points Firebolt directly to the S3 location of each Iceberg table. It works with any Iceberg table created via Gravitino/Spark and requires no additional authentication setup.

```sql
-- Create a location for each Iceberg table
CREATE LOCATION my_orders
WITH
  SOURCE = ICEBERG
  CATALOG = FILE_BASED
  CATALOG_OPTIONS = (
    URL = 's3://YOUR_BUCKET/iceberg/demo_db/orders'
  )
  CREDENTIALS = (
    AWS_ACCESS_KEY_ID = '<your-access-key>'
    AWS_SECRET_ACCESS_KEY = '<your-secret-key>'
  );

-- Query the table
SELECT * FROM READ_ICEBERG(LOCATION => 'my_orders') LIMIT 10;

-- Aggregation example
SELECT
  DATE_TRUNC('month', order_date) AS month,
  COUNT(*)                        AS num_orders,
  ROUND(SUM(amount), 2)           AS total_revenue
FROM READ_ICEBERG(LOCATION => 'my_orders')
GROUP BY 1
ORDER BY 1;
```

> **Note on metadata files**: Firebolt's `FILE_BASED` catalog expects a `version-hint.text` file in the `metadata/` directory of each table. Iceberg tables created by Spark with a Hive catalog backend do not generate this file automatically. If you encounter the error `Could not find version hint file`, create the file manually:
>
> ```bash
> # Find the latest metadata version number (look for the highest-numbered file)
> aws s3 ls s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/ | grep metadata.json
>
> # Create the version-hint.text file (no trailing newline)
> printf "1" | aws s3 cp - s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/version-hint.text
>
> # Also create a symlink alias that Firebolt uses
> aws s3 cp \
>   s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/00001-<uuid>.metadata.json \
>   s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/v1.metadata.json
> ```

### Option B — REST catalog (requires OAuth)

Firebolt's REST catalog integration requires an OAuth2 token endpoint. Gravitino's standalone Iceberg REST server (`gravitino-iceberg-rest` image) does not expose a public OAuth endpoint by default. This option requires additional OAuth middleware or a reverse proxy.

If you need REST catalog access from Firebolt, contact your Firebolt account team for the latest guidance on OAuth configuration.

---

## Troubleshooting

### Pod stuck in `Init` or `CrashLoopBackOff`

```bash
kubectl describe pod -n gravitino -l app=gravitino-iceberg-rest
kubectl logs -n gravitino -l app=gravitino-iceberg-rest --previous
```

Common causes:
- **Cannot connect to Hive Metastore**: verify the `GRAVITINO_URI` value and that port 9083 is reachable from the cluster network.
- **S3 access denied**: check that the IAM user/role has the required permissions on the warehouse bucket and prefix.

### Config endpoint returns `connection refused`

The server starts JVM and loads the catalog on startup — it can take 20–30 seconds. Check readiness probe events:
```bash
kubectl get events -n gravitino --sort-by='.lastTimestamp'
```

### Namespace or table creation fails with `Failed to create external path`

Gravitino (via Hive Metastore) tries to create the S3 directory prefix for new namespaces. Ensure the AWS credentials have `s3:PutObject` and `s3:ListBucket` permissions on the warehouse prefix.

### Spark: `NoClassDefFoundError: software/amazon/awssdk/...`

Use `iceberg-aws-bundle-1.5.2.jar` (AWS SDK v2) instead of `aws-java-sdk-bundle` (AWS SDK v1). They are not compatible.

---

## Tested Versions

| Component | Version |
|---|---|
| Apache Gravitino Iceberg REST | `1.2.0` |
| Apache Hive Metastore | `4.0.0` |
| Apache Spark | `3.5.1` |
| Iceberg Spark Runtime | `1.5.2` |
| Iceberg AWS Bundle | `1.5.2` |
| Kubernetes | `k3s v1.29` |
| Firebolt Core | latest |

---

## Repository Structure

```
.
├── k8s/
│   ├── 00-namespace.yaml            # gravitino namespace
│   ├── 01-secrets.yaml              # AWS credentials secret (template)
│   ├── 02-gravitino-configmap.yaml  # Gravitino server configuration
│   └── 03-gravitino.yaml            # Deployment + ClusterIP + NodePort services
├── scripts/
│   └── verify.sh                    # Smoke-test the running server
└── README.md
```

---

## License

Apache License 2.0 — same license as Apache Gravitino itself.
