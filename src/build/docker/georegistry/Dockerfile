#
#
#

FROM tomcat:11-jdk25

# Ubuntu 26.04 base images ship Canonical's pebble (Go binary, unused here, flagged for go/stdlib CVEs) - drop it
# and pick up any pending OS security updates
RUN rm -f /usr/bin/pebble \
 && apt-get update && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

ENV CGR_VERSION=LATEST
ENV LOG_LEVEL=error
ENV POSTGRES_PORT=5432

# CWBI - Support Arbitrary context paths
ARG CONTEXT_NAME=ROOT
ARG DEPLOY_ENV=
ENV CONTEXT_NAME=$CONTEXT_NAME \
    DEPLOY_ENV=$DEPLOY_ENV

# CWBI - Rebuild database
ARG REBUILD_DATABASE=false
ENV REBUILD_DATABASE=${REBUILD_DATABASE}

RUN mkdir -p $CATALINA_HOME/wars

# Copy CGR WAR
COPY target/georegistry.war $CATALINA_HOME/wars/geoprism.war

# Deploy CGR War
RUN mkdir -p $CATALINA_HOME/wars/geoprism && cd $CATALINA_HOME/wars/geoprism && $JAVA_HOME/bin/jar xf $CATALINA_HOME/wars/geoprism.war \
 && rm $CATALINA_HOME/wars/geoprism.war
RUN mv $CATALINA_HOME/wars/geoprism $CATALINA_HOME/webapps/$CONTEXT_NAME

# Log4j properties
ADD https://raw.githubusercontent.com/terraframe/geoprism-cloud/dev/ansible/roles/webserver/files/log4j2.xml $CATALINA_HOME/webapps/$CONTEXT_NAME/WEB-INF/classes/log4j2.xml
RUN sed -i -e "s/<Root level=\"error\">/<Root level=\"$LOG_LEVEL\">/g" $CATALINA_HOME/webapps/$CONTEXT_NAME/WEB-INF/classes/log4j2.xml

# Pre-load with a default appcfg
COPY target/appcfg $CATALINA_HOME/appcfg

ADD https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh $CATALINA_HOME/bin/wait-for-it.sh
RUN chmod +x $CATALINA_HOME/bin/wait-for-it.sh

# Send Tomcat localhost logs to container stderr/stdout so ECS can capture them
RUN sed -i \
    's|org.apache.catalina.core.ContainerBase.\[Catalina\].\[localhost\].handlers = 2localhost.org.apache.juli.AsyncFileHandler|org.apache.catalina.core.ContainerBase.[Catalina].[localhost].handlers = java.util.logging.ConsoleHandler|' \
    $CATALINA_HOME/conf/logging.properties

COPY entrypoint.sh /usr/local/bin/geoprism-entrypoint.sh
RUN chmod +x /usr/local/bin/geoprism-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/geoprism-entrypoint.sh"]
