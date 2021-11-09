#!/bin/bash
set -e
if [ "${CONSUL_LEADER_LOG_LEVEL:=error}" = "debug" ]; then
  set -x
fi 

ccwhite=$(echo -e "\033[0;37m")
ccred=$(echo -e "\033[0;31m")
ccgreen=$(echo -e "\033[0;32m")
ccyellow=$(echo -e "\033[0;33m")
ccend=$(echo -e "\033[0m")
declare -A LOG_LEVELS=([debug]=0 [info]=1 [warn]=2 [error]=3)
declare -A LOG_COLORS=([debug]=${ccwhite} [info]=${ccgreen} [warn]=${ccyellow} [error]=${ccred})

function log() {
  [[ ${LOG_LEVELS[$2]} ]] || return 1
  (( ${LOG_LEVELS[$2]} < ${LOG_LEVELS[$CONSUL_LEADER_LOG_LEVEL]} )) && return 2
  echo ${3-} "$(date -u +'%D %H:%M:%S') ${LOG_COLORS[$2]}$2$ccend : $1"
}

# your CONSUL url                           default is "http://localhost:8500"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:=http://localhost:8500}"
# TODO: consul auth

# the name of the service                   default service is "consul-leader"
CONSUL_LEADER_SERVICE_NAME="${CONSUL_LEADER_SERVICE_NAME:=consul-leader}"
# the key to assign the sessions to         default is "/consul-leader/lock" 
# if CONSUL_LEADER_SERVICE_NAME is set      default is "/consul-leader/$CONSUL_LEADER_SERVICE_NAME"
# if CONSUL_LEADER_KEY is set then it starts at root kv level
if [ "$CONSUL_LEADER_SERVICE_NAME" = "consul-leader" ]; then
  CONSUL_LEADER_KEY="${CONSUL_LEADER_KEY:=/$CONSUL_LEADER_SERVICE_NAME/lock}"
else
  CONSUL_LEADER_KEY="${CONSUL_LEADER_KEY:=/consul-leader/$CONSUL_LEADER_SERVICE_NAME/lock}"
fi
CONSUL_LEADER_SESSION_ID=

CONSUL_LEADER_PRIMARY_LABEL="${CONSUL_LEADER_PRIMARY_LABEL:=primary}"
# the time the session will be considerd alive, script will sleep for SLEEP seconds
CONSUL_LEADER_TTL=${CONSUL_LEADER_TTL:=15s}
# set sleep to some interval less than TTL
CONSUL_LEADER_SLEEP=${CONSUL_LEADER_SLEEP:=10}
# lock delay will take effect after a key is lost, and lock out new sessions for X time
CONSUL_LEADER_LOCKDELAY=${CONSUL_LEADER_LOCKDELAY:=0s}

function check_key () {
  log "checking key..." "debug" "-n"
  CHECK_KEY_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
function create_key () {
  check_key
  case $CHECK_KEY_RESPONSE_CODE in
    "404")
      echo "NO"
      echo -n "creating key..."
      CREATE_KEY_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
      [ "$CREATE_KEY_RESPONSE_CODE" = "200" ] && echo "CREATED" || exit 1
      ;;
    "200")
      echo "EXISTS"
      ;;
  esac
}

