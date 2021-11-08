job "test-job" {
  datacenters = ["h2"]
  group "test-group" {
    count = 5
    task "test-task" {
      driver = "raw_exec"
      artifact {
        source = "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
        mode = "file"
        destination = "${NOMAD_TASK_DIR}/jq"
      }
      template {
        destination = "${NOMAD_TASK_DIR}/consul-leader.sh"
        perms = 755
        data = <<-EOF
          #!/bin/bash
          set -e
          set -x
          env
          # your CONSUL url                           default is "http://localhost:8500"
          CONSUL_HTTP_ADDR="$${CONSUL_HTTP_ADDR:=http://localhost:8500}"
          # TODO: consul auth

          # the name of the service                   default service is "consul-leader"
          CONSUL_LEADER_SERVICE_NAME="$${CONSUL_LEADER_SERVICE_NAME:=consul-leader}"
          # the key to assign the sessions to         default is "/consul-leader/lock" 
          # if CONSUL_LEADER_SERVICE_NAME is set      default is "/consul-leader/$CONSUL_LEADER_SERVICE_NAME"
          # if CONSUL_LEADER_KEY is set then it starts at root kv level
          if [ "$CONSUL_LEADER_SERVICE_NAME" = "consul-leader" ]; then
            CONSUL_LEADER_KEY="$${CONSUL_LEADER_KEY:=/$CONSUL_LEADER_SERVICE_NAME/lock}"
          else
            CONSUL_LEADER_KEY="$${CONSUL_LEADER_KEY:=/consul-leader/$CONSUL_LEADER_SERVICE_NAME/lock}"
          fi
          CONSUL_LEADER_SESSION_ID=

          CONSUL_LEADER_PRIMARY_LABEL="primary"
          # the time the session will be considerd alive, script will sleep for SLEEP seconds
          CONSUL_LEADER_TTL=15s
          # set sleep to some interval less than TTL
          CONSUL_LEADER_SLEEP=10
          # lock delay will take effect after a key is lost, and lock out new sessions for X time
          CONSUL_LEADER_LOCKDELAY=0s

          function check_key () {
            echo -n "checking key..."
            CHECK_KEY_RESPONSE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
          }

          function create_key () {
            check_key
            case $CHECK_KEY_RESPONSE_CODE in
              "404")
                echo "NO"
                echo -n "creating key..."
                CREATE_KEY_RESPONSE_CODE=$(curl -o /dev/null -w "%%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY)
                [ "$CREATE_KEY_RESPONSE_CODE" = "200" ] && echo "CREATED" || exit 1
                ;;
              "200")
                echo "EXISTS"
                ;;
            esac
          }

          function get_service () {
            # C/U R D
            # curl -G --data-urlencode 'filter=Service == "test" and ID matches "_nomad-task-abcd-1237.*"' $CONSUL_HTTP_ADDR/v1/agent/services | $NOMAD_TASK_DIR/jq 'to_entries| map(select(.key | test("_nomad-task-abcd-1237-*")))| map(.value)[0]//empty'
            # curl -X PUT -s -d '{"ID": "_nomad-task-abcd-1237-test-test-test", "Name": "test"}' $CONSUL_HTTP_ADDR/v1/agent/service/register
            # curl -X PUT -s $CONSUL_HTTP_ADDR/v1/agent/service/deregister/_nomad-task-abcd-1234-test-test-test
            # get service def
            echo -n "getting service..."
            i="$${2-0}"
            GET_SERVICE_RESPONSE=$(curl -s -G --data-urlencode 'filter=ID matches "_nomad-task-'$NOMAD_ALLOC_ID'-.*"'  $CONSUL_HTTP_ADDR/v1/agent/services | $NOMAD_TASK_DIR/jq -c 'to_entries | map(select(.key | test("_nomad-task-'$NOMAD_ALLOC_ID'-*")))| map(.value)[0]//empty')
            if [ -z $GET_SERVICE_RESPONSE ]; then
              i="$((i+1))"
              echo "FAILURE"
              echo "no service for alloc: $NOMAD_ALLOC_ID, retrying ($i/3) in 5 seconds..."
              [ "$1" = "FAILURE" ] && [ "$2" == "3" ] && exit 1
              sleep 5 && get_service "FAILURE" $i
            fi
            echo "OK"
          }
          function remove_tag () {
            get_service
            echo -n 'removing tag...'
            UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | $NOMAD_TASK_DIR/jq -c 'del(.Tags[] | select(. == "'$CONSUL_LEADER_PRIMARY_LABEL'"))')
            if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
              UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | $NOMAD_TASK_DIR/jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
              REMOVE_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
              [ "$REMOVE_TAG_RESPONSE_CODE" = "200" ] && echo "OK" || echo "FAILURE"
            else
              echo "NO CHANGE"
            fi
          }
          function add_tag () {
            #jq '. | select( .Services[] | .ID == "'$CONSUL_LEADER_INSTANCE_ID'").Services[0].Tags = (select( .Services[] | .ID == "'$CONSUL_LEADER_INSTANCE_ID'").Services[0].Tags + ["'$CONSUL_LEADER_PRIMARY_LABEL'"] | unique) | .Services[0]'
            get_service
            echo -n 'adding tag...'
            UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | $NOMAD_TASK_DIR/jq -c '.Tags =  (.Tags + ["'$CONSUL_LEADER_PRIMARY_LABEL'"]|unique)')
            if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
              UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | $NOMAD_TASK_DIR/jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
              ADD_TAG_RESPONSE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
              [ "$ADD_TAG_RESPONSE_CODE" = "200" ] && echo "OK" || echo "FAILURE"
            else
              echo "NO CHANGE"
            fi
          }
          function add_metadata () {
            # add session: SESSION_ID to metadata
            get_service
            echo -n 'adding metadata...'
            UPDATE_SERVICE_BODY=$(echo $GET_SERVICE_RESPONSE | $NOMAD_TASK_DIR/jq -c '.Meta =  (.Meta + {"session": "'$CONSUL_LEADER_SESSION_ID'"})')
            if [ "$UPDATE_SERVICE_BODY" != "$GET_SERVICE_RESPONSE" ]; then
              UPDATE_SERVICE_BODY=$(echo $UPDATE_SERVICE_BODY | $NOMAD_TASK_DIR/jq -c '.["Name"] = .Service | del(.Service, .Datacenter)')
              ADD_METADATA_RESPONSE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT -d $UPDATE_SERVICE_BODY $CONSUL_HTTP_ADDR/v1/agent/service/register)
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
            CONSUL_LEADER_SESSION_ID=$(echo $CREATE_SESSION_RESPONSE | $NOMAD_TASK_DIR/jq -c -r '.ID//empty' )
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
              # if I acquired the key, I should tag myself as primary
              [ "$ACQUIRE_KEY_RESPONSE" = "true" ] && add_tag || remove_tag
            else
              echo "NO SESSION"
            fi
          }

          function renew_session () {
            [ -z "$CONSUL_LEADER_SESSION_ID" ] && create_session
            echo -n "renewing session:$CONSUL_LEADER_SESSION_ID..."
            RENEW_SESSION_RESPONSE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PUT $CONSUL_HTTP_ADDR/v1/session/renew/$CONSUL_LEADER_SESSION_ID)
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
            LOCK_OWNER=$(curl -s $CONSUL_HTTP_ADDR/v1/kv$CONSUL_LEADER_KEY | $NOMAD_TASK_DIR/jq -c -r '.[0].Session//empty')
            [ "$LOCK_OWNER" == "$CONSUL_LEADER_SESSION_ID" ] && add_tag || remove_tag
            [ "$LOCK_OWNER" = "" ] && create_key && acquire_key 
            sleep $CONSUL_LEADER_SLEEP
          done
        EOF
      }
      env {
        # CONSUL_HTTP_ADDR="http://localhost:8500"
        # CONSUL_LEADER_KEY="/lead/test/one"
        # CONSUL_LEADER_SERVICE_NAME="test2" # must match service you want tag to exist on
      }
      config {
        command = "sh"
        args = ["-c", "chmod 755 ${NOMAD_TASK_DIR}/jq && ${NOMAD_TASK_DIR}/consul-leader.sh"]
      }
      service {
        name = "test"
        enable_tag_override = true
      }
      resources {
        cpu    = 5
        memory = 20 # fails with minimum of 10 randomly
      }
    }
  }
}