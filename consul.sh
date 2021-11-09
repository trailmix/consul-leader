#!/usr/local/bin/bash
set -e
CONSUL_LEADER_LOG_LEVEL="${CONSUL_LEADER_LOG_LEVEL:=warn}"
if [ "$CONSUL_LEADER_LOG_LEVEL" = "debug" ]; then
  set -x
fi 
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
# replica label is empty, meaning no label.  if you set this then the replicas will have this label
CONSUL_LEADER_REPLICA_LABEL="${CONSUL_LEADER_REPLICA_LABEL:=}"
# the time the session will be considerd alive, script will sleep for SLEEP seconds
CONSUL_LEADER_TTL=${CONSUL_LEADER_TTL:=15s}
# set sleep to some interval less than TTL
CONSUL_LEADER_SLEEP=${CONSUL_LEADER_SLEEP:=10}
# lock delay will take effect after a key is lost, and lock out new sessions for X time
CONSUL_LEADER_LOCKDELAY=${CONSUL_LEADER_LOCKDELAY:=0s}

ccwhite=$(echo -e "\033[0;37m")
ccred=$(echo -e "\033[0;31m")
ccgreen=$(echo -e "\033[0;32m")
ccyellow=$(echo -e "\033[0;33m")
ccend=$(echo -e "\033[0m")
declare -A LOG_LEVELS=([debug]=0 [info]=1 [warn]=2 [error]=3)
declare -A LOG_COLORS=([debug]=${ccwhite} [info]=${ccgreen} [warn]=${ccyellow} [error]=${ccred})
# log "message" "level" "echo params"
function log() {
  [[ ${LOG_LEVELS[$2]} ]] || return 1
  (( ${LOG_LEVELS[$2]} < ${LOG_LEVELS[$CONSUL_LEADER_LOG_LEVEL]} )) && return 2
  echo ${3-} "$(date -u +'%D %H:%M:%S') level=${LOG_COLORS[$2]}$2$ccend alloc_id=$NOMAD_ALLOC_ID service=$CONSUL_LEADER_SERVICE_NAME msg=$1"
}
# note "message"
function note() {
  [[ ${LOG_LEVELS[${2-debug}]} ]] || return 1
  #(( ${LOG_LEVELS[${2-debug}]} < ${LOG_LEVELS[$CONSUL_LEADER_LOG_LEVEL]} )) && return 2
  echo "${LOG_COLORS[${2-debug}]}$1$ccend"
}

# returns 1 if it exists and 0 if it doesnt
function check_key () {
  log "checking key..." "debug" "-n"
  local CHECK_KEY_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
  case $CHECK_KEY_RESPONSE_CODE in
    "404")
      note "NO"
      ;;
    "200")
      note "EXISTS"
      ;;
  esac
}

function create_key () {
  check_key
  local exists=$?
  if [ $exists = 1 ]; then
    log "creating key..." "warn" "-n"
    local CREATE_KEY_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
    case $CREATE_KEY_RESPONSE_CODE in
      "200")
        note "CREATED" "warn"
        ;;
      *)
        log "UNABLE TO CREATE" "error" && exit 1
    esac
  fi
}

