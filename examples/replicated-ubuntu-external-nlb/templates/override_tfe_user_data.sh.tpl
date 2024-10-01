#! /bin/bash
set -euo pipefail

LOGFILE="/var/log/tfe-cloud-init.log"
TFE_CONFIG_DIR="/etc/tfe"
TFE_INSTALLER_DIR="/opt/tfe/installer"
TFE_LICENSE_PATH="$TFE_CONFIG_DIR/tfe-license.rli"
TFE_TLS_CERTS_DIR="$TFE_CONFIG_DIR/tls"
REPL_BUNDLE_PATH="$TFE_INSTALLER_DIR/replicated.tar.gz"
REPL_CONF_PATH="$TFE_CONFIG_DIR/replicated.conf"
TFE_LOG_FORWARDING_CONFIG_PATH="$TFE_CONFIG_DIR/fluent-bit.conf"
AWS_REGION="${aws_region}"

function log {
  local level="$1"
  local message="$2"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local log_entry="$timestamp [$level] - $message"

  echo "$log_entry" | tee -a "$LOGFILE"
}

function detect_os_distro {
  local OS_DISTRO_NAME=$(grep "^NAME=" /etc/os-release | cut -d"\"" -f2)
  local OS_DISTRO_DETECTED

  case "$OS_DISTRO_NAME" in
    "Ubuntu"*)
      OS_DISTRO_DETECTED="ubuntu"
      ;;
    "CentOS Linux"*)
      OS_DISTRO_DETECTED="centos"
      ;;
    "Red Hat"*)
      OS_DISTRO_DETECTED="rhel"
      ;;
    "Amazon Linux"*)
      OS_DISTRO_DETECTED="amzn2023"
      ;;
    *)
      log "ERROR" "'$OS_DISTRO_NAME' is not a supported Linux OS distro for TFE."
      exit_script 1
  esac

  echo "$OS_DISTRO_DETECTED"
}

function install_awscli {
  local OS_DISTRO="$1"
  local OS_VERSION=$(grep "^VERSION=" /etc/os-release | cut -d"\"" -f2)

  if command -v aws > /dev/null; then
    log "INFO" "Detected 'aws-cli' is already installed. Skipping."
  else
    log "INFO" "Installing 'aws-cli'."
    curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    if command -v unzip > /dev/null; then
      unzip -qq awscliv2.zip
    elif command -v busybox > /dev/null; then
      busybox unzip -qq awscliv2.zip
    else
      log "WARNING" "No 'unzip' utility found. Attempting to install 'unzip'."
      if [[ "$OS_DISTRO" == "ubuntu" || "$OS_DISTRO" == "debian" ]]; then
        apt-get update -y
        apt-get install unzip -y
      elif [[ "$OS_DISTRO" == "centos" || "$OS_DISTRO" == "rhel" || "$OS_DISTRO" == "amzn2023" ]]; then
        yum install unzip -y
      else
        log "ERROR" "Unable to install required 'unzip' utility. Exiting."
        exit_script 2
      fi
      unzip -qq awscliv2.zip
    fi
    ./aws/install > /dev/null
    rm -f ./awscliv2.zip && rm -rf ./aws
  fi
}

