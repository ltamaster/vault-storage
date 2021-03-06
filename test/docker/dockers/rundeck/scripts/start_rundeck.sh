#!/bin/bash

#exit on error
set -e

#Fix folder permissions
sudo chown -R $USERNAME:$USERNAME $HOME;


start_rundeck(){


  # (start rundeck)
  $HOME/server/sbin/rundeckd start

  echo "started rundeck"

  # Wait for server to start
  SUCCESS_MSG="Started ServerConnector@"
  MAX_ATTEMPTS=30
  SLEEP=10

  echo "Waiting for $RUNDECK_NODE to start. This will take about 2 minutes... "

  declare -i count=0
  while (( count <= MAX_ATTEMPTS ))
  do
      if ! [ -f "$LOGFILE" ]
      then  echo "Waiting. hang on..."; # output a progress character.
      elif ! grep "${SUCCESS_MSG}" "$LOGFILE" ; then
        echo "Still working. hang on..."; # output a progress character.
      else  break; # found successful startup message.
      fi
      (( count += 1 ))  ; # increment attempts counter.
      (( count == MAX_ATTEMPTS )) && {
          echo >&2 "FAIL: Reached max attempts to find success message in logfile. Exiting."
          exit 1
      }
      tail -n 5 "$LOGFILE"
      $HOME/server/sbin/rundeckd status || {
          echo >&2 "FAIL: rundeckd is not running. Exiting."
          exit 1
      }
      echo "."
      sleep $SLEEP; # wait before trying again.

  done
  echo "RUNDECK NODE $RUNDECK_NODE started successfully!!"


}

# helper function

run_helpers() {
  local -r helper=$1
  local -a scripts=( ${@:2} )

  for script in "${scripts[@]}"
  do
      [[ ! -f "$script" ]] && {
          echo >&2 "WARN: $helper script not found. skipping: '$script'"
          continue
      }
      echo "### applying $helper script: $script"
      . "$script"
  done
}

setup_ssl(){
  local FARGS=("$@")
  local DIR=${FARGS[0]}
  TRUSTSTORE=$DIR/etc/truststore
  KEYSTORE=$DIR/etc/keystore
  if [ ! -f $TRUSTSTORE ]; then
     echo "=>Generating ssl cert"
     sudo -u rundeck keytool -keystore $KEYSTORE -alias $RUNDECK_NODE -genkey -keyalg RSA \
      -keypass adminadmin -storepass adminadmin -dname "cn=$RUNDECK_NODE, o=test, o=rundeck, o=org, c=US" && \
     cp $KEYSTORE $TRUSTSTORE
  fi

cat >> $HOME/etc/profile <<END
export RDECK_JVM="$RDECK_JVM -Drundeck.ssl.config=$DIR/server/config/ssl.properties -Dserver.https.port=$RUNDECK_PORT"
END
}


setup_project(){
  local FARGS=("$@")
  local DIR=${FARGS[0]}
  local PROJ=${FARGS[1]}
  echo "setup test project: $PROJ in dir $DIR"
  mkdir -p $DIR/projects/$PROJ/etc
  cat >$DIR/projects/$PROJ/etc/project.properties<<END
project.name=$PROJ
project.nodeCache.delay=30
project.nodeCache.enabled=true
project.ssh-authentication=privateKey
#project.ssh-keypath=
resources.source.1.config.file=$DIR/projects/\${project.name}/etc/resources.xml
resources.source.1.config.format=resourcexml
resources.source.1.config.generateFileAutomatically=true
resources.source.1.config.includeServerNode=true
resources.source.1.config.requireFileExists=false
resources.source.1.type=file
service.FileCopier.default.provider=jsch-scp
service.NodeExecutor.default.provider=jsch-ssh
END
}

append_project_config(){
  local FARGS=("$@")
  local DIR=${FARGS[0]}
  local PROJ=${FARGS[1]}
  local FILE=${FARGS[2]}
  echo "Append config for test project: $PROJ in dir $DIR"

  cat >>$DIR/projects/$PROJ/etc/project.properties< $FILE
}

echo "######### start_rundeck on $RUNDECK_NODE ######### "
if test -f $HOME/resources/$RUNDECK_NODE.ready ; then
  echo "Already started, skipping..."
  exit 0
fi


