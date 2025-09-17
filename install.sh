#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

hui_systemd_version="${1:-latest}"
hui_docker_version=":${hui_systemd_version#v}"

init_var() {
  ECHO_TYPE="echo -e"

  package_manager=""
  release=""
  version=""
  get_arch=""

  HUI_DATA_DOCKER="/h-ui/"
  HUI_DATA_SYSTEMD="/usr/local/h-ui/"

  h_ui_port=8081
  h_ui_time_zone=Asia/Shanghai

  ssh_local_forwarded_port=8082

  translation_file_content=""
  translation_file_base_url="https://raw.githubusercontent.com/jonssonyan/h-ui/refs/heads/main/local/"
  translation_file="en.json"
}

echo_content() {
  case $1 in
  "red")
    ${ECHO_TYPE} "\033[31m$2\033[0m"
    ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m"
    ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m"
    ;;
  "blue")
    ${ECHO_TYPE} "\033[34m$2\033[0m"
    ;;
  "purple")
    ${ECHO_TYPE} "\033[35m$2\033[0m"
    ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m"
    ;;
  "white")
    ${ECHO_TYPE} "\033[37m$2\033[0m"
    ;;
  esac
}

can_connect() {
  if ping -c2 -i0.3 -W1 "$1" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

version_ge() {
  local v1=${1#v}
  local v2=${2#v}

  if [[ -z "$v1" || "$v1" == "latest" ]]; then
    return 0
  fi

  IFS='.' read -r -a v1_parts <<<"$v1"
  IFS='.' read -r -a v2_parts <<<"$v2"

  for i in "${!v1_parts[@]}"; do
    local part1=${v1_parts[i]:-0}
    local part2=${v2_parts[i]:-0}

    if [[ "$part1" < "$part2" ]]; then
      return 1
    elif [[ "$part1" > "$part2" ]]; then
      return 0
    fi
  done
  return 0
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "You must be root to run this script"
    exit 1
  fi

  can_connect github.com
  if [[ "$?" == "1" ]]; then
    echo_content red "---> Network connection failed"
    exit 1
  fi

  if [[ $(command -v yum) ]]; then
    package_manager='yum'
  elif [[ $(command -v dnf) ]]; then
    package_manager='dnf'
  elif [[ $(command -v apt-get) ]]; then
    package_manager='apt-get'
  elif [[ $(command -v apt) ]]; then
    package_manager='apt'
  fi

  if [[ -z "${package_manager}" ]]; then
    echo_content red "This system is not currently supported"
    exit 1
  fi

  if [[ -n $(find /etc -name "rocky-release") ]] || grep </proc/version -q -i "rocky"; then
    release="rocky"
    if rpm -q rocky-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' rocky-release)
    fi
  elif [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    if rpm -q centos-stream-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-stream-release)
    elif rpm -q centos-release &>/dev/null; then
      version=$(rpm -q --queryformat '%{VERSION}' centos-release)
    fi
  elif grep </etc/issue -q -i "debian" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "debian" && [[ -f "/proc/version" ]]; then
    release="debian"
    version=$(cat /etc/debian_version)
  elif grep </etc/issue -q -i "ubuntu" && [[ -f "/etc/issue" ]] || grep </etc/issue -q -i "ubuntu" && [[ -f "/proc/version" ]]; then
    release="ubuntu"
    version=$(lsb_release -sr)
  fi

  major_version=$(echo "${version}" | cut -d. -f1)

  case $release in
  rocky) ;;
  centos)
    if [[ $major_version -ge 6 ]]; then
      echo_content green "Supported CentOS version detected: $version"
    else
      echo_content red "Unsupported CentOS version: $version. Only supports CentOS 6+."
      exit 1
    fi
    ;;
  ubuntu)
    if [[ $major_version -ge 16 ]]; then
      echo_content green "Supported Ubuntu version detected: $version"
    else
      echo_content red "Unsupported Ubuntu version: $version. Only supports Ubuntu 16+."
      exit 1
    fi
    ;;
  debian)
    if [[ $major_version -ge 8 ]]; then
      echo_content green "Supported Debian version detected: $version"
    else
      echo_content red "Unsupported Debian version: $version. Only supports Debian 8+."
      exit 1
    fi
    ;;
  *)
    echo_content red "Only supports CentOS 6+/Ubuntu 16+/Debian 8+"
    exit 1
    ;;
  esac

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "Only supports x86_64/amd64 arm64/aarch64"
    exit 1
  fi
}

install_depend() {
  if [[ "${package_manager}" == 'apt-get' || "${package_manager}" == 'apt' ]]; then
    ${package_manager} update -y
  fi
  ${package_manager} install -y \
    curl \
    systemd \
    nftables \
    jq
}

select_language() {
  clear
  echo_content red "=============================================================="
  echo_content skyBlue "Please select language"
  echo_content yellow "1. English (Default)"
  echo_content yellow "2. 简体中文"
  echo_content red "=============================================================="
  read -r -p "Please choose: " input_option
  case ${input_option} in
  2)
    translation_file="zh_cn.json"
    ;;
  esac
  translation_file_content=$(curl -fsSL "${translation_file_base_url}${translation_file}")
}