function install_docker {
  local OS_DISTRO="$1"
  local OS_MAJOR_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d"\"" -f2 | cut -d"." -f1)

  if command -v docker > /dev/null; then
    log "INFO" "Detected 'docker' is already installed. Skipping."
  else
    if [[ "$OS_DISTRO" == "ubuntu" ]]; then
      # https://docs.docker.com/engine/install/ubuntu/
      log "INFO" "Installing Docker for Ubuntu."
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update -y
      DOCKER_VERSION="5:${docker_version}-1~ubuntu.$(lsb_release -r | awk '{print $2}')~$(lsb_release -cs)"
      apt-get install -y docker-ce="$${DOCKER_VERSION}" docker-ce-cli=$${DOCKER_VERSION} containerd.io docker-compose-plugin
    elif [[ "$OS_DISTRO" == "rhel" || "$OS_DISTRO" == "centos" ]]; then
      # https://docs.docker.com/engine/install/rhel/ or https://docs.docker.com/engine/install/centos/
      log "Warning" "Docker is no longer supported on RHEL 8 and beyond. Installing Docker CE..."
      local DOCKER_VERSION="${docker_version}-1.el$OS_MAJOR_VERSION"
      yum install -y yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      yum install -y docker-ce-3:$DOCKER_VERSION docker-ce-cli-1:$DOCKER_VERSION containerd.io docker-compose-plugin
    elif [[ "$OS_DISTRO" == "amzn2023" ]]; then
      yum install -y docker containerd
      mkdir -p /usr/local/lib/docker/cli-plugins
      curl -sL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-"$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
      chown root:root /usr/local/lib/docker/cli-plugins/docker-compose
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
    systemctl enable --now docker.service
  fi
}

function install_podman {
  local OS_DISTRO="$1"
  local OS_MAJOR_VERSION="$2"

  if [[ -n "$(command -v podman)" ]]; then
    log "INFO" "Detected 'podman' is already installed. Skipping."
  else
    if [[ "$OS_DISTRO" == "rhel" ]]; then
      log "INFO" "Installing Podman for RHEL $OS_MAJOR_VERSION."
      dnf update -y
      dnf install -y podman-docker
    else
      log "ERROR" "Podman install for $OS_DISTRO is currently not supported."
      exit_script 2
    fi
    #systemctl enable --now podman.service
    systemctl enable --now podman.socket
  fi
}

function retrieve_license_from_awssm {
  local SECRET_ARN="$1"
  local SECRET_REGION=$AWS_REGION

  if [[ -z "$SECRET_ARN" ]]; then
    log "ERROR" "Secret ARN cannot be empty. Exiting."
    exit_script 4
  elif [[ "$SECRET_ARN" == arn:aws:secretsmanager:* ]]; then
    log "INFO" "Retrieving value of secret '$SECRET_ARN' from AWS Secrets Manager."
    TFE_LICENSE=$(aws secretsmanager get-secret-value --region $SECRET_REGION --secret-id $SECRET_ARN --query SecretString --output text)
    echo "$TFE_LICENSE" > $TFE_LICENSE_PATH
  else
    log "WARNING" "Did not detect AWS Secrets Manager secret ARN. Setting value of secret to what was passed in."
    TFE_LICENSE="$SECRET_ARN"
    echo "$TFE_LICENSE" > $TFE_LICENSE_PATH
  fi
}

function retrieve_certs_from_awssm {
  local SECRET_ARN="$1"
  local DESTINATION_PATH="$2"
  local SECRET_REGION=$AWS_REGION
  local CERT_DATA

  if [[ -z "$SECRET_ARN" ]]; then
    log "ERROR" "Secret ARN cannot be empty. Exiting."
    exit_script 5
  elif [[ "$SECRET_ARN" == arn:aws:secretsmanager:* ]]; then
    log "INFO" "Retrieving value of secret '$SECRET_ARN' from AWS Secrets Manager."
    CERT_DATA=$(aws secretsmanager get-secret-value --region $SECRET_REGION --secret-id $SECRET_ARN --query SecretString --output text)
    echo "$CERT_DATA" | base64 -d > $DESTINATION_PATH
  else
    log "WARNING" "Did not detect AWS Secrets Manager secret ARN. Setting value of secret to what was passed in."
    CERT_DATA="$SECRET_ARN"
    echo "$CERT_DATA" | base64 -d > $DESTINATION_PATH
  fi
}

function configure_log_forwarding {
  cat > "$TFE_LOG_FORWARDING_CONFIG_PATH" << EOF
${fluent_bit_rendered_config}
EOF
}