# Some Cleanup
rm -rfv $HOME/server/logs/*
rm -fv $HOME/testdata/*


export RDECK_BASE=$HOME
LOGFILE=$RDECK_BASE/var/log/service.log
mkdir -p $(dirname $LOGFILE)
FWKPROPS=$HOME/etc/framework.properties
mkdir -p $(dirname $FWKPROPS)
export RUNDECK_PORT=4440
if [ -n "$SETUP_SSL" ] ; then
  export RUNDECK_PORT=4443
  export RUNDECK_URL=https://$RUNDECK_NODE:$RUNDECK_PORT
fi

# Configure general stuff.
# configure hostname, nodename, url

# RUN TEST PRESTART SCRIPT
if [[ -n "$CONFIG_SCRIPT_PRESTART" ]]
then
  config_scripts=( ${CONFIG_SCRIPT_PRESTART//,/ } )

  run_helpers "prestart" "${config_scripts[@]}"
else
  echo "### Prestart config not set. skipping..."
fi


cat > $FWKPROPS <<END
framework.server.name = $RUNDECK_NODE
framework.server.hostname = $RUNDECK_NODE
framework.server.port = $RUNDECK_PORT
framework.server.url = $RUNDECK_URL
# ----------------------------------------------------------------
# Installation locations
# ----------------------------------------------------------------
rdeck.base=$RDECK_BASE
framework.projects.dir=$RDECK_BASE/projects
framework.etc.dir=$RDECK_BASE/etc
framework.var.dir=$RDECK_BASE/var
framework.tmp.dir=$RDECK_BASE/var/tmp
framework.logs.dir=$RDECK_BASE/var/logs
framework.libext.dir=$RDECK_BASE/libext
# ----------------------------------------------------------------
# SSH defaults for node executor and file copier
# ----------------------------------------------------------------
framework.ssh.keypath = $RDECK_BASE/.ssh/id_rsa
framework.ssh.user = $USERNAME
# ssh connection timeout after a specified number of milliseconds.
# "0" value means wait forever.
framework.ssh.timeout = 0
rundeck.tokens.file=$HOME/etc/tokens.properties
# force UTF-8
#framework.remote.charset.default=UTF-8
END

#set grails URL
sed -i 's,grails.serverURL\=.*,grails.serverURL\='${RUNDECK_URL}',g' $RDECK_BASE/server/config/rundeck-config.properties

cat > $HOME/etc/profile <<END
RDECK_BASE=$RDECK_BASE
export RDECK_BASE
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export JAVA_HOME
PATH=\$JAVA_HOME/bin:\$RDECK_BASE/tools/bin:\$PATH
export PATH
export LIBDIR=\$RDECK_BASE/tools/lib
CLI_CP=
for i in \`ls \$LIBDIR/*.jar\`
do
 CLI_CP=\${CLI_CP}:\${i}
done
export CLI_CP
# force UTF-8 default encoding
export RDECK_JVM="-Dfile.encoding=UTF-8"
END

API_KEY=${API_KEY:-letmein99}
cat > $HOME/etc/tokens.properties <<END
admin: $API_KEY
END

cat > $HOME/etc/admin.aclpolicy <<END
description: Admin, all access.
context:
  project: '.*' # all projects
for:
  resource:
    - allow: '*' # allow read/create all kinds
  adhoc:
    - allow: '*' # allow read/running/killing adhoc jobs
  job:
    - allow: '*' # allow read/write/delete/run/kill of all jobs
  node:
    - allow: '*' # allow read/run for all nodes
by:
  group: admin
---
description: Admin, all access.
context:
  application: 'rundeck'
for:
  resource:
    - allow: '*' # allow create of projects
  project:
    - allow: '*' # allow view/admin of all projects
  project_acl:
    - allow: '*' # allow admin of all project-level ACL policies
  storage:
    - allow: '*' # allow read/create/update/delete for all /keys/* storage content
by:
  group: admin
END

# open permissions via api
cp $HOME/etc/admin.aclpolicy $HOME/etc/apitoken.aclpolicy
sed -i -e "s:admin:api_token_group:" $HOME/etc/apitoken.aclpolicy

if [ -n "$SETUP_TEST_PROJECT" ] ; then
    setup_project $RDECK_BASE $SETUP_TEST_PROJECT
    if [ -n "$CONFIG_TEST_PROJECT_FILE" ] ; then
      append_project_config $RDECK_BASE $SETUP_TEST_PROJECT $CONFIG_TEST_PROJECT_FILE
    fi
fi

if [ -n "$NODE_CACHE_FIRST_LOAD_SYNCH" ] ; then
  cat - >>$RDECK_BASE/server/config/rundeck-config.properties <<END
rundeck.nodeService.nodeCache.firstLoadAsynch=false
END
fi


#start rundeck
start_rundeck
echo "started rundeck"

### POST CONFIG
# RUN TEST POSTSTART SCRIPT
if [[ ! -z "$CONFIG_SCRIPT_POSTSTART" ]]
then
  config_scripts=( ${CONFIG_SCRIPT_POSTSTART//,/ } )
  run_helpers "post-start" "${config_scripts[@]}"
else
  echo "### Post start config not set. skipping..."
fi


### Signal READY
# here we should leave some file in a shared folder to signal that the server is ready. so tests can begin.
touch $HOME/resources/$RUNDECK_NODE.ready