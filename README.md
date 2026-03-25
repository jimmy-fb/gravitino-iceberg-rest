# Gravitino Iceberg REST Server — Kubernetes Deployment Guide

Deploy [Apache Gravitino](https://gravitino.apache.org/) as an **Iceberg REST Catalog** on Kubernetes, bridging your existing **Hive Metastore** and **S3** storage with any Iceberg-compatible query engine — including Firebolt, Spark, Trino, and others.

**OAuth2 is fully integrated.** A minimal OAuth2 token server is deployed alongside Gravitino, giving Firebolt and Spark a real token endpoint to authenticate against without any external identity provider.

> **Scope of this guide**
> This repository covers **Gravitino and OAuth server deployment only**. It assumes you already have a running Hive Metastore and an S3 bucket. Firebolt and Spark setup are described in the integration sections.

---

## Architecture

```
                         ┌──────────────────────────────────────────────────┐
                         │          Kubernetes cluster (gravitino ns)        │
                         │                                                  │
  ┌──────────────────┐   │  ┌──────────────────────────────────────────┐   │
  │  Firebolt Core   │   │  │  OAuth Server  :8080                     │   │
  │  Apache Spark    │──►│  │  (pure Python — no extra deps)           │   │
  │  Trino / Flink   │   │  │  POST /oauth/tokens → JWT (HS256)        │   │
  └──────────────────┘   │  └───────────────┬──────────────────────────┘   │
          │              │                  │ shared signing key             │
          │ Bearer JWT   │  ┌───────────────▼──────────────────────────┐   │
          └─────────────►│  │  Gravitino Iceberg REST  :9001           │   │
                         │  │  /iceberg/v1/*                           │   │
                         │  │  validates JWT → proxies to Hive         │   │
                         │  └───────────────┬──────────────────────────┘   │
                         └─────────────────-│──────────────────────────────┘
                                            │ Thrift :9083
                              ┌─────────────▼──────────────┐
                              │  Hive Metastore (yours)    │
                              └─────────────┬──────────────┘
                                            │ metadata
                              ┌─────────────▼──────────────┐
                              │  Amazon S3                 │
                              │  s3://<bucket>/iceberg     │
                              └────────────────────────────┘
```

### How authentication works

1. A client (Firebolt / Spark) calls **`POST <oauth-server>/oauth/tokens`** with `grant_type=client_credentials` + `client_id` + `client_secret`.
2. The OAuth server issues a **HS256-signed JWT** (audience `gravitino`, TTL 1 hour).
3. The client adds `Authorization: Bearer <token>` to every Iceberg REST request.
4. Gravitino's **StaticSignKeyValidator** verifies the JWT signature using the same shared HMAC key and allows the request if the signature and audience claim are valid.

The OAuth server and Gravitino both read the signing key from the **same Kubernetes Secret**, so they stay in sync automatically.

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

### 2. Set your environment values

**`k8s/01-secrets.yaml`** — update three values:

| Key | Where | What to set |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | `aws-credentials` Secret | Your AWS access key |
| `AWS_SECRET_ACCESS_KEY` | `aws-credentials` Secret | Your AWS secret key |
| `OAUTH_CLIENT_SECRET` | `oauth-credentials` Secret | Strong random string — this is what Firebolt will use as its password |

To generate a strong client secret:
```bash
openssl rand -base64 24
```

**Leave `OAUTH_SIGN_KEY_B64` unchanged** unless you want to rotate the signing key (see [Rotating the signing key](#rotating-the-signing-key)).

**`k8s/02-gravitino-configmap.yaml`** — update three values:

| Key | What to set |
|---|---|
| `GRAVITINO_URI` | Thrift URI of your Hive Metastore, e.g. `thrift://hive-metastore:9083` |
| `GRAVITINO_WAREHOUSE` | S3 warehouse root, e.g. `s3://my-bucket/iceberg` |
| `GRAVITINO_S3_REGION` | AWS region of your bucket |
| `GRAVITINO_S3_ENDPOINT` | Region-specific S3 endpoint, e.g. `https://s3.ap-south-1.amazonaws.com` |

### 3. Apply the manifests

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-gravitino-configmap.yaml
kubectl apply -f k8s/03-gravitino.yaml
kubectl apply -f k8s/04-oauth-server.yaml
```

### 4. Verify the deployment

```bash
# Wait for both pods to be Ready
kubectl rollout status deployment/oauth-server            -n gravitino
kubectl rollout status deployment/gravitino-iceberg-rest  -n gravitino

# Check Gravitino logs (look for "OAuth" lines in the config dump)
kubectl logs -n gravitino deployment/gravitino-iceberg-rest --tail=60

# Check OAuth server logs
kubectl logs -n gravitino deployment/oauth-server
```

Run the full smoke-test against the NodePort services:

```bash
./scripts/verify.sh <NODE_IP> 30901 30902
```

The script will:
1. Check the OAuth server `/health` endpoint
2. Request a token using `client_credentials`
3. Call Gravitino's `/iceberg/v1/config` with the Bearer token
4. List namespaces and tables

---

## Port Reference

| Service | Type | Port | Purpose |
|---|---|---|---|
| `gravitino-iceberg-rest` | ClusterIP | 9001 | In-cluster Iceberg REST access |
| `gravitino-iceberg-rest-external` | NodePort | **30901** | External Iceberg REST access |
| `oauth-server` | ClusterIP | 8080 | In-cluster token endpoint |
| `oauth-server-external` | NodePort | **30902** | External token endpoint |

---

## Integrating with Apache Spark

### Required JARs

```bash
curl -Lo iceberg-spark-runtime.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.5.2/iceberg-spark-runtime-3.5_2.12-1.5.2.jar

curl -Lo iceberg-aws-bundle.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.5.2/iceberg-aws-bundle-1.5.2.jar
```

> Use `iceberg-aws-bundle` (AWS SDK v2). Do **not** mix it with `aws-java-sdk-bundle` (AWS SDK v1).

### spark-submit with OAuth2

```bash
GRAVITINO_HOST="<node-ip>"          # or internal k8s hostname
GRAVITINO_PORT="30901"              # NodePort (use 9001 for in-cluster)
OAUTH_HOST="<node-ip>"
OAUTH_PORT="30902"                  # NodePort (use 8080 for in-cluster)

spark-submit \
  --jars "iceberg-spark-runtime.jar,iceberg-aws-bundle.jar" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.gravitino=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.gravitino.type=rest \
  --conf "spark.sql.catalog.gravitino.uri=http://${GRAVITINO_HOST}:${GRAVITINO_PORT}/iceberg/" \
  --conf "spark.sql.catalog.gravitino.rest.auth.type=oauth2" \
  --conf "spark.sql.catalog.gravitino.credential=firebolt:<YOUR_CLIENT_SECRET>" \
  --conf "spark.sql.catalog.gravitino.scope=gravitino" \
  --conf "spark.sql.catalog.gravitino.oauth2-server-uri=http://${OAUTH_HOST}:${OAUTH_PORT}/oauth/tokens" \
  --conf "spark.sql.catalog.gravitino.s3.access-key-id=<AWS_ACCESS_KEY_ID>" \
  --conf "spark.sql.catalog.gravitino.s3.secret-access-key=<AWS_SECRET_ACCESS_KEY>" \
  --conf "spark.sql.catalog.gravitino.s3.region=ap-south-1" \
  --conf "spark.sql.catalog.gravitino.s3.endpoint=https://s3.ap-south-1.amazonaws.com" \
  your_script.py
```

### PySpark example

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("gravitino-oauth-test").getOrCreate()

spark.sql("CREATE NAMESPACE IF NOT EXISTS gravitino.demo_db")

spark.sql("""
  CREATE TABLE IF NOT EXISTS gravitino.demo_db.orders (
    order_id    BIGINT,
    customer_id BIGINT,
    amount      DOUBLE,
    order_date  DATE
  ) USING iceberg
""")

spark.sql("""
  INSERT INTO gravitino.demo_db.orders VALUES
    (1, 101, 250.00, DATE '2024-01-15'),
    (2, 102, 180.50, DATE '2024-01-16'),
    (3, 101, 320.75, DATE '2024-02-01')
""")

spark.sql("SELECT * FROM gravitino.demo_db.orders").show()
```

In-cluster Spark endpoint: `http://gravitino-iceberg-rest.gravitino.svc.cluster.local:9001/iceberg/`

---

## Integrating with Firebolt

Firebolt Core connects to Gravitino via the Iceberg REST catalog using the OAuth2 token it obtains from the OAuth server.

### Connection details

| Parameter | Value |
|---|---|
| Iceberg REST URL | `http://<NODE_IP>:30901/iceberg/` |
| Token endpoint | `http://<NODE_IP>:30902/oauth/tokens` |
| `client_id` | `firebolt` (default; set in ConfigMap `OAUTH_CLIENT_ID`) |
| `client_secret` | value of `OAUTH_CLIENT_SECRET` in `oauth-credentials` Secret |

### Option A — REST catalog (full OAuth flow, recommended)

```sql
-- Step 1: Create a location pointing to Gravitino REST catalog with OAuth
CREATE LOCATION gravitino_catalog
WITH
  SOURCE = ICEBERG
  CATALOG = REST
  CATALOG_OPTIONS = (
    URI              = 'http://<NODE_IP>:30901/iceberg/'
    CREDENTIAL       = 'firebolt:<YOUR_CLIENT_SECRET>'
    OAUTH2_SERVER_URI = 'http://<NODE_IP>:30902/oauth/tokens'
    SCOPE            = 'gravitino'
  );

-- Step 2: Query any table managed by Gravitino
SELECT * FROM READ_ICEBERG(
  LOCATION => 'gravitino_catalog',
  TABLE     => 'demo_db.orders'
) LIMIT 10;
```

### Option B — FILE_BASED catalog (no OAuth, direct S3)

If you prefer to bypass the catalog entirely and read Iceberg tables directly from S3, use the `FILE_BASED` approach. It works immediately without OAuth but requires you to know each table's S3 path.

```sql
CREATE LOCATION gravitino_orders
WITH
  SOURCE = ICEBERG
  CATALOG = FILE_BASED
  CATALOG_OPTIONS = (
    URL = 's3://YOUR_BUCKET/iceberg/demo_db/orders'
  )
  CREDENTIALS = (
    AWS_ACCESS_KEY_ID     = '<AWS_ACCESS_KEY_ID>'
    AWS_SECRET_ACCESS_KEY = '<AWS_SECRET_ACCESS_KEY>'
  );

SELECT * FROM READ_ICEBERG(LOCATION => 'gravitino_orders') LIMIT 10;
```

> **Note on `version-hint.text`**: Firebolt's `FILE_BASED` catalog expects a `version-hint.text` file in each table's `metadata/` directory. Iceberg tables created by Spark with a Hive-backed catalog do not generate this file. If you see `Could not find version hint file`, create it manually:
>
> ```bash
> # No trailing newline — use printf, not echo
> printf "1" | aws s3 cp - s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/version-hint.text
> # Also create the v1 alias that Firebolt resolves
> aws s3 cp \
>   s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/00001-<uuid>.metadata.json \
>   s3://YOUR_BUCKET/iceberg/demo_db/orders/metadata/v1.metadata.json
> ```

---

## Configuration Reference

### Gravitino environment variables (from ConfigMap)

| Variable | Description |
|---|---|
| `GRAVITINO_CATALOG_BACKEND` | `hive` for Hive Metastore |
| `GRAVITINO_URI` | Hive Metastore Thrift URI |
| `GRAVITINO_WAREHOUSE` | S3 warehouse root prefix |
| `GRAVITINO_IO_IMPL` | `org.apache.iceberg.aws.s3.S3FileIO` |
| `GRAVITINO_S3_ACCESS_KEY` | AWS access key (from Secret) |
| `GRAVITINO_S3_SECRET_KEY` | AWS secret key (from Secret) |
| `GRAVITINO_S3_REGION` | AWS region |
| `GRAVITINO_S3_ENDPOINT` | S3 endpoint URL |
| `GRAVITINO_S3_PATH_STYLE_ACCESS` | `false` for AWS S3, `true` for MinIO |
| `GRAVITINO_CREDENTIAL_PROVIDERS` | `s3-token` |
| `OAUTH_AUDIENCE` | JWT `aud` claim — must match between server and Gravitino |
| `OAUTH_TOKEN_PATH` | Token endpoint path advertised by Gravitino to clients |
| `OAUTH_SERVER_URI` | OAuth server base URL advertised by Gravitino |
| `OAUTH_CLIENT_ID` | Default client ID for Firebolt/Spark |

### OAuth server environment variables

| Variable | Source | Description |
|---|---|---|
| `OAUTH_SIGN_KEY_B64` | `oauth-credentials` Secret | Base64-encoded HMAC signing key |
| `OAUTH_CLIENT_SECRET` | `oauth-credentials` Secret | Client secret for token requests |
| `OAUTH_CLIENT_ID` | ConfigMap | Accepted client ID |
| `OAUTH_AUDIENCE` | ConfigMap | JWT audience claim |
| `TOKEN_TTL` | ConfigMap (optional) | Token lifetime in seconds (default 3600) |

### Gravitino OAuth properties (appended to conf file at startup)

These are written into `conf/gravitino-iceberg-rest-server.conf` by the startup command in `k8s/03-gravitino.yaml`:

```properties
gravitino.authenticators                            = oauth
gravitino.authenticator.oauth.signAlgorithmType     = HS256
gravitino.authenticator.oauth.serviceAudience       = gravitino
gravitino.authenticator.oauth.defaultSignKey        = <OAUTH_SIGN_KEY_B64>
gravitino.authenticator.oauth.tokenPath             = /oauth/tokens
gravitino.authenticator.oauth.serverUri             = http://oauth-server.gravitino.svc.cluster.local:8080
```

---

## Rotating the Signing Key

1. Generate a new key:
   ```bash
   openssl rand -base64 32 | base64   # double-encode as Gravitino expects base64(raw_bytes)
   ```
2. Update `OAUTH_SIGN_KEY_B64` in `k8s/01-secrets.yaml` (or patch the Secret directly).
3. Re-apply: `kubectl apply -f k8s/01-secrets.yaml`
4. Roll both deployments to pick up the new key:
   ```bash
   kubectl rollout restart deployment/oauth-server           -n gravitino
   kubectl rollout restart deployment/gravitino-iceberg-rest -n gravitino
   ```
5. Any in-flight tokens signed with the old key will be rejected immediately. Clients will re-authenticate automatically on their next request.

---

## Troubleshooting

### `401 Unauthorized` on Gravitino endpoints

Verify the token is valid and the audience matches:
```bash
# Decode the payload (middle part of the JWT)
TOKEN=$(curl -s -X POST http://<node>:30902/oauth/tokens \
  -d "grant_type=client_credentials&client_id=firebolt&client_secret=firebolt-secret" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "${TOKEN}" | cut -d. -f2 | python3 -c "
import sys, base64, json
p = sys.stdin.read().strip()
p += '=' * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))
"
```
The decoded payload should show `"aud": "gravitino"`. If it doesn't, check that `OAUTH_AUDIENCE` is set to `gravitino` in both the ConfigMap and the Secret.

### `403 Forbidden — audience mismatch`

The `aud` claim in the JWT does not match `gravitino.authenticator.oauth.serviceAudience`. Both must be set to the same string (`gravitino` by default).

### Pod stuck in `CrashLoopBackOff` (Gravitino)

```bash
kubectl logs -n gravitino deployment/gravitino-iceberg-rest --previous
```

Common causes:
- Cannot reach Hive Metastore at `GRAVITINO_URI` — check Thrift port 9083 is open.
- S3 access denied — verify the IAM credentials have the required permissions.
- `defaultSignKey` missing — the `oauth-credentials` Secret was not applied before the deployment.

### OAuth server returns `500`

```bash
kubectl logs -n gravitino deployment/oauth-server
```

Most likely cause: `OAUTH_SIGN_KEY_B64` or `OAUTH_CLIENT_SECRET` env vars are missing (Secret not applied or not referenced correctly).

### Spark `NoClassDefFoundError: software/amazon/awssdk/...`

Use `iceberg-aws-bundle-1.5.2.jar` (AWS SDK v2). Remove any `aws-java-sdk-bundle` JAR from the classpath — they conflict.

---

## Repository Structure

```
.
├── k8s/
│   ├── 00-namespace.yaml            # gravitino namespace
│   ├── 01-secrets.yaml              # AWS + OAuth credentials (templates)
│   ├── 02-gravitino-configmap.yaml  # All non-secret config (Hive URI, S3, OAuth settings)
│   ├── 03-gravitino.yaml            # Gravitino Deployment + Services (ClusterIP + NodePort :30901)
│   └── 04-oauth-server.yaml         # OAuth token server Deployment + Services (ClusterIP + NodePort :30902)
├── scripts/
│   └── verify.sh                    # Smoke-test: health, token fetch, authenticated Gravitino calls
└── README.md
```

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

## License

Apache License 2.0 — same license as Apache Gravitino itself.
