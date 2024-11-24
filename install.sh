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
    echo_content red "您必须以 root 身份运行该脚本"
    exit 1
  fi

  can_connect www.google.com
  if [[ "$?" == "1" ]]; then
    echo_content red "---> 网络连接失败"
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
    echo_content red "目前不支持此系统"
    exit 1
  fi

  if [[ -n $(find /etc -name "redhat-release") ]] || grep </proc/version -q -i "centos"; then
    release="centos"
    if rpm -q centos-stream-release &> /dev/null; then
        version=$(rpm -q --queryformat '%{VERSION}' centos-stream-release)
    elif rpm -q centos-release &> /dev/null; then
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
  centos)
    if [[ $major_version -ge 6 ]]; then
      echo_content green "检测到支持的 CentOS 版本: $version"
    else
      echo_content red "不受支持的 CentOS 版本: $version. 仅支持 CentOS 6+."
      exit 1
    fi
    ;;
  ubuntu)
    if [[ $major_version -ge 16 ]]; then
      echo_content green "检测到支持的 Ubuntu 版本: $version"
    else
      echo_content red "不受支持的 Ubuntu 版本: $version. 仅支持 Ubuntu 16+."
      exit 1
    fi
    ;;
  debian)
    if [[ $major_version -ge 8 ]]; then
      echo_content green "检测到支持的 Debian 版本: $version"
    else
      echo_content red "不受支持的 Debian 版本: $version. 仅支持 Debian 8+."
      exit 1
    fi
    ;;
  *)
    echo_content red "仅支持 CentOS 6+/Ubuntu 16+/Debian 8+"
    exit 1
    ;;
  esac

  if [[ $(arch) =~ ("x86_64"|"amd64") ]]; then
    get_arch="amd64"
  elif [[ $(arch) =~ ("aarch64"|"arm64") ]]; then
    get_arch="arm64"
  fi

  if [[ -z "${get_arch}" ]]; then
    echo_content red "仅支持 x86_64/amd64 arm64/aarch64"
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
    nftables
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
    echo_content green "---> 安装 Docker"

    bash <(curl -fsSL https://get.docker.com)

    setup_docker

    systemctl enable docker && systemctl restart docker

    if [[ $(command -v docker) ]]; then
      echo_content skyBlue "---> Docker 安装成功"
    else
      echo_content red "---> Docker 安装失败"
      exit 1
    fi
  else
    echo_content skyBlue "---> Docker 已安装"
  fi
}

