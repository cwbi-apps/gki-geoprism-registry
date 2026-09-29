#!/bin/sh
set -eu

: "${ORIENTDB_HOST:?ORIENTDB_HOST is required}"
: "${ORIENTDB_PORT:?ORIENTDB_PORT is required}"
: "${ORIENTDB_ROOT_USERNAME:?ORIENTDB_ROOT_USERNAME is required}"
: "${ORIENTDB_ROOT_PASSWORD:?ORIENTDB_ROOT_PASSWORD is required}"

: "${POSTGRES_HOSTNAME:?POSTGRES_HOSTNAME is required}"
: "${POSTGRES_PORT:?POSTGRES_PORT is required}"
: "${DATABASE_USERNAME:?DATABASE_USERNAME is required}"
: "${DATABASE_PASSWORD:?DATABASE_PASSWORD is required}"

#
# Webapp location / context path
#
CONTEXT_NAME="${CONTEXT_NAME:-ROOT}"
WEBAPP_DIR="${CATALINA_HOME}/webapps/${CONTEXT_NAME}"

if [ "${CONTEXT_NAME}" = "ROOT" ]; then
  CONTEXT_PATH=""
else
  # Tomcat uses '#' for nested paths: apps#gpr -> /apps/gpr
  CONTEXT_PATH="/$(printf '%s' "${CONTEXT_NAME}" | tr '#' '/')"
fi

#
# Public URL of the registry (emails, OAuth redirect_uri, links)
#
if [ -z "${GEOPRISM_REMOTE_URL:-}" ]; then
  case "${DEPLOY_ENV:-}" in
    dev)  GEOPRISM_PUBLIC_HOST="https://gki.dev.cwbi.us" ;;
    test) GEOPRISM_PUBLIC_HOST="https://gki-test.cwbi.us" ;;
    prod) GEOPRISM_PUBLIC_HOST="https://gki.cwbi.us" ;;
    *)
      echo "ERROR: Set GEOPRISM_REMOTE_URL, or DEPLOY_ENV to dev|test (got '${DEPLOY_ENV:-}')."
      exit 1
      ;;
  esac

  GEOPRISM_REMOTE_URL="${GEOPRISM_PUBLIC_HOST}${CONTEXT_PATH}/"
fi

# Read by the rebuild-mode health server (jshell)
export CONTEXT_PATH

echo "Context path:        ${CONTEXT_PATH:-/}"
echo "geoprism.remote.url: ${GEOPRISM_REMOTE_URL}"

LOCK_DIR="/data/geoprism/locks"
REBUILD_LOCK="${LOCK_DIR}/database-rebuild.lock"
DATABASE_USE_LOCK="${LOCK_DIR}/database-use.lock"

HEALTH_STATUS_FILE="/tmp/database-rebuild-status"

mkdir -p "${LOCK_DIR}"

command -v flock >/dev/null 2>&1 || {
  echo "ERROR: flock is required but is not installed."
  exit 1
}

ORIENTDB_URL="$ORIENTDB_HOST"

case "$ORIENTDB_URL" in
  *:*) ;;
  *) ORIENTDB_URL="remote:$ORIENTDB_URL" ;;
esac

CATALINA_OPTS="${CATALINA_OPTS:-}"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.db.url=${ORIENTDB_URL}"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.port=${ORIENTDB_PORT}"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.root.username=${ORIENTDB_ROOT_USERNAME}"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.root.password=${ORIENTDB_ROOT_PASSWORD}"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.admin.username=georegistry"
CATALINA_OPTS="${CATALINA_OPTS} -Dorientdb.admin.password=${ORIENTDB_ROOT_PASSWORD}"
CATALINA_OPTS="${CATALINA_OPTS} -Ddatabase.hostURL=${POSTGRES_HOSTNAME}"
CATALINA_OPTS="${CATALINA_OPTS} -Ddatabase.port=${POSTGRES_PORT}"
CATALINA_OPTS="${CATALINA_OPTS} -Ddatabase.user=${DATABASE_USERNAME}"
CATALINA_OPTS="${CATALINA_OPTS} -Ddatabase.password=${DATABASE_PASSWORD}"
CATALINA_OPTS="${CATALINA_OPTS} -Dgeoprism.origin=gki.cwbi.us"
CATALINA_OPTS="${CATALINA_OPTS} -Dmapboxgl.accessToken=${MAPBOX_KEY:-}"
CATALINA_OPTS="${CATALINA_OPTS} -Dgeoprism.remote.url=${GEOPRISM_REMOTE_URL}"

export CATALINA_OPTS