function generate_tfe_replicated_config {
  local TFE_SETTINGS_PATH="$1"
  cat > "$TFE_SETTINGS_PATH" << EOF
{
  "DaemonAuthenticationType": "password",
  "DaemonAuthenticationPassword": "",
  "ImportSettingsFrom": "$TFE_SETTINGS_PATH",
%{ if airgap_install == true ~}
  "LicenseBootstrapAirgapPackagePath": "$TFE_AIRGAP_PATH",
%{ else ~}
  "ReleaseSequence": ${tfe_release_sequence},
%{ endif ~}
  "LicenseFileLocation": "$TFE_LICENSE_PATH",
  "TlsBootstrapHostname": "${tfe_hostname}",
  "TlsBootstrapType": "server-path",
  "TlsBootstrapCert": "$TFE_CONFIG_DIR/certs/tls_cert.pem",
  "TlsBootstrapKey": "$TFE_CONFIG_DIR/certs/tls_privkey.pem",
  "RemoveImportSettingsFrom": false,
  "BypassPreflightChecks": true
}
EOF
}
function generate_tfe_settings_config {
  local TFE_SETTINGS_PATH="$1"
 # generate TFE app settings JSON file
  # https://www.terraform.io/docs/enterprise/install/automating-the-installer.html#available-settings
  echo "[INFO] Generating $TFE_SETTINGS_PATH file."
  cat > $TFE_SETTINGS_PATH << EOF
{
  "aws_access_key_id": {},
  "aws_instance_profile": {
      "value": "1"
  },
  "aws_secret_access_key": {},
  "azure_account_key": {},
  "azure_account_name": {},
  "azure_container": {},
  "azure_endpoint": {},
  "backup_token": {},
  "ca_certs": {
    "value": "$CA_CERTS"
  },
  "capacity_concurrency": {
      "value": "${capacity_concurrency}"
  },
  "capacity_cpus": {},
  "capacity_memory": {
      "value": "${capacity_memory}"
  },
  "custom_image_tag": {
    "value": "${custom_image_tag}"
  },
  "disk_path": {},
  "enable_active_active": {
    "value": "${enable_active_active}"
  },
  "enable_metrics_collection": {
      "value": "${enable_metrics_collection}"
  },
  "enc_password": {
      "value": "$ENC_PASSWORD"
  },
  "extern_vault_addr": {},
  "extern_vault_enable": {
      "value": "0"
  },
  "extern_vault_path": {},
  "extern_vault_propagate": {},
  "extern_vault_role_id": {},
  "extern_vault_secret_id": {},
  "extern_vault_token_renew": {},
  "extra_no_proxy": {
    "value": "${extra_no_proxy}"
  },
  "force_tls": {
    "value": "${force_tls}"
  },
  "gcs_bucket": {},
  "gcs_credentials": {},
  "gcs_project": {},
  "hairpin_addressing": {
    "value": "${hairpin_addressing}"
  },
  "hostname": {
      "value": "${tfe_hostname}"
  },
  "iact_subnet_list": {},
  "iact_subnet_time_limit": {
      "value": "60"
  },
  "installation_type": {
      "value": "production"
  },
  "log_forwarding_config": {
    "value": "$LOG_FORWARDING_CONFIG"
  },
  "log_forwarding_enabled": {
    "value": "${log_forwarding_enabled}"
  },
  "metrics_endpoint_enabled": {
      "value": "${metrics_endpoint_enabled}"
  },
  "metrics_endpoint_port_http": {
      "value": "${metrics_endpoint_port_http}"
  },
  "metrics_endpoint_port_https": {
      "value": "${metrics_endpoint_port_https}"
  },
  "pg_dbname": {
      "value": "${pg_dbname}"
  },
  "pg_extra_params": {
      "value": "sslmode=require"
  },
  "pg_netloc": {
      "value": "${pg_netloc}"
  },
  "pg_password": {
      "value": "${pg_password}"
  },
  "pg_user": {
      "value": "${pg_user}"
  },
  "placement": {
      "value": "placement_s3"
  },
  "production_type": {
      "value": "external"
  },
  "redis_host": {
    "value": "${redis_host}"
  },
  "redis_pass": {
    "value": "${redis_pass}"
  },
  "redis_port": {
    "value": "${redis_port}"
  },
  "redis_use_password_auth": {
    "value": "${redis_use_password_auth}"
  },
  "redis_use_tls": {
    "value": "${redis_use_tls}"
  },
  "restrict_worker_metadata_access": {
    "value": "${restrict_worker_metadata_access}"
  },
  "s3_bucket": {
      "value": "${s3_app_bucket_name}"
  },
  "s3_endpoint": {},
  "s3_region": {
      "value": "${s3_app_bucket_region}"
  },
%{ if kms_key_arn != "" ~}
  "s3_sse": {
      "value": "aws:kms"
  },
  "s3_sse_kms_key_id": {
      "value": "${kms_key_arn}"
  },
%{ else ~}
  "s3_sse": {},
  "s3_sse_kms_key_id": {},
%{ endif ~}
  "tbw_image": {
      "value": "${tbw_image}"
  },
  "tls_ciphers": {},
  "tls_vers": {
      "value": "tls_1_2_tls_1_3"
  }
}
EOF
}

