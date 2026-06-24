# Architecture Deep Dive

## How a message flows through Chatwoot

Understanding the data flow helps explain why each service exists.

### Inbound message (customer sends a message)

```
1. Customer sends message via widget/email/WhatsApp
2. Rails receives webhook/HTTP request
3. Rails creates/updates Conversation + Message in PostgreSQL
4. Rails enqueues a Sidekiq job into Redis
   - "notify_agents" job
   - "send_email_notification" job
5. Rails broadcasts over Action Cable (Redis pub/sub)
   → All connected agent browsers get real-time update instantly
6. Sidekiq picks up jobs from Redis queue
   → Sends email notification to agent
   → Triggers any configured webhooks
```

### Why Redis is used for TWO different things

**As a job queue (Sidekiq):**
- Rails pushes a JSON job descriptor into a Redis list
- Sidekiq polls that list in a loop
- Workers pop jobs and execute them
- Redis acts as a durable message broker

**As pub/sub (Action Cable):**
- Rails publishes a message to a Redis channel
- All Rails processes subscribed to that channel receive it
- They push it over WebSocket to connected browsers
- This is how multiple Rails instances stay in sync

If you only had one Rails process, you could do pub/sub in-process. Redis makes it work across multiple instances.

## Why Sidekiq doesn't expose any ports

Sidekiq is a **pull-based** worker — it reaches out to Redis to get jobs. Nothing reaches into Sidekiq. This is why:
- No `ports:` in the compose service
- No health check URL
- It just needs network access to Redis and Postgres

## PostgreSQL + pgvector

Standard Postgres stores structured relational data. Chatwoot adds `pgvector` to store **embeddings** — high-dimensional float vectors that represent the semantic meaning of text.

This enables:
- "Similar conversations" suggestions
- Semantic search across message history
- AI-powered smart reply

Without pgvector, these features fail silently or error on startup.

## The entrypoint script (rails.sh)

The entrypoint does three things before starting the server:

```bash
# 1. Wait for postgres
until pg_isready -h $POSTGRES_HOST; do sleep 1; done

# 2. Run migrations (safe to run on every start)
bundle exec rails db:chatwoot_prepare

# 3. Start the server
exec bundle exec rails s -p 3000 -b 0.0.0.0
```

`db:chatwoot_prepare` is idempotent — if the DB is already set up it just runs pending migrations and exits. This means you never need to manually run migrations after deploys.

## Container networking — why services use hostnames not IPs

In docker-compose, every service is reachable by its **service name** as a hostname within the network:

```yaml
# In .env
POSTGRES_HOST=postgres    # resolves to the postgres container's IP
REDIS_URL=redis://redis:6379  # resolves to the redis container's IP
```

Docker's embedded DNS server handles this automatically. IPs can change when containers restart — hostnames don't.

## Volume strategy

| Volume | Mount point | What's stored |
|---|---|---|
| `postgres_data` | `/var/lib/postgresql/data` | All database files |
| `redis_data` | `/data` | Redis RDB snapshots (persisted queue) |
| `storage_data` | `/app/storage` | Uploaded files via Active Storage |

Both `rails` and `sidekiq` mount `storage_data` because Sidekiq jobs may need to read or process uploaded files (e.g. image resizing, attachment processing).
