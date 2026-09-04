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

if [ "${REBUILD_DATABASE:-false}" = "true" ]; then
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
  echo "This is a rebuild-only image. Deploy a normal image to start GeoPrism."

  exec tail -f /dev/null
fi

export CATALINA_OPTS

echo "Starting GeoPrism..."
exec "$CATALINA_HOME/bin/catalina.sh" run