# https://developer.hashicorp.com/terraform/enterprise/flexible-deployments/install/configuration
function generate_tfe_docker_compose_config {
  local TFE_SETTINGS_PATH="$1"
  cat > "$TFE_SETTINGS_PATH" << EOF
---
name: tfe
services:
  tfe:
    image: ${tfe_image_repository_url}/${tfe_image_name}:${tfe_image_tag}
    restart: unless-stopped
    environment:
      # Application settings
      TFE_HOSTNAME: ${tfe_hostname}
      TFE_LICENSE: $TFE_LICENSE
      TFE_LICENSE_PATH: ""
      TFE_OPERATIONAL_MODE: ${tfe_operational_mode}
      TFE_ENCRYPTION_PASSWORD: $TFE_ENCRYPTION_PASSWORD
      TFE_CAPACITY_CONCURRENCY: ${tfe_capacity_concurrency}
      TFE_CAPACITY_CPU: ${tfe_capacity_cpu}
      TFE_CAPACITY_MEMORY: ${tfe_capacity_memory}
      TFE_LICENSE_REPORTING_OPT_OUT: ${tfe_license_reporting_opt_out}
      TFE_RUN_PIPELINE_DRIVER: ${tfe_run_pipeline_driver}
      TFE_RUN_PIPELINE_IMAGE: ${tfe_run_pipeline_image}
      TFE_BACKUP_RESTORE_TOKEN: ${tfe_backup_restore_token}
      TFE_NODE_ID: ${tfe_node_id}
      TFE_HTTP_PORT: ${tfe_http_port}
      TFE_HTTPS_PORT: ${tfe_https_port}

      # Database settings
      TFE_DATABASE_HOST: ${tfe_database_host}
      TFE_DATABASE_NAME: ${tfe_database_name}
      TFE_DATABASE_USER: ${tfe_database_user}
      TFE_DATABASE_PASSWORD: ${tfe_database_password}
      TFE_DATABASE_PARAMETERS: ${tfe_database_parameters}

      # Object storage settings
      TFE_OBJECT_STORAGE_TYPE: ${tfe_object_storage_type}
      TFE_OBJECT_STORAGE_S3_BUCKET: ${tfe_object_storage_s3_bucket}
      TFE_OBJECT_STORAGE_S3_REGION: ${tfe_object_storage_s3_region}
      TFE_OBJECT_STORAGE_S3_ENDPOINT: ${tfe_object_storage_s3_endpoint}
      TFE_OBJECT_STORAGE_S3_USE_INSTANCE_PROFILE: ${tfe_object_storage_s3_use_instance_profile}
      TFE_OBJECT_STORAGE_S3_ACCESS_KEY_ID: ${tfe_object_storage_s3_access_key_id}
      TFE_OBJECT_STORAGE_S3_SECRET_ACCESS_KEY: ${tfe_object_storage_s3_secret_access_key}
      TFE_OBJECT_STORAGE_S3_SERVER_SIDE_ENCRYPTION: ${tfe_object_storage_s3_server_side_encryption}
      TFE_OBJECT_STORAGE_S3_SERVER_SIDE_ENCRYPTION_KMS_KEY_ID: ${tfe_object_storage_s3_server_side_encryption_kms_key_id}

%{ if tfe_operational_mode == "active-active" ~}
      # Vault settings
      TFE_VAULT_CLUSTER_ADDRESS: https://$VM_PRIVATE_IP:8201

      # Redis settings.
      TFE_REDIS_HOST: ${tfe_redis_host}
      TFE_REDIS_USE_TLS: ${tfe_redis_use_tls}
      TFE_REDIS_USE_AUTH: ${tfe_redis_use_auth}
      TFE_REDIS_PASSWORD: ${tfe_redis_password}
%{ endif ~}

      # TLS settings
      TFE_TLS_CERT_FILE: ${tfe_tls_cert_file}
      TFE_TLS_KEY_FILE: ${tfe_tls_key_file}
      TFE_TLS_CA_BUNDLE_FILE: ${tfe_tls_ca_bundle_file}
      TFE_TLS_CIPHERS: ${tfe_tls_ciphers}
      TFE_TLS_ENFORCE: ${tfe_tls_enforce}
      TFE_TLS_VERSION: ${tfe_tls_version}

      # Observability settings
      TFE_LOG_FORWARDING_ENABLED: ${tfe_log_forwarding_enabled}
      TFE_LOG_FORWARDING_CONFIG_PATH: $TFE_LOG_FORWARDING_CONFIG_PATH
      TFE_METRICS_ENABLE: ${tfe_metrics_enable}
      TFE_METRICS_HTTP_PORT: ${tfe_metrics_http_port}
      TFE_METRICS_HTTPS_PORT: ${tfe_metrics_https_port}

      # Docker driver settings
      TFE_DISK_CACHE_PATH: ${tfe_disk_cache_path}
      TFE_DISK_CACHE_VOLUME_NAME: ${tfe_disk_cache_volume_name}
      TFE_RUN_PIPELINE_DOCKER_NETWORK: ${tfe_run_pipeline_docker_network}
%{ if tfe_hairpin_addressing ~}
      # Prevent loopback with Layer 4 load balancer with hairpinning TFE agent traffic
      TFE_RUN_PIPELINE_DOCKER_EXTRA_HOSTS: ${tfe_hostname}:$VM_PRIVATE_IP
%{ endif ~}

      # Network settings
      TFE_IACT_SUBNETS: ${tfe_iact_subnets}
      TFE_IACT_TRUSTED_PROXIES: ${tfe_iact_trusted_proxies}
      TFE_IACT_TIME_LIMIT: ${tfe_iact_time_limit}

%{ if tfe_hairpin_addressing ~}
    extra_hosts:
      - ${tfe_hostname}:$VM_PRIVATE_IP
%{ endif ~}
    cap_add:
      - IPC_LOCK
    read_only: true
    tmpfs:
      - /tmp:mode=01777
      - /var/run
      - /var/log/terraform-enterprise
    ports:
      - 80:80
      - 443:443
%{ if tfe_operational_mode == "active-active" ~}
      - 8201:8201
%{ endif ~}
%{ if tfe_metrics_enable ~}
      - ${tfe_metrics_http_port}:${tfe_metrics_http_port}
      - ${tfe_metrics_https_port}:${tfe_metrics_https_port}
%{ endif ~}

    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
%{ if tfe_log_forwarding_enabled ~}
      - type: bind
        source: $TFE_LOG_FORWARDING_CONFIG_PATH
        target: $TFE_LOG_FORWARDING_CONFIG_PATH
%{ endif ~}
      - type: bind
        source: $TFE_TLS_CERTS_DIR
        target: /etc/ssl/private/terraform-enterprise
      - type: volume
        source: terraform-enterprise-cache
        target: /var/cache/tfe-task-worker/terraform
volumes:
  terraform-enterprise-cache:
EOF
}

