# consul-leader

This is an implementation of [application leader election](https://learn.hashicorp.com/tutorials/consul/application-leader-elections) running from a shell script in a docker container on alpine.

Basically you run this as a sidecar container to manage who is a leader in a group of tasks.

- Each sidecar will loop(`sleep $CONSUL_LEADER_SLEEP`) through:

  - Renewing their session.
    - Creating a session on their nomad task node.
      - Add `Meta.session` with the SessionID.
  - Checking the session on the key.
    - If they are the owner, they will tag themselves with `primary label` if not already, and remove tags if `replica label` is set and the tag is set.
    - If they are not the owner, they will remove `primary label` tag if it exists, and add tag if `replica label` is set and the tag is not set.
    - if there is no owner:
      - Creating the key if it doesn't exist
      - Acquiring the key
        - Tagging primary if acquired

- There is a level of expected entropy and it should survive:
  - Task being killed
  - Node being lost
  - KV value being misplaced
  - Session invalidation

## knobs

| ENV                         | default                                                                   | Note                                                                                        |
| :-------------------------- | :------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------ |
| CONSUL_HTTP_ADDR            | http://localhost:8500                                                     | Consul host.                                                                                |
| CONSUL_LEADER_SERVICE_NAME  | consul-leader                                                             | Changes the key root (if not explcit) and session label.                                    |
| CONSUL_LEADER_KEY           | /consul-leader/lock **OR** /consul-leader/CONSUL_LEADER_SERVICE_NAME/lock | Explicitly set the KV key to lock on.                                                       |
| CONSUL_LEADER_PRIMARY_LABEL | primary                                                                   | Label the leader this tag.                                                                  |
| CONSUL_LEADER_REPLICA_LABEL | **empty**                                                                 | Default non replica labels, add this to tag the non primary services.                       |
| CONSUL_LEADER_TTL           | 15s                                                                       | TTL of session. Must more more than sleep or will break. `10s-24h0m0s`                      |
| CONSUL_LEADER_SLEEP         | 10                                                                        | Sleep period for renewing TTL.                                                              |
| CONSUL_LEADER_LOCKDELAY     | 0s                                                                        | [Lock delay of key.](https://www.consul.io/docs/dynamic-app-config/sessions#session-design) |
| CONSUL_LEADER_LOG_LEVEL     | warn                                                                      | error/warn/info/debug _using debug will enable set -x_                                      |
