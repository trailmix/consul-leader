job "test-job" {
  datacenters = ["h2"]
  group "test-group" {
    count = 5
    task "test-task" {
      driver = "docker"
      env {
        CONSUL_HTTP_ADDR="http://${attr.unique.network.ip-address}:8500"
      }
      config {
        image = "registry.trilho.me/consul-leader:latest"
      }
      service {
        name = "test"
        enable_tag_override = true
      }
      resources {
        cpu    = 5
        memory = 50 # fails with minimum of 10 randomly
      }
    }
  }
}