function get_service () {
  # C/U R D
  # curl -G --data-urlencode 'filter=Service == "test" and ID matches "_nomad-task-abcd-1237.*"' $CONSUL_HTTP_ADDR/v1/agent/services | jq 'to_entries| map(select(.key | test("_nomad-task-abcd-1237-*")))| map(.value)[0]//empty'
  # curl -X PUT -s -d '{"ID": "_nomad-task-abcd-1237-test-test-test", "Name": "test"}' $CONSUL_HTTP_ADDR/v1/agent/service/register
  # curl -X PUT -s $CONSUL_HTTP_ADDR/v1/agent/service/deregister/_nomad-task-abcd-1234-test-test-test
  # get service def
  echo -n "getting service..."
  i="${2-0}"
  GET_SERVICE_RESPONSE=$(curl -s -G --data-urlencode 'filter=ID matches "_nomad-task-'$NOMAD_ALLOC_ID'-.*"'  $CONSUL_HTTP_ADDR/v1/agent/services | jq -c 'to_entries | map(select(.key | test("_nomad-task-'$NOMAD_ALLOC_ID'-*")))| map(.value)[0]//empty')
  if [ -z $GET_SERVICE_RESPONSE ]; then
    i="$((i+1))"
    echo "FAILURE"
    echo "no service for alloc: $NOMAD_ALLOC_ID, retrying ($i/3) in 5 seconds..."
    [ "$1" = "FAILURE" ] && [ "$2" == "3" ] && exit 1
    sleep 5 && get_service "FAILURE" $i
  fi
  echo "OK"
}
# optionally pass in a label, defaults to CONSUL_LEADER_PRIMARY_LABEL
function remove_tag () {
  get_service
  echo -n 'removing tag...'
  UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | jq -c 'del(.Tags[] | select(. == "'${1-$CONSUL_LEADER_PRIMARY_LABEL}'"))')
  if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
    UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    REMOVE_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
    if [ "$REMOVE_TAG_RESPONSE_CODE" = "200" ]; then
      echo "OK"
    else
      echo "FAILURE"
    fi
  else
    echo "NO CHANGE"
  fi
}
# optionally pass in a label, defaults to CONSUL_LEADER_PRIMARY_LABEL
function add_tag () {
  get_service
  echo -n 'adding tag...'
  UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | jq -c '.Tags =  (.Tags + ["'${1-$CONSUL_LEADER_PRIMARY_LABEL}'"]|unique)')
  if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
    UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    ADD_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
    if [ "$ADD_TAG_RESPONSE_CODE" = "200" ]; then
      if [ "${1-$CONSUL_LEADER_PRIMARY_LABEL}" = "$CONSUL_LEADER_PRIMARY_LABEL" ]; then
        touch $NOMAD_ALLOC_DIR/$NOMAD_ALLOC_ID
      fi
      echo "OK"
    else
      echo "FAILURE"
    fi
  else
    echo "NO CHANGE"
  fi
}
function add_metadata () {
  # add session: SESSION_ID to metadata
  get_service
  echo -n 'adding metadata...'
  UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | jq -c '.Meta =  (.Meta + {"session": "'$CONSUL_LEADER_SESSION_ID'"})')
  if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
    UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    ADD_METADATA_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
    [ "$ADD_METADATA_RESPONSE_CODE" = "200" ] && echo "OK" || echo "FAILURE"
  else
    echo "NO CHANGE"
  fi
}

function create_session () {
  echo -n "creating session..."
  # CONSIDER: LockDelay default is 15s
  # https://www.consul.io/docs/dynamic-app-config/sessions#session-design
  # This means that after a lock is invalidated, a new one cannot be acquired for 15 seconds
  CREATE_SESSION_RESPONSE=$(curl -s -X PUT -d '{ "Name": "Consul-Leader API Lock: '$CONSUL_LEADER_SERVICE_NAME'", "TTL": "'$CONSUL_LEADER_TTL'", "LockDelay": "'$CONSUL_LEADER_LOCKDELAY'" }' $CONSUL_HTTP_ADDR/v1/session/create)
  CONSUL_LEADER_SESSION_ID=$(echo $CREATE_SESSION_RESPONSE | jq -c -r '.ID//empty' )
  if [ "$(expr length $CONSUL_LEADER_SESSION_ID)" = 36 ]; then
    echo "OK"
    add_metadata
  else
    [ "$1" = "FAILURE" ] && exit 1
    sleep 5 && create_session "FAILURE"
  fi
}

function acquire_key () {
  echo -n "acquiring key..."
  if [ -n "$CONSUL_LEADER_SESSION_ID" ]; then
    ACQUIRE_KEY_RESPONSE=$(curl -s -X PUT $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY?acquire=$CONSUL_LEADER_SESSION_ID)
    echo $ACQUIRE_KEY_RESPONSE
  else
    echo "NO SESSION"
  fi
}

function renew_session () {
  [ -z "$CONSUL_LEADER_SESSION_ID" ] && create_session
  echo -n "renewing session:$CONSUL_LEADER_SESSION_ID..."
  RENEW_SESSION_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/session/renew/$CONSUL_LEADER_SESSION_ID)
  case $RENEW_SESSION_RESPONSE_CODE in
    "404")
      echo "LOST" && create_session
      ;;
    "200")
      echo "RENEWED"
      ;;
  esac
}

#create_key # create a consul kv to bind session to
#create_session # create a session to bind to kv
#acquire_key # bind to kv with session
while [ true ]; do
  # check if there is a session, if not race to check key, create if necessary, and acquire it
  renew_session # renew session first
  [ "$LOCK_OWNER" = "" ] && create_key && acquire_key 
  LOCK_OWNER=$(curl -s $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY?consistent | jq -c -r '.[0].Session//empty')
  if [ "$LOCK_OWNER" == "$CONSUL_LEADER_SESSION_ID" ]; then
    add_tag $CONSUL_LEADER_PRIMARY_LABEL
    if [ -n $CONSUL_LEADER_REPLICA_LABEL ]; then
      remove_tag $CONSUL_LEADER_REPLICA_LABEL
    fi
  else
    remove_tag
    if [ -n $CONSUL_LEADER_REPLICA_LABEL ]; then
      add_tag $CONSUL_LEADER_REPLICA_LABEL
    fi
  fi
  sleep $CONSUL_LEADER_SLEEP
done