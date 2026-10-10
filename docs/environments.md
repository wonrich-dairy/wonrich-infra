# Environments

Every service runs in two environments, **staging** and **production**, with nothing shared that could let a staging test touch production data (SCRUM-121). This page is the reference for the layout and for what exists today. Situation as of 2026-10-10.

---

## The layout

| Resource | Staging | Production |
|---|---|---|
| Branch that deploys | `develop` | `main` |
| App Service | the existing staging app of the service | a separate app, normally with a `-prod` suffix |
| `ASPNETCORE_ENVIRONMENT` | `Staging` | `Production` |
| Database | the service's database | a separate database with a `_prod` suffix and its own user, on the same MySQL server |
| Kafka broker | port `9094` | separate broker on the same VM, port `9095` |
| GitHub environment | `staging` | `production`, limited to `main`, with required reviewers |
| Container image tag the app follows | `latest` | `production` (the image already tested on staging, never rebuilt) |
| Swagger UI | on | off |
| Migrations | applied by the service on startup | applied from the pipeline's `migrations.sql` artifact before the deploy, never by hand |

Secrets live in App Service settings and GitHub environment secrets, never in source. Configuration is read at runtime, not at build time. Access to production configuration is limited to the DevOps role holder.

Production uses the same Auth service as staging (`wonrich-auth-app`), so every production app needs the same signing key as staging. This is a known limitation of the case-study environment.

---

## Services

| Service | Staging | Production |
|---|---|---|
| Traceability | `wonrich-traceability`, https://wonrich-traceability-hhfsh9d4cff6gsd3.southeastasia-01.azurewebsites.net | `wonrich-traceability-prod`, https://wonrich-traceability-prod-hcagaah2exc9frbj.southeastasia-01.azurewebsites.net |
| Quality Lab | `wonrich-quality-lab`, https://wonrich-quality-lab-bvega5acfkgpb5gx.southeastasia-01.azurewebsites.net | not created yet |
| Processing | `app-wonrich-processing-staging`, https://app-wonrich-processing-staging.azurewebsites.net | `app-wonrich-processing-prod`, https://app-wonrich-processing-prod.azurewebsites.net |
| MCC and Intake | `app-mcc-intake-staging`, https://app-mcc-intake-staging.azurewebsites.net | `app-mcc-intake-prod`, https://app-mcc-intake-prod.azurewebsites.net |
| Auth | `wonrich-auth-app`, https://wonrich-auth-app-f4dndrgcgzgjb5h4.malaysiawest-01.azurewebsites.net (shared by both environments) | same app |
| Frontend | https://frontend-phi-sage-81.vercel.app (hosted on Vercel) | same project |

### How each service deploys

Not every service deploys the same way. The difference is known and accepted for this sprint.

| Service | Method | Production approval | Rollback |
|---|---|---|---|
| Traceability | Container image in `wonrichtrcacr.azurecr.io`, pulled by App Service through a registry webhook. The production image is the one staging tested, retagged | `production` GitHub environment | `Rollback` workflow with `environment` and `image_tag` |
| Quality Lab | Container image in `wonrichacr`, same pattern, staging only so far | | `Rollback` workflow |
| Processing | Zip deploy with a publish profile; production is rebuilt from `main` | `production` GitHub environment | redeploy the previous successful run |
| MCC and Intake | Zip deploy with a publish profile; production is rebuilt from `main` | `production` GitHub environment | redeploy the previous successful run |
| Auth | Container image in `wonrichauthcontainer`, deployed from `main` | none | re-run the workflow for an earlier commit |

Processing and MCC rebuild production from `main` instead of promoting the staging image. The minimum standard for every service is a production GitHub environment with required reviewers, a health check after the deploy, and a documented rollback.

### What each service reports

| Service | `/health` | `/version` |
|---|---|---|
| Traceability | JSON, checks `mysql` and `kafka` | commit SHA |
| Quality Lab | JSON, checks `mysql` and `kafka` | commit SHA |
| Processing | JSON, checks `database` and `kafka` (staging) | not available |
| MCC and Intake | not available | not available |
| Auth | not available | not available |

`scripts/verify-health.sh` in the Traceability repository takes the database check name in `HEALTH_DB_CHECK` and skips the `/version` wait when no commit is given, so it covers both shapes.

---

## Databases

One MySQL server, `wonrichmysql.mysql.database.azure.com` (Azure Database for MySQL Flexible Server, Southeast Asia), with one database and one user per service and environment. Every user can only reach its own database, and connections require SSL. Passwords are shared privately.

| Service | Staging database and user | Production database and user |
|---|---|---|
| Traceability | `traceability`, `trc_app` | `traceability_prod`, `trc_app_prod` |
| Quality Lab | `quality_lab`, `qls_app` | `quality_lab_prod`, `qls_app_prod` |
| Processing | `processingdb`, `processingdb_app` | `processingdb_prod`, `processingdb_app_prod` |
| MCC and Intake, Auth | `mccdb`, `mccdb_app` | `mccdb_prod`, `mccdb_app_prod` |

Processing also has `processingdb_test` with `processingdb_test_app`. Quality Lab reads Processing's database for its processing sync; that needs a read-only user limited to the tables it reads.

`azure/mysql/create-databases.sh` creates the Traceability databases and the production databases of the other services.

---

## Kafka

Two independent brokers on the VM `vm-wonrich-kafka` (host `wonrich-kafka.southeastasia.cloudapp.azure.com`), so a staging test can never put an event into production. Details and the topic list are in [kafka.md](kafka.md).

| | Staging | Production |
|---|---|---|
| Bootstrap | `wonrich-kafka.southeastasia.cloudapp.azure.com:9094` | `wonrich-kafka.southeastasia.cloudapp.azure.com:9095` |
| Dead-letter retention | 7 days | 30 days |

Topic names are the same on both, so only the bootstrap address and password change between environments.

---

## Observability

Prometheus and Grafana for staging run on the same VM, bound to localhost, and are reached through an SSH tunnel. They are deployed by `infra/observability/staging/deploy.sh` in the Processing repository. The whole platform, including its local monitoring stack, starts from `docker-compose.stack.yml` (see the [README](../README.md)).

---

## Where things live

| Resource | Where |
|---|---|
| MySQL server `wonrichmysql`, registry `wonrichtrcacr` | the DevOps member's Azure subscription, resource group `rg-wonrich` |
| Traceability App Services | a separate Azure for Students subscription of the DevOps member, resource group `rg-traceability`, each on its own free F1 plan |
| Kafka VM, staging Prometheus and Grafana, Quality Lab, registry `wonrichacr` | the Quality Lab and Kafka owner's subscription |

How the Traceability apps were created is in the Traceability repository, `docs/azure-setup.md`.

---

## Verifying an environment

```bash
curl https://<app host>/version      # the commit that is running
curl https://<app host>/health       # status, with the mysql (or database) and kafka checks
```

A healthy database check only passes when the connection string resolved from the App Service settings, the scoped user could open its database, and the schema is up to date.
