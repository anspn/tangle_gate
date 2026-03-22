import Config

# Disable web server and MongoDB in test environment
config :iota_service, start_web: false, start_repo: false

# Use a separate test database to avoid polluting dev data
config :iota_service, IotaService.Store.Repo, url: "mongodb://localhost:27017/iota_service_test"

# Vault disabled in tests
config :iota_service, IotaService.Vault.Client, enabled: false
