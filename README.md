# 🐳 Chatwoot Docker Deployment

> A complete DevOps implementation for [Chatwoot](https://github.com/chatwoot/chatwoot) — an open-source customer support platform. This repo documents containerizing a real-world multi-service Rails application using Docker, Docker Compose, and Jenkins CI/CD.

---

## 📌 What is this?

This is a **learning project** built as part of a DevOps curriculum. The goal was to take a production-grade open-source application (Chatwoot) and:

1. Understand its architecture
2. Containerize it using Docker
3. Orchestrate all services with Docker Compose
4. Automate builds and tests with a Jenkins CI/CD pipeline

Everything here is my own DevOps layer on top of the original Chatwoot source code.

---

## 🏗️ Application Architecture

Chatwoot is a multi-service application. Here's what runs under the hood:

```
                        ┌─────────────────────────────────────────┐
                        │           chatwoot-net (bridge)          │
                        │                                          │
  Browser/API  ──HTTP──▶│  ┌─────────────┐    ┌──────────────┐   │
                        │  │ Rails Server │    │   Sidekiq    │   │
                        │  │  :3000       │    │   Worker     │   │
                        │  └──────┬──────┘    └──────┬───────┘   │
                        │         │ SQL               │ SQL        │
                        │         ▼                   ▼            │
                        │  ┌─────────────────────────────────┐    │
                        │  │      PostgreSQL + pgvector       │    │
                        │  │         (port 5432)              │    │
                        │  └─────────────────────────────────┘    │
                        │                                          │
                        │  ┌─────────────────────────────────┐    │
                        │  │            Redis                 │    │
                        │  │  Job Queue │ Pub/Sub │ Cache     │    │
                        │  └─────────────────────────────────┘    │
                        └─────────────────────────────────────────┘
```

### Service breakdown

| Service | Image | Purpose |
|---|---|---|
| `rails` | Custom (our Dockerfile) | HTTP server, REST API, Action Cable WebSockets |
| `sidekiq` | Same image as rails | Background jobs — emails, webhooks, AI processing |
| `postgres` | `pgvector/pgvector:pg16` | Primary database with vector search support |
| `redis` | `redis:7-alpine` | Sidekiq job queue + Action Cable pub/sub + caching |

### Why pgvector and not plain postgres?

Chatwoot uses vector similarity search for AI-powered features (semantic search, smart reply suggestions). The standard `postgres` image doesn't include the `pgvector` extension — using it would cause silent failures on those queries.

### Why does Sidekiq share the same image as Rails?

Sidekiq isn't a separate application — it runs the **same Rails codebase** in worker mode. Sharing one image means:
- One build instead of two
- Models, mailers, and business logic are automatically in sync
- No version mismatch between web and worker

---

## 📁 Repository Structure

```
chatwoot-docker-deployment/
│
├── Dockerfile                      # Multi-stage production build
├── docker-compose.yml              # All services with health checks
├── .env.example                    # Environment variable template
├── Jenkinsfile                     # CI/CD pipeline definition
├── verify.sh                       # Post-deploy smoke test script
│
├── docker/
│   └── entrypoints/
│       └── rails.sh                # Container entrypoint: waits for postgres,
│                                   # runs migrations, starts server
│
└── docs/
    └── architecture.md             # Deep-dive into service design decisions
```

---

## 🐋 Dockerfile — Multi-Stage Build

The Dockerfile uses a **3-stage build** to keep the production image lean:

```
Stage 1 (node)      → pulls Node binary to copy into other stages
Stage 2 (builder)   → installs ALL deps, compiles gems, precompiles assets
Stage 3 (runtime)   → copies only compiled output, no build tools
```

**Why multi-stage?**

A naive single-stage build would include compilers, build tools, and source caches in the final image — easily 2-3GB. The multi-stage approach produces a ~600MB runtime image because build tools never make it to production.

Key decisions:
- `ruby:3.4.4-alpine` base — minimal footprint vs Debian
- `bundle install -j 4` — parallel gem compilation
- Asset precompilation happens in builder, not runtime
- `.git`, `spec/`, `node_modules/` removed before final copy

---

## 🔧 Docker Compose

### Health checks and startup order

Services don't start randomly — startup order is enforced:

```
postgres (healthy) ─┐
                    ├──▶ rails starts
redis (healthy) ────┘
                    └──▶ sidekiq starts
```

Each service has a health check:
- **postgres**: `pg_isready -U $POSTGRES_USERNAME`
- **redis**: `redis-cli ping`
- **rails**: HTTP check on `/auth/sign_in`

### Named volumes

```yaml
volumes:
  postgres_data:   # survives container restarts — your data is safe
  redis_data:      # persists Sidekiq queue across restarts
  storage_data:    # Active Storage files (attachments, avatars)
```

`docker compose down` keeps volumes intact. `docker compose down -v` deletes everything (fresh start).

### Isolated network

All services communicate on `chatwoot-net` (bridge driver). Services reference each other by container name — `rails` connects to postgres at hostname `postgres`, not `localhost`. Postgres and Redis ports are never exposed to the host in production.

---

## ⚙️ Environment Variables

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

Critical variables:

| Variable | How to generate | Purpose |
|---|---|---|
| `SECRET_KEY_BASE` | `openssl rand -hex 64` | Rails encryption key |
| `POSTGRES_PASSWORD` | any strong password | DB auth |
| `REDIS_PASSWORD` | any strong password | Redis auth |
| `FRONTEND_URL` | your domain or `http://localhost:3000` | Absolute URL for links in emails |

⚠️ Never commit `.env` — it's in `.gitignore`.

---

## 🚀 Local Deployment (Quickstart)

### Prerequisites
- Docker 24+
- Docker Compose v2 (plugin, not v1)
- WSL2 Ubuntu (if on Windows) — clone into WSL home, not `/mnt/c/`

### Steps

```bash
# 1. Clone this repo
git clone https://github.com/Dhruv-Gupta014/chatwoot-docker-deployment.git
cd chatwoot-docker-deployment

# 2. Clone the Chatwoot source alongside it
git clone https://github.com/chatwoot/chatwoot.git chatwoot-src

# 3. Copy DevOps files into source
cp Dockerfile chatwoot-src/dockerfile
cp docker-compose.yml chatwoot-src/docker-compose.yml
cp .env.example chatwoot-src/.env.example
cp docker/entrypoints/rails.sh chatwoot-src/docker/entrypoints/rails.sh

# 4. Set up environment
cd chatwoot-src
cp .env.example .env
# Edit .env — set SECRET_KEY_BASE, POSTGRES_PASSWORD, REDIS_PASSWORD

# 5. Build the image
docker compose build

# 6. Start databases first
docker compose up -d postgres redis

# 7. Run DB setup (first time only)
docker compose run --rm rails bundle exec rails db:chatwoot_prepare

# 8. Start everything
docker compose up -d

# 9. Verify
bash verify.sh
```

Open `http://localhost:3000/app/installation/setup` to create your admin account.

### Useful commands

```bash
# Watch live logs
docker compose logs -f rails
docker compose logs -f sidekiq

# Rails console (full app access)
docker compose exec rails bundle exec rails console

# Run a migration
docker compose exec rails bundle exec rails db:migrate

# Stop everything (keeps data)
docker compose down

# Fresh start (deletes all data)
docker compose down -v
```

---

## 🔁 Jenkins CI/CD Pipeline

### Pipeline stages

```
Checkout → Clone Chatwoot Source → Build Image → Test Setup → DB Setup → RSpec
```

| Stage | What happens |
|---|---|
| Checkout | Pulls this repo, logs the commit SHA |
| Clone Chatwoot Source | Clones official chatwoot repo, overlays our Dockerfile |
| Build Image | `docker build` — multi-stage build produces `chatwoot:latest` |
| Test Setup | Starts postgres + redis, patches `.env` for test environment |
| DB Setup | Runs `rails db:chatwoot_prepare` against test DB |
| RSpec | Runs full test suite, outputs results |

### Key design decisions

**`COMPOSE_PROJECT_NAME = "chatwoot_ci_${BUILD_NUMBER}"`**

Each build gets its own isolated containers (`chatwoot_ci_1_postgres`, `chatwoot_ci_2_postgres`, etc.). This means:
- Parallel builds never collide
- CI containers never conflict with your running dev stack
- The `post { always }` block tears them all down after every build

**Jenkins needs Docker socket access**

Jenkins runs in Docker itself, so it needs to talk to the host Docker daemon:
```bash
docker run -v /var/run/docker.sock:/var/run/docker.sock jenkins/jenkins:lts
```

### Setting up Jenkins

1. Jenkins running at `http://localhost:8080`
2. Install plugins: **Docker Pipeline**, **Git**, **Pipeline**
3. New Item → Pipeline → SCM: Git
4. Repo URL: `https://github.com/Dhruv-Gupta014/chatwoot-docker-deployment.git`
5. Script Path: `Jenkinsfile`
6. Build Now

### Auto-triggering on push (webhook)

Jenkins needs to be internet-accessible for GitHub webhooks. On local dev use ngrok:

```bash
ngrok http 8080
# Copy the https URL → GitHub repo → Settings → Webhooks → Add webhook
# Payload URL: https://<ngrok-id>.ngrok.io/github-webhook/
# Content type: application/json
# Event: Just the push event
```

---

## 🧪 Verification

Run the included smoke test after deploy:

```bash
bash verify.sh
```

Checks:
- All containers are running and healthy
- Postgres reachable from rails container
- Redis reachable from rails container  
- HTTP response on `:3000`

---

## 📚 Concepts Covered

| Concept | Where applied |
|---|---|
| Multi-stage Docker builds | `Dockerfile` — 3 stages, lean runtime image |
| Docker networking | `chatwoot-net` bridge, service discovery by name |
| Docker volumes | Named volumes for postgres, redis, storage |
| Docker Compose | Multi-service orchestration with health checks |
| Environment variables | `.env` file, CI overrides via `sed` |
| PostgreSQL | Primary DB with pgvector extension |
| Redis | Job queue + pub/sub + cache |
| Jenkins pipelines | Declarative pipeline with isolated CI environments |
| CI/CD | Automated build + test on every push |
| Tool used - ngrok
| Web hook test and implemented

---

## 🔗 References

- [Chatwoot source](https://github.com/chatwoot/chatwoot)
- [Docker multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [Docker Compose health checks](https://docs.docker.com/compose/how-tos/startup-order/)
- [Sidekiq best practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices)
- [pgvector](https://github.com/pgvector/pgvector)
