pipeline {
    agent any
    options { timestamps() }

    environment {
        SERVICE_DIR = '.'
        IMAGE_NAME = 'open-products-catalog-service:' + (env.GIT_COMMIT ?: 'local')
        STRICT_DEPRECATED_ROOTS = 'true'
    }

    stages {
        stage('Validate Workspace') {
            steps {
                sh '''
                  set -euo pipefail
                  test -f "${SERVICE_DIR}/build.gradle"
                  test -x ./gradlew
                '''
            }
        }
        stage('Repository Governance') {
            steps {
                sh '''
                  set -euo pipefail
                  export STRICT_DEPRECATED_ROOTS="${STRICT_DEPRECATED_ROOTS:-true}"
                  bash tools/validation/validate-repo-governance.sh

                  python3 -m venv .venv-validation
                  . .venv-validation/bin/activate
                  python -m pip install --upgrade pip coverage
                  python -m coverage run --source=tools/validation -m unittest discover -s tools/validation/tests -p 'test_*.py'
                  python -m coverage report --include='*/repo_governance_validator.py' --fail-under=90
                '''
            }
        }
        stage('Quality Gate') {
            steps {
                // The PostgreSQL integration tests fail (not skip) under Jenkins
                // without TEST_DB_URL, so provide a throwaway postgres:16 unless
                // the agent already supplies TEST_DB_URL.
                sh '''
                  set -euo pipefail
                  if [ -z "${TEST_DB_URL:-}" ]; then
                    if ! command -v docker >/dev/null 2>&1; then
                      echo "Quality Gate needs PostgreSQL: set TEST_DB_URL/TEST_DB_USERNAME/TEST_DB_PASSWORD or install docker on the agent" >&2
                      exit 1
                    fi
                    db_container="products-qg-${BUILD_TAG:-local}-$$"
                    db_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')"
                    trap 'docker rm -f "$db_container" >/dev/null 2>&1 || true' EXIT
                    docker run -d --name "$db_container" -p 127.0.0.1::5432 \\
                      -e POSTGRES_DB=db_of_open_products_catalog_test \\
                      -e POSTGRES_USER=open_products_test \\
                      -e POSTGRES_PASSWORD="$db_secret" postgres:16-alpine >/dev/null
                    for _ in $(seq 1 60); do
                      docker exec "$db_container" pg_isready -U open_products_test -d db_of_open_products_catalog_test >/dev/null 2>&1 && break
                      sleep 1
                    done
                    docker exec "$db_container" pg_isready -U open_products_test -d db_of_open_products_catalog_test
                    db_port="$(docker port "$db_container" 5432/tcp | head -n 1 | sed 's/.*://')"
                    export TEST_DB_URL="jdbc:postgresql://127.0.0.1:${db_port}/db_of_open_products_catalog_test"
                    export TEST_DB_USERNAME=open_products_test
                    export TEST_DB_PASSWORD="$db_secret"
                  fi
                  ./gradlew -p "${SERVICE_DIR}" --no-daemon clean check
                '''
            }
        }
        stage('Security Gate') {
            steps {
                sh '''
                  set -euo pipefail
                  mkdir -p "${SERVICE_DIR}/build/reports/security"
                  ./gradlew -p "${SERVICE_DIR}" --no-daemon dependencies > "${SERVICE_DIR}/build/reports/security/dependencies.txt"
                  command -v trivy >/dev/null 2>&1
                  trivy fs --exit-code 1 --severity HIGH,CRITICAL "${SERVICE_DIR}"
                  command -v gitleaks >/dev/null 2>&1
                  gitleaks detect --no-git --source "${SERVICE_DIR}" --exit-code 1
                '''
            }
        }
        stage('Build Image') {
            steps {
                sh '''
                  set -euo pipefail
                  if command -v docker >/dev/null 2>&1; then
                    # Root Dockerfile builds from source (see deploy/helm for the chart).
                    docker build -t "${IMAGE_NAME}" "${SERVICE_DIR}"
                  else
                    echo "docker not installed; skipping image build"
                  fi
                '''
            }
        }
        stage('Sign & Publish Image') {
            when {
                expression { return env.PUBLISH_IMAGE == 'true' }
            }
            steps {
                sh '''
                  set -euo pipefail

                  if command -v cosign >/dev/null 2>&1 && [ -n "${COSIGN_KEY:-}" ]; then
                    cosign sign --key "${COSIGN_KEY}" "${IMAGE_NAME}"
                  else
                    echo "cosign key not configured; skipping image signing"
                  fi

                  if command -v docker >/dev/null 2>&1 && [ -n "${DOCKER_REGISTRY:-}" ] && [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ]; then
                    echo "${DOCKER_PASSWORD}" | docker login "${DOCKER_REGISTRY}" --username "${DOCKER_USERNAME}" --password-stdin
                    docker push "${IMAGE_NAME}"
                  else
                    echo "registry credentials not configured; skipping image publish"
                  fi
                '''
            }
        }
    }
}
