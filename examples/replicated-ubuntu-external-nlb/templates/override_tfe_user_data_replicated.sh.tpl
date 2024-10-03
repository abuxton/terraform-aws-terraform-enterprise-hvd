#! /bin/bash
set -euo pipefail

LOGFILE="/var/log/tfe-cloud-init.log"
TFE_CONFIG_DIR="/etc/tfe"
TFE_INSTALLER_DIR="/opt/tfe/installer"
TFE_LICENSE_PATH="$TFE_CONFIG_DIR/tfe-license.rli"
#TFE_SETTINGS_PATH="$TFE_CONFIG_DIR/settings.json"
TFE_TLS_CERTS_DIR="$TFE_CONFIG_DIR/tls"
#REPL_BUNDLE_PATH="$TFE_INSTALLER_DIR/replicated.tar.gz"
REPL_CONF_PATH="/etc/replicated.conf"
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
   # echo "$TFE_LICENSE" > $TFE_LICENSE_PATH
    echo "$TFE_LICENSE" | base64 -d > $TFE_LICENSE_PATH
  else
    log "WARNING" "Did not detect AWS Secrets Manager secret ARN. Setting value of secret to what was passed in."
    TFE_LICENSE="$SECRET_ARN"

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
  local REPL_CONF_PATH="$1"
  cat > "$REPL_CONF_PATH" << EOF
{
  "DaemonAuthenticationType": "password",
  "DaemonAuthenticationPassword": "",
  "ImportSettingsFrom": "$TFE_SETTINGS_PATH",
  "ReleaseSequence": ${tfe_release_sequence},
  "LicenseFileLocation": "$TFE_LICENSE_PATH",
  "TlsBootstrapHostname": "${tfe_hostname}",
  "TlsBootstrapType": "server-path",
  "TlsBootstrapCert": "$TFE_TLS_CERTS_DIR/cert.pem",
  "TlsBootstrapKey": "$TFE_TLS_CERTS_DIR/key.pem",
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
      "value": "${tfe_capacity_concurrency}"
  },
  "capacity_cpus": {},
  "capacity_memory": {
      "value": "${tfe_capacity_memory}"
  },
  "custom_image_tag": {
    "value": "hashicorp/build-worker:now"
  },
  "disk_path": {},
  "enable_active_active": {
    "value": "false"
  },
  "enable_metrics_collection": {
      "value": "${tfe_metrics_enable}"
  },
  "enc_password": {
      "value": "$TFE_ENCRYPTION_PASSWORD"
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
    "value": ""
  },
  "force_tls": {
    "value": ""
  },
  "gcs_bucket": {},
  "gcs_credentials": {},
  "gcs_project": {},
  "hairpin_addressing": {
    "value": ""
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
    "value": "${fluent_bit_rendered_config}"
  },
  "log_forwarding_enabled": {
    "value": "${tfe_log_forwarding_enabled}"
  },
  "metrics_endpoint_enabled": {
      "value": "${tfe_metrics_enable}"
  },
  "metrics_endpoint_port_http": {
      "value": "${tfe_metrics_http_port}"
  },
  "metrics_endpoint_port_https": {
      "value": "${tfe_metrics_https_port}"
  },
  "pg_dbname": {
      "value": "${tfe_database_name}"
  },
  "pg_extra_params": {
      "value": "sslmode=require"
  },
  "pg_netloc": {
      "value": "${tfe_database_host}"
  },
  "pg_password": {
      "value": "${tfe_database_password}"
  },
  "pg_user": {
      "value": "${tfe_database_user}"
  },
  "placement": {
      "value": "placement_s3"
  },
  "production_type": {
      "value": "external"
  },
  "redis_host": {
    "value": "${tfe_redis_host}"
  },
  "redis_pass": {
    "value": "${tfe_redis_password}"
  },
  "redis_port": {
    "value": ""
  },
  "redis_use_password_auth": {
    "value": "${tfe_redis_use_auth}"
  },
  "redis_use_tls": {
    "value": "${tfe_redis_use_tls}"
  },
  "restrict_worker_metadata_access": {
    "value": ""
  },
  "s3_bucket": {
      "value": "${tfe_object_storage_s3_bucket}"
  },
  "s3_endpoint": {},
  "s3_region": {
      "value": "${tfe_object_storage_s3_region}"
  },
%{ if tfe_object_storage_s3_server_side_encryption != "" ~}
  "s3_sse": {
      "value": "${tfe_object_storage_s3_server_side_encryption}"
  },
  "s3_sse_kms_key_id": {
      "value": "${tfe_object_storage_s3_server_side_encryption_kms_key_id}"
  },
%{ else ~}
  "s3_sse": {},
  "s3_sse_kms_key_id": {},
%{ endif ~}
  "tbw_image": {
      "value": "default_image"
  },
  "tls_ciphers": {},
  "tls_vers": {
      "value": "tls_1_2_tls_1_3"
  }
}
EOF
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
  CA_CERTS=$(sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' $TFE_TLS_CERTS_DIR/bundle.pem)

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
    generate_tfe_replicated_config "$REPL_CONF_PATH"
    generate_tfe_settings_config "$TFE_SETTINGS_PATH"

    chmod -R 0644 $REPL_CONF_PATH
    chmod -R 0644 $TFE_CONFIG_DIR
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
    log "INFO" "Starting TFE application via replicated."
    # if command -v docker-compose > /dev/null; then
    #   docker-compose --file $TFE_SETTINGS_PATH up --detach
    # else
    #   docker compose --file $TFE_SETTINGS_PATH up --detach
    # fi
    log "INFO" "Starting TFE application via replicated."
    cd $TFE_INSTALLER_DIR
    echo "[INFO] Executing TFE install in 'online' mode."

    curl -o install.sh https://install.terraform.io/ptfe/stable
    bash ./install.sh \
      no-proxy \
      no-docker \
      private-address=$VM_PRIVATE_IP \
      public-address=$VM_PRIVATE_IP

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
