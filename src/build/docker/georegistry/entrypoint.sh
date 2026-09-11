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

LOCK_DIR="/data/geoprism/locks"
REBUILD_LOCK="${LOCK_DIR}/database-rebuild.lock"
DATABASE_USE_LOCK="${LOCK_DIR}/database-use.lock"

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
CATALINA_OPTS="${CATALINA_OPTS} -Dgeoprism.origin=gki-gpr.dev.cwbi.us"

export CATALINA_OPTS

start_health_server() {
  echo "Starting health-check server on port 8080..."

  exec jshell --add-modules jdk.httpserver <<'EOF'
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

var server = HttpServer.create(new InetSocketAddress(8080), 0);

server.createContext("/actuator/health", exchange -> {
    byte[] response = "{\"status\":\"UP\"}\n".getBytes(StandardCharsets.UTF_8);

    exchange.getResponseHeaders().set("Content-Type", "application/json");

    exchange.sendResponseHeaders(200, response.length);

    try (var os = exchange.getResponseBody()) {
        os.write(response);
    }
});
server.createContext("/", exchange -> {
    byte[] response =
        "Database rebuild complete! Please launch a standard deploy.\n"
            .getBytes(StandardCharsets.UTF_8);

    exchange.getResponseHeaders().set("Content-Type", "text/plain");
    exchange.sendResponseHeaders(200, response.length);

    try (var os = exchange.getResponseBody()) {
        os.write(response);
    }
});

server.start();

System.out.println("Health-check server listening on port 8080.");

Thread.currentThread().join();
EOF
}

if [ "${REBUILD_DATABASE:-false}" = "true" ]; then
  : "${POSTGRES_ROOT_USERNAME:?POSTGRES_ROOT_USERNAME is required when REBUILD_DATABASE=true}"
  : "${POSTGRES_ROOT_PASSWORD:?POSTGRES_ROOT_PASSWORD is required when REBUILD_DATABASE=true}"

  echo "GeoPrism database rebuild mode enabled."
  echo "Lock directory: ${LOCK_DIR}"

  #
  # Only one rebuild task is allowed to perform the rebuild.
  #
  # FD 8 remains open for the lifetime of this container.
  #
  exec 8>"${REBUILD_LOCK}"

  if ! flock -n 8; then
    echo "Another ECS task already owns the database rebuild lock."
    echo "This task will not rebuild the database."
    echo "Starting health-check server instead."

    start_health_server
  fi

  echo "Database rebuild lock acquired."
  echo "This task is the active database builder."

  #
  # Acquire the database-use lock exclusively.
  #
  # Normal GeoPrism instances hold this lock in shared mode.
  # This call therefore waits until all currently-running application
  # instances have exited.
  #
  exec 9>"${DATABASE_USE_LOCK}"

  echo "Waiting for all live GeoPrism instances to stop..."
  echo "Attempting to acquire exclusive database-use lock..."

  flock 9

  echo "Exclusive database-use lock acquired."
  echo "No live GeoPrism instances are using the database."
  echo "Rebuilding GeoPrism database..."

  java ${CATALINA_OPTS} \
    -cp "${CATALINA_HOME}/webapps/ROOT/WEB-INF/classes:${CATALINA_HOME}/webapps/ROOT/WEB-INF/lib/*" \
    net.geoprism.build.GeoprismDatabaseBuilder \
    "${CATALINA_HOME}/webapps/ROOT/WEB-INF/classes/metadata" \
    --rootUser="${POSTGRES_ROOT_USERNAME}" \
    --rootPass="${POSTGRES_ROOT_PASSWORD}" \
    --templateDb=postgres \
    --clean=true \
    --install=true

  echo "Database rebuild complete."

  #
  # Release the exclusive database-use lock.
  #
  # Keep FD 8 open so this task continues to own the rebuild-election
  # lock until the container itself is terminated.
  #
  flock -u 9
  exec 9>&-

  echo "Database-use lock released."
  echo "Database rebuild task is complete."
  echo "This task will remain alive only to satisfy health checks."

  start_health_server
fi

#
# Normal application mode.
#
# Every normal GeoPrism instance holds a shared lock for its entire
# lifetime. Multiple application instances may coexist, but the
# database builder cannot acquire its exclusive lock until all of them
# have exited.
#
exec 9>"${DATABASE_USE_LOCK}"

echo "Acquiring shared database-use lock..."

flock -s 9

echo "Shared database-use lock acquired."
echo "Starting GeoPrism..."

exec "$CATALINA_HOME/bin/catalina.sh" run