start_health_server() {
  echo "Starting rebuild health-check server on port 8080..."

  jshell --add-modules jdk.httpserver <<'EOF' &
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

var server = HttpServer.create(new InetSocketAddress(8080), 0);

HttpHandler health = exchange -> {
    byte[] response =
        "{\"status\":\"UP\"}\n".getBytes(StandardCharsets.UTF_8);

    exchange.getResponseHeaders()
        .set("Content-Type", "application/json");

    exchange.sendResponseHeaders(200, response.length);

    try (var os = exchange.getResponseBody()) {
        os.write(response);
    }
};

// Health checks may arrive at the root or under the context path (e.g. /gpr/actuator/health)
server.createContext("/actuator/health", health);

var contextPath = System.getenv().getOrDefault("CONTEXT_PATH", "");

if (!contextPath.isEmpty()) {
    server.createContext(contextPath + "/actuator/health", health);
}

// Everything else (/, /gpr/, /gpr/cgr/manage, ...) gets the rebuild status message
server.createContext("/", exchange -> {
    String message;

    try {
        message = Files.readString(
            Path.of("/tmp/database-rebuild-status")
        );
    } catch (Exception e) {
        message = "Database rebuild task is running.\n";
    }

    byte[] response =
        message.getBytes(StandardCharsets.UTF_8);

    exchange.getResponseHeaders()
        .set("Content-Type", "text/plain");

    exchange.sendResponseHeaders(200, response.length);

    try (var os = exchange.getResponseBody()) {
        os.write(response);
    }
});

server.start();

System.out.println(
    "Health-check server listening on port 8080."
);

Thread.currentThread().join();
EOF

  HEALTH_SERVER_PID=$!

  echo "Health-check server PID: ${HEALTH_SERVER_PID}"
}

if [ "${REBUILD_DATABASE:-false}" = "true" ]; then
  : "${POSTGRES_ROOT_USERNAME:?POSTGRES_ROOT_USERNAME is required when REBUILD_DATABASE=true}"
  : "${POSTGRES_ROOT_PASSWORD:?POSTGRES_ROOT_PASSWORD is required when REBUILD_DATABASE=true}"

  echo "GeoPrism database rebuild mode enabled."
  echo "Lock directory: ${LOCK_DIR}"

  #
  # Elect exactly one rebuild task.
  #
  exec 8<>"${REBUILD_LOCK}"

  if ! flock -n 8; then
    echo "Another ECS task already owns the database rebuild lock."
    echo "This task will NOT rebuild the database."
    echo "This task will NOT respond to health checks."
    echo "Exiting."

    exit 0
  fi

  echo "Database rebuild lock acquired."
  echo "This task is the active database builder."

  #
  # IMPORTANT:
  #
  # Become healthy BEFORE waiting for the currently-running
  # GeoPrism task to terminate.
  #
  # ECS may require this task to become healthy before stopping
  # the previous task.
  #
  printf '%s\n' \
    "Database rebuild in progress. Please wait..." \
    > "${HEALTH_STATUS_FILE}"

  start_health_server

  #
  # Acquire exclusive access to the database.
  #
  # Normal GeoPrism instances hold this lock shared, so this
  # waits until ECS terminates/drains the old application task.
  #
  exec 9<>"${DATABASE_USE_LOCK}"

  echo "Waiting for all live GeoPrism instances to stop..."
  echo "Attempting to acquire exclusive database-use lock..."

  flock 9

  echo "Exclusive database-use lock acquired."
  echo "No live GeoPrism instances are using the database."
  echo "Rebuilding GeoPrism database..."

  java ${CATALINA_OPTS} \
    -cp "${WEBAPP_DIR}/WEB-INF/classes:${WEBAPP_DIR}/WEB-INF/lib/*" \
    net.geoprism.build.GeoprismDatabaseBuilder \
    "${WEBAPP_DIR}/WEB-INF/classes/metadata" \
    --rootUser="${POSTGRES_ROOT_USERNAME}" \
    --rootPass="${POSTGRES_ROOT_PASSWORD}" \
    --templateDb=postgres \
    --clean=true \
    --install=true

  echo "Database rebuild complete."

  #
  # The destructive work is finished.
  # Release exclusive DB access.
  #
  flock -u 9
  exec 9>&-

  echo "Database-use lock released."

  printf '%s\n' \
    "Database rebuild complete! Please launch a standard deploy." \
    > "${HEALTH_STATUS_FILE}"

  echo "Database rebuild task is complete."
  echo "Waiting for a standard deployment."
  echo "Health-check server will remain running."

  #
  # Keep PID 1 alive and continue holding FD 8, which owns the
  # rebuild lock.
  #
  wait "${HEALTH_SERVER_PID}"

  exit 1
fi

#
# Normal application mode.
#
exec 9<>"${DATABASE_USE_LOCK}"

echo "Acquiring shared database-use lock..."

flock -s 9

echo "Shared database-use lock acquired."
echo "Starting GeoPrism..."

exec "$CATALINA_HOME/bin/catalina.sh" run