# the inputs are for the retry attempts.
# first failure will call get_service again with "FAILURE" and 1, then 2, then 3 performing 3retries
# C/U R D
# curl -X PUT -s -d '{"ID": "_nomad-task-abcd-1237-test-test-test", "Name": "test"}' $CONSUL_HTTP_ADDR/v1/agent/service/register
# curl -G --data-urlencode 'filter=Service == "test" and ID matches "_nomad-task-abcd-1237.*"' $CONSUL_HTTP_ADDR/v1/agent/services | jq 'to_entries| map(select(.key | test("_nomad-task-abcd-1237-*")))| map(.value)[0]//empty'
# curl -X PUT -s $CONSUL_HTTP_ADDR/v1/agent/service/deregister/_nomad-task-abcd-1234-test-test-test
function get_service () {
  log "getting service..." "debug" "-n"
  local i="${2-0}"
  SERVICE=$(curl -s -G --data-urlencode 'filter=ID matches "_nomad-task-'$NOMAD_ALLOC_ID'-.*"'  $CONSUL_HTTP_ADDR/v1/agent/services | jq -c 'to_entries | map(select(.key | test("_nomad-task-'$NOMAD_ALLOC_ID'-*")))| map(.value)[0]//empty')
  if [ -z $SERVICE ]; then
    i="$((i+1))"
    note "FAILURE" "error"
    log "no service for alloc: $NOMAD_ALLOC_ID" "error"
    log "retrying ($i/3) in 5 seconds." "error"
    sleep 5
    [ $i -ge 3 ] && exit 1 || get_service "FAILURE" $i
  else
    note "OK"
  fi
  
}
# optionally pass in a label, defaults to CONSUL_LEADER_PRIMARY_LABEL
function remove_tag () {
  get_service
  log 'checking tag...' "debug" "-n"
  local NEWSERVICE=$(echo $SERVICE | jq -c 'del(.Tags[] | select(. == "'${1-$CONSUL_LEADER_PRIMARY_LABEL}'"))')
  if [ "$NEWSERVICE" != "$SERVICE" ]; then
    note "removing tag ${1-$CONSUL_LEADER_PRIMARY_LABEL}" "debug"
    local NEWSERVICE=$(echo $NEWSERVICE | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    local REMOVE_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $NEWSERVICE $CONSUL_HTTP_ADDR/v1/agent/service/register)
    case $REMOVE_TAG_RESPONSE_CODE in
      "200")
        log "removed ${1-$CONSUL_LEADER_PRIMARY_LABEL}" "debug"
        ;;
      *)
        log "FAILURE: $REMOVE_TAG_RESPONSE_CODE" "error"
    esac
  else
    note "NO CHANGE"
  fi
}
# optionally pass in a label, defaults to CONSUL_LEADER_PRIMARY_LABEL
function add_tag () {
  get_service
  log "adding tag..." "debug" "-n"
  local NEWSERVICE=$(echo $SERVICE | jq -c '.Tags =  (.Tags + ["'${1-$CONSUL_LEADER_PRIMARY_LABEL}'"]|unique)')
  if [ "$NEWSERVICE" != "$SERVICE" ]; then
    local NEWSERVICE=$(echo $NEWSERVICE | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    local ADD_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $NEWSERVICE $CONSUL_HTTP_ADDR/v1/agent/service/register)
    case $ADD_TAG_RESPONSE_CODE in
      "200")
        if [ "${1-$CONSUL_LEADER_PRIMARY_LABEL}" = "$CONSUL_LEADER_PRIMARY_LABEL" ]; then
          touch $NOMAD_ALLOC_DIR/$NOMAD_ALLOC_ID
        fi
        note "OK"
        ;;
      *)
        log "FAILURE: $ADD_TAG_RESPONSE_CODE" "error"
    esac
  else
    note "NO CHANGE"
  fi
}
function add_metadata () {
  # add session: SESSION_ID to metadata
  get_service
  log "adding metadata..." "debug" "-n"
  local NEWSERVICE=$(echo $SERVICE | jq -c '.Meta =  (.Meta + {"session": "'$CONSUL_LEADER_SESSION_ID'"})')
  if [ "$NEWSERVICE" != "$SERVICE" ]; then
    local NEWSERVICE=$(echo $NEWSERVICE | jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
    local ADD_METADATA_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -d $NEWSERVICE $CONSUL_HTTP_ADDR/v1/agent/service/register)
    case $ADD_METADATA_RESPONSE_CODE in
      "200")
        note "OK"
        ;;
      *)
        log "FAILURE: $ADD_METADATA_RESPONSE_CODE" "error"
    esac
  else
    note "NO CHANGE"
  fi
}

function create_session () {
  log "creating session..." "debug" "-n"
  # CONSIDER: LockDelay default is 15s
  # https://www.consul.io/docs/dynamic-app-config/sessions#session-design
  # This means that after a lock is invalidated, a new one cannot be acquired for 15 seconds
  local CREATE_SESSION_RESPONSE=$(curl -s -X PUT -d '{ "Name": "Consul-Leader API Lock: '$CONSUL_LEADER_SERVICE_NAME'", "TTL": "'$CONSUL_LEADER_TTL'", "LockDelay": "'$CONSUL_LEADER_LOCKDELAY'" }' $CONSUL_HTTP_ADDR/v1/session/create)
  CONSUL_LEADER_SESSION_ID=$(echo $CREATE_SESSION_RESPONSE | jq -c -r '.ID//empty' )
  if [ "$(expr length $CONSUL_LEADER_SESSION_ID)" = 36 ]; then
    note "OK" && add_metadata
  else
    [ "$1" = "FAILURE" ] && exit 1
    sleep 5 && create_session "FAILURE"
  fi
}

function acquire_key () {
  log "acquiring key..." "warn" "-n"
  if [ -n "$CONSUL_LEADER_SESSION_ID" ]; then
    local ACQUIRE_KEY_RESPONSE=$(curl -s -X PUT $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY?acquire=$CONSUL_LEADER_SESSION_ID)
    [ "$ACQUIRE_KEY_RESPONSE" = "true" ] && note "GET" "warn" && add_tag || note "MISS" "warn"
  fi
}

function renew_session () {
  [ -z "$CONSUL_LEADER_SESSION_ID" ] && log "no session..." "warn" && create_session
  log "renewing session: $CONSUL_LEADER_SESSION_ID..." "info" "-n"
  local RENEW_SESSION_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/session/renew/$CONSUL_LEADER_SESSION_ID)
  case $RENEW_SESSION_RESPONSE_CODE in
    "200")
      note "RENEWED"
      ;;
    "404")
      note "LOST" "warn" && create_session
  esac
}

create_key # create a consul kv to bind session to
create_session # create a session to bind to kv
acquire_key # bind to kv with session
while [ true ]; do
  # check if there is a session, if not race to check key, create if necessary, and acquire it
  renew_session # renew session first
  LOCK_OWNER=$(curl -s $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY?consistent | jq -c -r '.[0].Session//empty')
  if [ "$LOCK_OWNER" = "$CONSUL_LEADER_SESSION_ID" ]; then
    add_tag
    [ "$CONSUL_LEADER_REPLICA_LABEL" != "" ] && remove_tag $CONSUL_LEADER_REPLICA_LABEL
  else
    remove_tag
    [ "$CONSUL_LEADER_REPLICA_LABEL" != "" ] && add_tag $CONSUL_LEADER_REPLICA_LABEL
  fi
  [ "$LOCK_OWNER" = "" ] && create_key && acquire_key 
  sleep $CONSUL_LEADER_SLEEP
done