function generate_tfe_podman_quadlet {
  cat > $TFE_CONFIG_DIR/tfe.kube << EOF
[Unit]
Description=Terraform Enterprise Kubernetes Deployment

[Install]
WantedBy=default.target

[Service]
Restart=always

[Kube]
Yaml=tfe-pod.yaml
EOF
}

function pull_tfe_image {
  log "INFO" "Authenticating to '${tfe_image_repository_url}' container registry."
  log "INFO" "Detected TFE image repository username is '${tfe_image_repository_username}'."
  if [[ "${tfe_image_repository_url}" == "images.releases.hashicorp.com" ]]; then
    log "INFO" "Detected default TFE registry in use. Setting TFE_IMAGE_REPOSITORY_PASSWORD to value of TFE license."
    TFE_IMAGE_REPOSITORY_PASSWORD=$TFE_LICENSE
  else
    log "INFO" "Setting TFE_IMAGE_REPOSITORY_PASSWORD to value of 'tfe_image_repository_password' module input."
    TFE_IMAGE_REPOSITORY_PASSWORD=${tfe_image_repository_password}
  fi
  if [[ "${container_runtime}" == "podman" ]]; then
    podman login --username ${tfe_image_repository_username} ${tfe_image_repository_url} --password $TFE_IMAGE_REPOSITORY_PASSWORD
    log "INFO" "Pulling TFE container image '${tfe_image_repository_url}/${tfe_image_name}:${tfe_image_tag}' down locally."
    podman pull ${tfe_image_repository_url}/${tfe_image_name}:${tfe_image_tag}
  else
    docker login ${tfe_image_repository_url} --username ${tfe_image_repository_username} --password $TFE_IMAGE_REPOSITORY_PASSWORD
    log "INFO" "Pulling TFE container image '${tfe_image_repository_url}/${tfe_image_name}:${tfe_image_tag}' down locally."
    docker pull ${tfe_image_repository_url}/${tfe_image_name}:${tfe_image_tag}
  fi
}

