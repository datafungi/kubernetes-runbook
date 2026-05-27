# Apache Airflow

CeleryExecutor deployment using the official Apache Airflow Helm chart.
DAGs are loaded via GitSync (SSH). All secrets are managed through OpenBao and ESO.

## Environments

| Directory | Environment     |
|-----------|-----------------|
| `k3d/`    | Local dev (k3d) |
