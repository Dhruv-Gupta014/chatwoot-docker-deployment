pipeline {
    agent any

    environment {
        IMAGE_NAME           = "chatwoot"
        IMAGE_TAG            = "${env.BUILD_NUMBER}"
        COMPOSE_PROJECT_NAME = "chatwoot_ci_${env.BUILD_NUMBER}"
    }

    stages {

        stage("Checkout") {
            steps {
                sh "git log --oneline -1"
            }
        }

        stage("Clone Chatwoot Source") {
            steps {
                sh '''
                    git clone --depth=1 https://github.com/chatwoot/chatwoot.git chatwoot-src
                    cp Dockerfile chatwoot-src/dockerfile
                    cp docker/entrypoints/rails.sh chatwoot-src/docker/entrypoints/rails.sh
                '''
            }
        }

        stage("Build Image") {
            steps {
                sh '''
                    cd chatwoot-src
                    docker build -f dockerfile -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest .
                    echo "Built ${IMAGE_NAME}:${IMAGE_TAG} successfully"
                '''
            }
        }

    }

    post {
        always {
            sh "rm -rf chatwoot-src || true"
        }
        success {
            echo "Pipeline passed"
        }
        failure {
            echo "Pipeline failed — check logs"
        }
    }
}
