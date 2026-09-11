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

if [ "${REBUILD_DATABASE:-false}" = "true" ]; then
  : "${POSTGRES_ROOT_USERNAME:?POSTGRES_ROOT_USERNAME is required when REBUILD_DATABASE=true}"
  : "${POSTGRES_ROOT_PASSWORD:?POSTGRES_ROOT_PASSWORD is required when REBUILD_DATABASE=true}"

  echo "GeoPrism database rebuild mode enabled."
  echo "Lock directory: ${LOCK_DIR}"

  #
  # Rebuild election lock.
  #
  # Only one rebuild task is allowed to become the active builder.
  # This is non-blocking because duplicate ECS tasks should simply
  # sit idle rather than queue up and rebuild the database again later.
  #
  exec 8>"${REBUILD_LOCK}"

  if ! flock -n 8; then
    echo "Another ECS task already owns the database rebuild lock."
    echo "This rebuild task will remain idle."

    exec tail -f /dev/null
  fi

  echo "Database rebuild lock acquired."
  echo "This task is the active database builder."

  #
  # Database-use lock.
  #
  # Normal GeoPrism instances hold a shared lock for their entire
  # lifetime. The database builder requires an exclusive lock.
  #
  # Therefore this blocks until all live GeoPrism application
  # instances have exited.
  #
  exec 9>"${DATABASE_USE_LOCK}"

  echo "Waiting for all live GeoPrism instances to stop..."
  echo "Attempting to acquire exclusive database-use lock."

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
  # Release only the database-use lock.
  #
  # Keep FD 8 / the rebuild election lock for the lifetime of this
  # container. This prevents another duplicate rebuild task from
  # acquiring it after this rebuild finishes and rebuilding again.
  #
  flock -u 9
  exec 9>&-

  echo "Database-use lock released."
  echo "Rebuild task will remain idle."
  echo "The database-rebuild lock will remain held by this container."

  exec tail -f /dev/null
fi

#
# Normal GeoPrism application mode.
#
# Hold a shared database-use lock for the entire lifetime of Tomcat.
# Multiple normal application instances may coexist, but a rebuild
# requiring the exclusive lock cannot begin until they have all exited.
#
exec 9>"${DATABASE_USE_LOCK}"

echo "Acquiring shared database-use lock..."

flock -s 9

echo "Shared database-use lock acquired."
echo "Starting GeoPrism..."

exec "$CATALINA_HOME/bin/catalina.sh" run