function exit_script {
  if [[ "$1" == 0 ]]; then
    log "INFO" "tfe_user_data script finished successfully!"
  else
    log "ERROR" "tfe_user_data script finished with error code $1."
  fi

  exit "$1"
}

function main() {
  log "INFO" "Beginning TFE user_data script."
  log "INFO" "Determining Linux operating system distro..."
  OS_DISTRO=$(detect_os_distro)
  log "INFO" "Detected Linux OS distro is '$OS_DISTRO'."
  OS_MAJOR_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d"\"" -f2 | cut -d"." -f1)
  log "INFO" "Detected OS major version is '$OS_MAJOR_VERSION'."

  log "INFO" "Scraping EC2 instance metadata for private IP address..."
  EC2_TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  VM_PRIVATE_IP=$(curl -sS -H "X-aws-ec2-metadata-token: $EC2_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
  log "INFO" "Detected EC2 instance private IP address is '$VM_PRIVATE_IP'."

  log "INFO" "Creating TFE directories..."
  mkdir -p $TFE_CONFIG_DIR $TFE_TLS_CERTS_DIR
  mkdir -p $TFE_INSTALLER_DIR

  log "INFO" "Installing software dependencies..."
  install_awscli "$OS_DISTRO"
  if [[ "${container_runtime}" == "podman" ]]; then
    install_podman "$OS_DISTRO" "$OS_MAJOR_VERSION"
  else
    install_docker "$OS_DISTRO" "$OS_MAJOR_VERSION"
  fi

  if [[ "$OS_DISTRO" == "rhel" ]]; then
    log "INFO" "Resizing '/' and '/var' partitions for RHEL."
    lvresize -r -L 10G /dev/mapper/rootvg-rootlv
    lvresize -r -L 40G /dev/mapper/rootvg-varlv
  fi

  log "INFO" "Retrieving TFE license file..."
  retrieve_license_from_awssm "${tfe_license_secret_arn}"

  log "INFO" "Retrieving TFE TLS certificate..."
  retrieve_certs_from_awssm "${tfe_tls_cert_secret_arn}" "$TFE_TLS_CERTS_DIR/cert.pem"
  log "INFO" "Retrieving TFE TLS private key..."
  retrieve_certs_from_awssm "${tfe_tls_privkey_secret_arn}" "$TFE_TLS_CERTS_DIR/key.pem"
  log "INFO" "Retrieving TFE TLS CA bundle..."
  retrieve_certs_from_awssm "${tfe_tls_ca_bundle_secret_arn}" "$TFE_TLS_CERTS_DIR/bundle.pem"

  log "INFO" "Retrieving 'TFE_ENCRYPTION_PASSWORD' secret..."
  TFE_ENCRYPTION_PASSWORD=$(aws secretsmanager get-secret-value --region $AWS_REGION --secret-id "${tfe_encryption_password_secret_arn}" --query SecretString --output text)

  if [[ "${tfe_log_forwarding_enabled}" == "true" ]]; then
    log "INFO" "Generating '$TFE_LOG_FORWARDING_CONFIG_PATH' file for log forwarding."
    configure_log_forwarding
  fi

  # Generate TFE container runtime config file
  if [[ "${container_runtime}" == "podman" ]]; then
    TFE_SETTINGS_PATH="$TFE_CONFIG_DIR/tfe-pod.yaml"
    log "INFO" "Generating '$TFE_SETTINGS_PATH' config file for TFE on Podman."
    #generate_tfe_podman_spec "$TFE_SETTINGS_PATH"
    log "ERROR" "Podman support is not yet available. Exiting."
    exit_script 99
  else
    # TFE_SETTINGS_PATH="$TFE_CONFIG_DIR/docker-compose.yaml"
    # log "INFO" "Generating '$TFE_SETTINGS_PATH' config file for TFE on Docker."
    # generate_tfe_docker_compose_config "$TFE_SETTINGS_PATH"
    # TFE_SETTINGS_PATH="$TFE_CONFIG_DIR/docker-compose.yaml"
    TFE_SETTINGS_PATH="$TFE_CONFIG_DIR/tfe-settings.json"
    log "INFO" "Generating '$TFE_SETTINGS_PATH' config file for TFE on Replicated."
    # generate_tfe_docker_compose_config "$TFE_SETTINGS_PATH"
    generate_tfe_replicated_config "$TFE_SETTINGS_PATH"
  fi

  # log "INFO" "Preparing to download TFE container image..."
  # pull_tfe_image

  cd $TFE_CONFIG_DIR
  if [[ "${container_runtime}" == "podman" ]]; then
    #log "INFO" "Starting TFE application via Podman."
    #podman play kube $TFE_SETTINGS_PATH
    #generate_tfe_podman_quadlet
    #cp $TFE_SETTINGS_PATH /etc/containers/systemd
    #cp $TFE_CONFIG_DIR/tfe.kube /etc/containers/systemd
    #systemctl daemon-reload
    #systemctl start tfe.service
    log "ERROR" "Podman support is not yet available. Exiting."
    exit_script 99
  else
    # log "INFO" "Starting TFE application via Docker Compose."
    # if command -v docker-compose > /dev/null; then
    #   docker-compose --file $TFE_SETTINGS_PATH up --detach
    # else
    #   docker compose --file $TFE_SETTINGS_PATH up --detach
    # fi
    log "INFO" "Starting TFE application via replicated."

  fi

  log "INFO" "Sleeping for a minute while TFE initializes."
  sleep 60

  log "INFO" "Polling TFE health check endpoint until the app becomes ready..."
  while ! curl -ksfS --connect-timeout 5 https://$VM_PRIVATE_IP/_health_check; do
    sleep 5
  done

  exit_script 0
}

main "$@"
