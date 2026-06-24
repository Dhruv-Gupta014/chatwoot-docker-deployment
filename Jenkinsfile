pipeline {
    agent any

    environment {
        IMAGE_NAME           = "chatwoot"
        IMAGE_TAG            = "${env.BUILD_NUMBER}"
        COMPOSE_PROJECT_NAME = "chatwoot_ci_${env.BUILD_NUMBER}"
        DEPLOY_PROJECT_NAME  = "chatwoot"
    }

    stages {

        // ── Stage 1: Checkout ─────────────────────────────────────────────
        stage('Checkout') {
            steps {
                sh 'git log --oneline -1'
                sh 'echo "Branch: ${GIT_BRANCH}"'
            }
        }

        // ── Stage 2: Clone Chatwoot source ────────────────────────────────
        // Your repo has the DevOps files (Dockerfile, compose etc)
        // The actual Rails source lives in the official chatwoot repo
        stage('Clone Chatwoot Source') {
            steps {
                sh '''
                    git clone --depth=1 https://github.com/chatwoot/chatwoot.git chatwoot-src
                    cp Dockerfile chatwoot-src/dockerfile
                    cp docker/entrypoints/rails.sh chatwoot-src/docker/entrypoints/rails.sh
                    cp docker-compose.yml chatwoot-src/docker-compose.yml
                    cp .env.example chatwoot-src/.env.example
                '''
            }
        }

        // ── Stage 3: Build Docker image ───────────────────────────────────
        // Multi-stage build — produces chatwoot:<build_number> and chatwoot:latest
        stage('Build Image') {
            steps {
                sh '''
                    cd chatwoot-src
                    docker build \
                        -f dockerfile \
                        -t ${IMAGE_NAME}:${IMAGE_TAG} \
                        -t ${IMAGE_NAME}:latest \
                        .
                    echo "Built ${IMAGE_NAME}:${IMAGE_TAG} successfully"
                '''
            }
        }

        // ── Stage 4: Spin up test dependencies ───────────────────────────
        // Uses COMPOSE_PROJECT_NAME = chatwoot_ci_<build_number>
        // So CI containers never collide with the live deployment on port 3000
        stage('Test Setup') {
            steps {
                sh '''
                    cd chatwoot-src
                    cp .env.example .env
                    sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -hex 64)|" .env
                    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=ci_pass|" .env
                    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=ci_pass|" .env
                    sed -i "s|RAILS_ENV=.*|RAILS_ENV=test|" .env

                    docker compose -p ${COMPOSE_PROJECT_NAME} up -d postgres redis

                    echo "Waiting for postgres to be healthy..."
                    timeout 60 bash -c \
                        "until docker compose -p ${COMPOSE_PROJECT_NAME} exec -T postgres pg_isready; do sleep 2; done"
                    echo "Postgres ready."
                '''
            }
        }

        // ── Stage 5: Database setup ───────────────────────────────────────
        // db:chatwoot_prepare is idempotent — safe to run on every build
        stage('DB Setup') {
            steps {
                sh '''
                    cd chatwoot-src
                    docker compose -p ${COMPOSE_PROJECT_NAME} run --rm \
                        -e RAILS_ENV=test rails \
                        bundle exec rails db:chatwoot_prepare
                '''
            }
        }

        // ── Stage 6: Run tests ────────────────────────────────────────────
        stage('RSpec') {
            steps {
                sh '''
                    cd chatwoot-src
                    docker compose -p ${COMPOSE_PROJECT_NAME} run --rm \
                        -e RAILS_ENV=test rails \
                        bundle exec rspec --format progress
                '''
            }
        }

        // ── Stage 7: Deploy locally ───────────────────────────────────────
        // Only runs if all tests pass
        // Uses fixed project name "chatwoot" — this is the live instance
        // CI used chatwoot_ci_<N> so no port conflicts
        stage('Deploy') {
            steps {
                sh '''
                    cd chatwoot-src

                    # Patch .env for production deployment
                    cp .env.example .env
                    sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -hex 64)|" .env
                    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=devpassword|" .env
                    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=devpassword|" .env
                    sed -i "s|RAILS_ENV=.*|RAILS_ENV=production|" .env
                    sed -i "s|FRONTEND_URL=.*|FRONTEND_URL=http://localhost:3000|" .env

                    # Tear down old deployment gracefully
                    docker compose -p ${DEPLOY_PROJECT_NAME} down || true

                    # Start databases first and wait
                    docker compose -p ${DEPLOY_PROJECT_NAME} up -d postgres redis
                    echo "Waiting for postgres..."
                    timeout 60 bash -c \
                        "until docker compose -p ${DEPLOY_PROJECT_NAME} exec -T postgres pg_isready; do sleep 2; done"

                    # Run migrations
                    docker compose -p ${DEPLOY_PROJECT_NAME} run --rm rails \
                        bundle exec rails db:chatwoot_prepare

                    # Start full stack
                    docker compose -p ${DEPLOY_PROJECT_NAME} up -d

                    echo ""
                    echo "========================================="
                    echo " Chatwoot deployed at http://localhost:3000"
                    echo "========================================="
                '''
            }
        }

    }

    post {
        always {
            // Tear down CI test containers — always, pass or fail
            sh '''
                cd chatwoot-src 2>/dev/null
                docker compose -p ${COMPOSE_PROJECT_NAME} down -v --remove-orphans || true
                cd ..
                rm -rf chatwoot-src || true
            '''
        }
        success {
            echo "CI/CD complete — image ${IMAGE_NAME}:${IMAGE_TAG} built, tested, and deployed."
        }
        failure {
            echo "Pipeline failed — deployment skipped. Check logs above."
        }
    }
}