get_translation() {
  echo "${translation_file_content}" | jq -r "$1"
}

setup_docker() {
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  }
}
EOF
  systemctl daemon-reload
}

remove_forward() {
  if command -v nft &>/dev/null && nft list tables | grep -q hui_porthopping; then
    nft delete table inet hui_porthopping
  fi
  if command -v iptables &>/dev/null; then
    for num in $(iptables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      iptables -t nat -D PREROUTING $num
    done
  fi
  if command -v ip6tables &>/dev/null; then
    for num in $(ip6tables -t nat -L PREROUTING -v --line-numbers | grep -i "hui_hysteria_porthopping" | awk '{print $1}' | sort -rn); do
      ip6tables -t nat -D PREROUTING $num
    done
  fi
}

install_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content green "---> Install Docker"

    bash <(curl -fsSL https://get.docker.com)

    setup_docker

    systemctl enable docker && systemctl restart docker

    if [[ $(command -v docker) ]]; then
      echo_content skyBlue "---> Docker install successful"
    else
      echo_content red "---> Docker install failed"
      exit 1
    fi
  else
    echo_content skyBlue "---> Docker is already installed"
  fi
}

install_h_ui_docker() {
  if [[ -n $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content skyBlue "---> H UI is already installed"
    exit 0
  fi

  echo_content green "---> Install H UI"
  mkdir -p ${HUI_DATA_DOCKER}

  read -r -p "Please enter the port of H UI (default: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "Please enter the Time zone of H UI (default: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  docker run -d --cap-add=NET_ADMIN \
    --name h-ui --restart always \
    --network=host \
    -e TZ=${h_ui_time_zone} \
    -v /h-ui/bin:/h-ui/bin \
    -v /h-ui/data:/h-ui/data \
    -v /h-ui/export:/h-ui/export \
    -v /h-ui/logs:/h-ui/logs \
    jonssonyan/h-ui"${hui_docker_version}" \
    ./h-ui -p ${h_ui_port}
  sleep 3
  echo_content yellow "h-ui Panel Port: ${h_ui_port}"
  if version_ge "$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
    echo_content yellow "$(docker exec h-ui ./h-ui reset)"
  else
    echo_content yellow "h-ui Login Username: sysadmin"
    echo_content yellow "h-ui Login Password: sysadmin"
  fi
  echo_content skyBlue "---> H UI install successful"
}

upgrade_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker not installed"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> H UI not installed"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H UI is already the latest version"
    exit 0
  fi

  echo_content green "---> Upgrade H UI"
  docker rm -f h-ui
  docker rmi jonssonyan/h-ui

  read -r -p "Please enter the port of H UI (default: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "Please enter the Time zone of H UI (default: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  docker run -d --cap-add=NET_ADMIN \
    --name h-ui --restart always \
    --network=host \
    -e TZ=${h_ui_time_zone} \
    -v /h-ui/bin:/h-ui/bin \
    -v /h-ui/data:/h-ui/data \
    -v /h-ui/export:/h-ui/export \
    -v /h-ui/logs:/h-ui/logs \
    jonssonyan/h-ui \
    ./h-ui -p ${h_ui_port}
  echo_content skyBlue "---> H UI upgrade successful"
}

uninstall_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> Docker not installed"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> H UI not installed"
    exit 0
  fi

  echo_content green "---> Uninstall H UI"
  docker rm -f h-ui
  docker images jonssonyan/h-ui -q | xargs -r docker rmi -f
  rm -rf /h-ui/
  remove_forward
  echo_content skyBlue "---> H UI uninstall successful"
}

install_h_ui_systemd() {
  if systemctl status h-ui >/dev/null 2>&1; then
    echo_content skyBlue "---> H UI is already installed"
    exit 0
  fi

  echo_content green "---> Install H UI"
  mkdir -p ${HUI_DATA_SYSTEMD} &&
    export HUI_DATA="${HUI_DATA_SYSTEMD}"

  sed -i '/^HUI_DATA=/d' /etc/environment &&
    echo "HUI_DATA=${HUI_DATA_SYSTEMD}" | tee -a /etc/environment >/dev/null

  read -r -p "Please enter the port of H UI (default: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "Please enter the Time zone of H UI (default: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  timedatectl set-timezone ${h_ui_time_zone} && timedatectl set-local-rtc 0
  systemctl restart rsyslog
  if [[ "${release}" == "centos" || "${release}" == "rocky" ]]; then
    systemctl restart crond
  elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
    systemctl restart cron
  fi

  export GIN_MODE=release

  bin_url=https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-${get_arch}
  if [[ "latest" != "${hui_systemd_version}" ]]; then
    bin_url=https://github.com/jonssonyan/h-ui/releases/download/${hui_systemd_version}/h-ui-linux-${get_arch}
  fi

  curl -fsSL "${bin_url}" -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    curl -fsSL https://raw.githubusercontent.com/jonssonyan/h-ui/main/h-ui.service -o /etc/systemd/system/h-ui.service &&
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/h-ui/h-ui -p ${h_ui_port}|" "/etc/systemd/system/h-ui.service" &&
    systemctl daemon-reload &&
    systemctl enable h-ui &&
    systemctl restart h-ui
  sleep 3
  echo_content yellow "h-ui Panel Port: ${h_ui_port}"
  if version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
    echo_content yellow "$(${HUI_DATA_SYSTEMD}h-ui reset)"
  else
    echo_content yellow "h-ui Login Username: sysadmin"
    echo_content yellow "h-ui Login Password: sysadmin"
  fi
  echo_content skyBlue "---> H UI install successful"
}

upgrade_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> H UI not installed"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/jonssonyan/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H UI is already the latest version"
    exit 0
  fi

  echo_content green "---> Upgrade H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  curl -fsSL https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-${get_arch} -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    systemctl restart h-ui
  echo_content skyBlue "---> H UI upgrade successful"
}

uninstall_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> H UI not installed"
    exit 0
  fi

  echo_content green "---> Uninstall H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  systemctl disable h-ui.service &&
    rm -f /etc/systemd/system/h-ui.service &&
    systemctl daemon-reload &&
    rm -rf /usr/local/h-ui/ &&
    systemctl reset-failed
  remove_forward
  echo_content skyBlue "---> H UI uninstall successful"
}

ssh_local_port_forwarding() {
  read -r -p "Please enter the port of SSH local forwarding (default: 8082): " ssh_local_forwarded_port
  [[ -z "${ssh_local_forwarded_port}" ]] && ssh_local_forwarded_port="8082"
  read -r -p "Please enter the port of H UI (default: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  ssh -N -f -L 0.0.0.0:${ssh_local_forwarded_port}:localhost:${h_ui_port} localhost
  echo_content skyBlue "---> SSH local port forwarding successful"
}

reset_sysadmin() {
  if systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    if ! version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
      echo_content red "---> H UI (systemd) version must be greater than or equal to v0.0.12"
      exit 0
    fi
    export HUI_DATA="${HUI_DATA_SYSTEMD}"
    echo_content yellow "$(${HUI_DATA_SYSTEMD}h-ui reset)"
    echo_content skyBlue "---> H UI (systemd) reset sysadmin username and password successful"
  fi
  if [[ $(command -v docker) && -n $(docker ps -a -q -f "name=^h-ui$") ]]; then
    if ! version_ge "$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
      echo_content red "---> H UI (Docker) version must be greater than or equal to v0.0.12"
      exit 0
    fi
    echo_content yellow "$(docker exec h-ui ./h-ui reset)"
    echo_content skyBlue "---> H UI (Docker) reset sysadmin username and password successful"
  fi
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  select_language
  clear
  echo_content yellow '
         _   _     _    _ ___
        | | | |   | |  | |_ _|
        | |_| |   | |  | || |
        |  _  |   | |  | || |
        | | | |   | |__| || |
        |_| |_|    \____/|___|
'
  echo_content red "=============================================================="
  echo_content skyBlue "$(get_translation ".menu.recommend_os"): CentOS 8+/Ubuntu 20+/Debian 11+"
  echo_content skyBlue "$(get_translation ".menu.description")"
  echo_content skyBlue "$(get_translation ".menu.author"): jonssonyan <https://jonssonyan.com>"
  echo_content skyBlue "Github: https://github.com/jonssonyan/h-ui"
  echo_content red "=============================================================="
  echo_content yellow "1. $(get_translation ".menu.install_hui_systemd")"
  echo_content yellow "2. $(get_translation ".menu.upgrade_h_ui_systemd")"
  echo_content yellow "3. $(get_translation ".menu.uninstall_h_ui_systemd")"
  echo_content red "=============================================================="
  echo_content yellow "4. $(get_translation ".menu.install_h_ui_docker")"
  echo_content yellow "5. $(get_translation ".menu.upgrade_h_ui_docker")"
  echo_content yellow "6. $(get_translation ".menu.uninstall_h_ui_docker")"
  echo_content red "=============================================================="
  echo_content yellow "7. $(get_translation ".menu.ssh_local_port_forwarding")"
  echo_content yellow "8. $(get_translation ".menu.reset_sysadmin")"
  echo_content red "=============================================================="
  read -r -p "Please choose: " input_option
  case ${input_option} in
  1)
    install_h_ui_systemd
    ;;
  2)
    upgrade_h_ui_systemd
    ;;
  3)
    uninstall_h_ui_systemd
    ;;
  4)
    install_docker
    install_h_ui_docker
    ;;
  5)
    upgrade_h_ui_docker
    ;;
  6)
    uninstall_h_ui_docker
    ;;
  7)
    ssh_local_port_forwarding
    ;;
  8)
    reset_sysadmin
    ;;
  *)
    echo_content red "No such option"
    ;;
  esac
}

main
