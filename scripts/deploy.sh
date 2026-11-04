
#!/bin/bash

set -Eeuo pipefail

# Configuration
NEW_IMAGE="${1:?Usage: deploy.sh <docker-image:tag>}"

APP="fastapi-container"
CANDIDATE="fastapi-candidate"
PREVIOUS="fastapi-previous"

PROMOTION_STARTED=false
DEPLOYMENT_SUCCESS=false

echo "===================================="
echo "Starting deployment: $NEW_IMAGE"
echo "===================================="

# Check container health
wait_for_healthy() {
    local container="$1"
    local status=""

    for attempt in $(seq 1 20); do
        status=$(sudo docker inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$container" 2>/dev/null || true)

        echo "$container health: ${status:-unknown}"

        if [ "$status" = "healthy" ]; then
            return 0
        fi

        if [ "$status" = "unhealthy" ] || [ "$status" = "exited" ]; then
            return 1
        fi

        sleep 3
    done

    return 1
}

# Restore the previous production container
rollback() {
    echo "Deployment failed. Starting rollback..."

    if sudo docker inspect "$PREVIOUS" >/dev/null 2>&1; then
        sudo docker rm -f "$APP" 2>/dev/null || true
        sudo docker rename "$PREVIOUS" "$APP"
    elif sudo docker inspect "$APP" >/dev/null 2>&1; then
        echo "Previous container was not renamed. Restarting it."
    else
        echo "No previous container available for rollback."
        return 1
    fi

    sudo docker start "$APP" || return 1

    if wait_for_healthy "$APP" && \
       curl -fsS http://localhost:8000/health; then
        echo "Rollback successful."
        return 0
    fi

    echo "CRITICAL: Rollback health verification failed."
    return 1
}

# Handle unexpected errors
on_error() {
    local exit_code=$?

    trap - ERR

    echo "Unexpected deployment error: exit code $exit_code"

    if [ "$PROMOTION_STARTED" = true ] && \
       [ "$DEPLOYMENT_SUCCESS" = false ]; then
        rollback || true
    fi

    exit "$exit_code"
}

trap on_error ERR

# 1. Pull the new image
sudo docker pull "$NEW_IMAGE"

# 2. Remove stale candidate
sudo docker rm -f "$CANDIDATE" 2>/dev/null || true

# 3. Start candidate container
sudo docker run -d \
    --name "$CANDIDATE" \
    -p 127.0.0.1:8001:8000 \
    --health-cmd='curl -fsS http://localhost:8000/health || exit 1' \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=3 \
    --health-start-period=5s \
    "$NEW_IMAGE"

# 4. Verify candidate
if ! wait_for_healthy "$CANDIDATE"; then
    echo "Candidate health check failed."
    sudo docker logs "$CANDIDATE" || true
    sudo docker rm -f "$CANDIDATE" || true
    exit 1
fi

echo "Candidate is healthy."

# 5. Preserve current production container
PROMOTION_STARTED=true

sudo docker rm -f "$PREVIOUS" 2>/dev/null || true

if sudo docker inspect "$APP" >/dev/null 2>&1; then
    sudo docker stop "$APP"
    sudo docker rename "$APP" "$PREVIOUS"
fi

# 6. Promote the candidate image
sudo docker rm -f "$CANDIDATE"

sudo docker run -d \
    --name "$APP" \
    --restart unless-stopped \
    -p 8000:8000 \
    --health-cmd='curl -fsS http://localhost:8000/health || exit 1' \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=3 \
    --health-start-period=5s \
    "$NEW_IMAGE"

# 7. Verify production deployment
if ! wait_for_healthy "$APP" || \
   ! curl -fsS http://localhost:8000/health; then

    echo "Production health verification failed."
    rollback
    exit 1
fi

# 8. Remove previous version after success
sudo docker rm -f "$PREVIOUS" 2>/dev/null || true

DEPLOYMENT_SUCCESS=true
trap - ERR

echo "===================================="
echo "Deployment successful!"
echo "Image: $NEW_IMAGE"
echo "===================================="