install_h_ui_docker() {
  if [[ -n $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content skyBlue "---> H UI 已安装"
    exit 0
  fi

  echo_content green "---> 安装 H UI"
  mkdir -p ${HUI_DATA_DOCKER}

  read -r -p "请输入H UI的端口 (默认: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "请输入H UI的时区 (默认: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  docker run -d --cap-add=NET_ADMIN \
    --name h-ui --restart always \
    --network=host \
    -e TZ=${h_ui_time_zone} \
    -v /h-ui/bin:/h-ui/bin \
    -v /h-ui/data:/h-ui/data \
    -v /h-ui/export:/h-ui/export \
    -v /h-ui/logs:/h-ui/logs \
    xxf185/h-ui"${hui_docker_version}" \
    ./h-ui -p ${h_ui_port}
  sleep 3
  echo_content yellow "h-ui面板端口: ${h_ui_port}"
  if version_ge "$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
    echo_content yellow "$(docker exec h-ui ./h-ui reset)"
  else
    echo_content yellow "h-ui 登录用户名: sysadmin"
    echo_content yellow "h-ui 登录密码: sysadmin"
  fi
  echo_content skyBlue "---> H UI 安装成功"
}

upgrade_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> 未安装 Docker"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> 未安装 H UI"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/xxf185/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H UI已是最新版本"
    exit 0
  fi

  echo_content green "---> 升级 H UI"
  docker rm -f h-ui
  docker rmi xxf185/h-ui

  read -r -p "请输入H UI的端口 (默认: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "请输入H UI的时区 (默认: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  docker run -d --cap-add=NET_ADMIN \
    --name h-ui --restart always \
    --network=host \
    -e TZ=${h_ui_time_zone} \
    -v /h-ui/bin:/h-ui/bin \
    -v /h-ui/data:/h-ui/data \
    -v /h-ui/export:/h-ui/export \
    -v /h-ui/logs:/h-ui/logs \
    xxf185/h-ui \
    ./h-ui -p ${h_ui_port}
  echo_content skyBlue "---> H UI 升级成功"
}

uninstall_h_ui_docker() {
  if [[ ! $(command -v docker) ]]; then
    echo_content red "---> 未安装 Docker"
    exit 0
  fi
  if [[ -z $(docker ps -a -q -f "name=^h-ui$") ]]; then
    echo_content red "---> 未安装 H UI"
    exit 0
  fi

  echo_content green "---> 卸载H UI"
  docker rm -f h-ui
  docker images xxf185/h-ui -q | xargs -r docker rmi -f
  rm -rf /h-ui/
  remove_forward
  echo_content skyBlue "---> H UI 卸载成功"
}

install_h_ui_systemd() {
  if systemctl status h-ui >/dev/null 2>&1; then
    echo_content skyBlue "---> H UI 已安装"
    exit 0
  fi

  echo_content green "---> 安装 H UI"
  mkdir -p ${HUI_DATA_SYSTEMD} &&
    export HUI_DATA="${HUI_DATA_SYSTEMD}"

  sed -i '/^HUI_DATA=/d' /etc/environment &&
    echo "HUI_DATA=${HUI_DATA_SYSTEMD}" | tee -a /etc/environment >/dev/null

  read -r -p "请输入H UI的端口 (默认: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  read -r -p "请输入H UI的时区 (默认: Asia/Shanghai): " h_ui_time_zone
  [[ -z "${h_ui_time_zone}" ]] && h_ui_time_zone="Asia/Shanghai"

  timedatectl set-timezone ${h_ui_time_zone} && timedatectl set-local-rtc 0
  systemctl restart rsyslog
  if [[ "${release}" == "centos" ]]; then
    systemctl restart crond
  elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
    systemctl restart cron
  fi

  export GIN_MODE=release

  bin_url=https://github.com/xxf185/h-ui/releases/latest/download/h-ui-linux-${get_arch}
  if [[ "latest" != "${hui_systemd_version}" ]]; then
    bin_url=https://github.com/xxf185/h-ui/releases/download/${hui_systemd_version}/h-ui-linux-${get_arch}
  fi

  curl -fsSL "${bin_url}" -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    curl -fsSL https://raw.githubusercontent.com/xxf185/h-ui/master/h-ui.service -o /etc/systemd/system/h-ui.service &&
    sed -i "s|^ExecStart=.*|ExecStart=/usr/local/h-ui/h-ui -p ${h_ui_port}|" "/etc/systemd/system/h-ui.service" &&
    systemctl daemon-reload &&
    systemctl enable h-ui &&
    systemctl restart h-ui
  sleep 3
  echo_content yellow "h-ui面板端口: ${h_ui_port}"
  if version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
    echo_content yellow "$(${HUI_DATA_SYSTEMD}h-ui reset)"
  else
    echo_content yellow "h-ui 登录用户名: sysadmin"
    echo_content yellow "h-ui 登录密码: sysadmin"
  fi
  echo_content skyBlue "---> H UI 安装成功"
}

upgrade_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> 未安装 H UI"
    exit 0
  fi

  latest_version=$(curl -Ls "https://api.github.com/repos/xxf185/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1/')
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')
  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "---> H UI已是最新版本"
    exit 0
  fi

  echo_content green "---> 升级H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  curl -fsSL https://github.com/xxf185/h-ui/releases/latest/download/h-ui-linux-${get_arch} -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    systemctl restart h-ui
  echo_content skyBlue "---> H UI 升级成功"
}

uninstall_h_ui_systemd() {
  if ! systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    echo_content red "---> 未安装 H UI"
    exit 0
  fi

  echo_content green "---> 卸载H UI"
  if [[ $(systemctl is-active h-ui) == "active" ]]; then
    systemctl stop h-ui
  fi
  systemctl disable h-ui.service &&
    rm -f /etc/systemd/system/h-ui.service &&
    systemctl daemon-reload &&
    rm -rf /usr/local/h-ui/ &&
    systemctl reset-failed
  remove_forward
  echo_content skyBlue "---> H UI 卸载成功"
}

ssh_local_port_forwarding() {
  read -r -p "请输入SSH本地转发的端口 (默认: 8082): " ssh_local_forwarded_port
  [[ -z "${ssh_local_forwarded_port}" ]] && ssh_local_forwarded_port="8082"
  read -r -p "请输入H UI的端口 (默认: 8081): " h_ui_port
  [[ -z "${h_ui_port}" ]] && h_ui_port="8081"
  ssh -N -f -L 0.0.0.0:${ssh_local_forwarded_port}:localhost:${h_ui_port} localhost
  echo_content skyBlue "---> SSH 本地端口转发成功"
}

reset_sysadmin() {
  if systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
    if ! version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
      echo_content red "---> H UI (systemd) 版本必须大于或等于 v0.0.12"
      exit 0
    fi
    export HUI_DATA="${HUI_DATA_SYSTEMD}"
    echo_content yellow "$(${HUI_DATA_SYSTEMD}h-ui reset)"
    echo_content skyBlue "---> H UI（systemd）重置系统管理员用户名和密码成功"
  fi
  if [[ $(command -v docker) && -n $(docker ps -a -q -f "name=^h-ui$") ]]; then
    if ! version_ge "$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
      echo_content red "---> H UI (Docker) 版本必须大于或等于 v0.0.12"
      exit 0
    fi
    echo_content yellow "$(docker exec h-ui ./h-ui reset)"
    echo_content skyBlue "---> H UI（Docker）重置系统管理员用户名和密码成功"
  fi
}

main() {
  cd "$HOME" || exit 0
  init_var
  check_sys
  install_depend
  clear
  echo_content red ""
  echo_content yellow "\n=================== H UI =========================="
  echo_content red ""
  echo_content yellow "1. 安装 H UI (systemd)"
  echo_content yellow "2. 升级 H UI (systemd)"
  echo_content yellow "3. 卸载 H UI (systemd)"
  echo_content red "\n=============================================================="
  echo_content yellow "4. 安装 H UI (Docker)"
  echo_content yellow "5. 升级 H UI (Docker)"
  echo_content yellow "6. 卸载 H UI (Docker)"
  echo_content red "\n=============================================================="
  echo_content yellow "7. SSH 本地端口转发（重启服务器后失败）"
  echo_content yellow "8. 重置系统管理员用户名和密码"
  read -r -p "请选择: " input_option
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
    echo_content red "没有这样的选项"
    ;;
  esac
}

main
